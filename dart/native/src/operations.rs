//! Native operation lifecycle and bounded progress delivery.
use crate::{bridge_error, decode, envelope, reply, RemVibeArchiveBuffer, Reply};
use remvibe_archive::{ArchiveLayout, CancellationToken, ExtractOptions, ExtractionSync, MetadataCapture, ReaderOptions, WriterOptions, VERSION};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::{HashMap, VecDeque},
    panic::{catch_unwind, AssertUnwindSafe},
    sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, atomic::{AtomicU64, Ordering}},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}
const PROGRESS_INTERVAL: Duration = Duration::from_millis(100);
const PROGRESS_CAPACITY: usize = 64;

#[derive(Default)]
struct State {
    progress: VecDeque<Value>,
    last_phase: Option<String>,
    last_snapshot: Option<Instant>,
    terminal: Option<Reply>,
    consumed: bool,
    sealed: bool,
    abandoned: bool,
}
struct Operation {
    token: CancellationToken,
    state: Mutex<State>,
    ready: Condvar,
    worker: Mutex<Option<JoinHandle<()>>>,
}
static OPERATIONS: OnceLock<Mutex<HashMap<u64, Arc<Operation>>>> = OnceLock::new();
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);
fn registry() -> MutexGuard<'static, HashMap<u64, Arc<Operation>>> {
    lock(OPERATIONS.get_or_init(|| Mutex::new(HashMap::new())))
}

pub(crate) fn allocate_handle(operation: &str) -> Result<u64, Value> {
    let mut current = NEXT_HANDLE.load(Ordering::Relaxed);
    loop {
        let next = current.checked_add(1)
            .ok_or_else(|| bridge_error(operation,"invalidInput","handles exhausted"))?;
        match NEXT_HANDLE.compare_exchange_weak(current, next, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(previous) => return Ok(previous),
            Err(observed) => current = observed,
        }
    }
}

#[derive(Clone)]
pub(crate) struct OperationContext(Arc<Operation>);
impl OperationContext {
    pub(crate) fn token(&self) -> CancellationToken { self.0.token.clone() }

    // Once a writer command has decided its result, cancel from that operation
    // may no longer poison the writer's one-way token for a later command.
    pub(crate) fn seal(&self) {
        lock(&self.0.state).sealed = true;
    }

    /// Real Core phase transitions are queued in order. Same-phase writing
    /// snapshots are sampled at ~100ms. A slow receiver cannot grow this native
    /// queue indefinitely; cancel/close releases a blocked producer.
    pub(crate) fn emit(&self, phase: &str, value: Value) {
        let mut state = lock(&self.0.state);
        if state.abandoned || state.sealed { return; }
        let now = Instant::now();
        if state.last_phase.as_deref() == Some(phase) && phase == "writing"
            && state.last_snapshot.is_some_and(|last| now.duration_since(last) < PROGRESS_INTERVAL) {
            return;
        }
        while state.progress.len() >= PROGRESS_CAPACITY {
            if state.abandoned || self.0.token.is_cancelled() { return; }
            let (next, _) = self.0.ready.wait_timeout(state, PROGRESS_INTERVAL)
                .unwrap_or_else(|e| e.into_inner());
            state = next;
        }
        if state.abandoned || (self.0.token.is_cancelled() && phase != "completed") { return; }
        state.last_phase = Some(phase.to_owned());
        state.last_snapshot = Some(Instant::now());
        state.progress.push_back(value);
        self.0.ready.notify_all();
    }
}

pub(crate) fn start_with_token(
    operation: &'static str,
    token: CancellationToken,
    task: impl FnOnce(OperationContext) -> Reply + Send + 'static,
) -> Reply {
    let id = allocate_handle(operation)?;
    let entry = Arc::new(Operation {
        token, state: Mutex::new(State::default()),
        ready: Condvar::new(), worker: Mutex::new(None),
    });
    let running = Arc::clone(&entry);
    let worker = thread::Builder::new().name("remvibe-archive-operation".into()).spawn(move || {
        let result = catch_unwind(AssertUnwindSafe(|| task(OperationContext(Arc::clone(&running)))))
            .unwrap_or_else(|_| Err(bridge_error(operation,"panic","native operation panicked")));
        let mut state = lock(&running.state);
        state.sealed = true;
        state.terminal = Some(result);
        running.ready.notify_all();
    }).map_err(|e| bridge_error(operation,"workerFailed",e.to_string()))?;
    *lock(&entry.worker) = Some(worker);
    registry().insert(id, entry);
    Ok(json!({"handle":id.to_string()}))
}
fn start(operation: &'static str, task: impl FnOnce(CancellationToken) -> Reply + Send + 'static) -> Reply {
    start_with_token(operation, CancellationToken::new(), move |context| task(context.token()))
}
#[derive(Deserialize)]
pub(crate) struct HandleInput { pub(crate) handle: String }
pub(crate) fn parse_handle(op: &str, raw: &str) -> Result<u64, Value> {
    let id = raw.parse::<u64>().map_err(|_| bridge_error(op,"invalidInput","invalid handle"))?;
    if id == 0 || id.to_string() != raw { return Err(bridge_error(op,"invalidInput","invalid handle")); }
    Ok(id)
}
unsafe fn handle(op: &str, data: *const u8, len: usize) -> Result<u64, Value> {
    parse_handle(op, &decode::<HandleInput>(op, data, len)?.handle)
}

/// Actual root Core defaults, not a synthetic archive operation.
#[no_mangle]
pub extern "C" fn remvibe_archive_core_info() -> *mut RemVibeArchiveBuffer {
    reply("core_info", || start("core_info", |token| {
        if token.is_cancelled() {
            return Err(json!({"domain":"archive","kind":"cancelled","operation":"core_info","message":"operation cancelled"}));
        }
        let writer = WriterOptions::default();
        let reader = ReaderOptions::default();
        let extract = ExtractOptions::default();
        Ok(json!({
            "formatVersion":VERSION,
            "compression":writer.compression,
            "manifestCompression":writer.manifest_compression,
            "zstdLevel":writer.zstd_level,
            "zlibLevel":writer.zlib_level,
            "layout":match writer.layout { ArchiveLayout::Single => "single", ArchiveLayout::Split { .. } => "split" },
            "metadataCapture":match writer.metadata_capture { MetadataCapture::Basic => "basic", MetadataCapture::Full => "full" },
            "extractionSync":match extract.sync { ExtractionSync::Buffered => "buffered", ExtractionSync::PerFile => "perFile" },
            "writerBufferSize":writer.buffer_size.to_string(),
            "readerBufferSize":reader.buffer_size.to_string(),
            "maxManifestBytes":reader.limits.max_manifest_bytes.to_string(),
            "maxTotalBytes":reader.limits.max_total_bytes.to_string()
        }))
    }))
}


/// Blocking receive: ordered progress followed by one terminal result.
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_operation_recv(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    reply("operation_recv", || {
        let id = handle("operation_recv", data, len)?;
        let entry = { registry().get(&id).cloned() }
            .ok_or_else(|| bridge_error("operation_recv","invalidHandle","unknown operation handle"))?;
        let mut state = lock(&entry.state);
        loop {
            if state.consumed || state.abandoned {
                return Err(bridge_error("operation_recv","invalidHandle","operation closed or terminal already consumed"));
            }
            if let Some(progress) = state.progress.pop_front() {
                entry.ready.notify_all();
                return Ok(json!({"kind":"progress","value":progress}));
            }
            if let Some(terminal) = state.terminal.take() {
                state.consumed = true;
                entry.ready.notify_all();
                return Ok(json!({"kind":"terminal","result":envelope(terminal)}));
            }
            state = entry.ready.wait(state).unwrap_or_else(|e| e.into_inner());
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_operation_cancel(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    reply("operation_cancel", || {
        let id = handle("operation_cancel", data, len)?;
        let entry = { registry().get(&id).cloned() };
        if let Some(entry) = entry {
            let state = lock(&entry.state);
            if !state.sealed { entry.token.cancel(); }
            entry.ready.notify_all();
        }
        Ok(Value::Null)
    })
}

/// Release a receiver and join worker outside the registry lock. Never cancel
/// a sealed operation: Writer operations share the writer's one-way token.
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_operation_close(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    reply("operation_close", || {
        let id = handle("operation_close", data, len)?;
        let entry = { registry().remove(&id) };
        if let Some(entry) = entry {
            {
                let mut state = lock(&entry.state);
                state.abandoned = true;
                state.progress.clear();
                if !state.sealed { entry.token.cancel(); }
                entry.ready.notify_all();
            }
            let worker = lock(&entry.worker).take();
            if let Some(worker) = worker {
                worker.join().map_err(|_| bridge_error("operation_close","workerFailed","native worker join failed"))?;
            }
        }
        Ok(Value::Null)
    })
}
