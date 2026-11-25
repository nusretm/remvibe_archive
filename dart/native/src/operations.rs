//! Native operation lifetime substrate. Writer/Reader commands are added in B/C.
use crate::{bridge_error, decode, envelope, reply, RemVibeArchiveBuffer, Reply};
use remvibe_archive::{ArchiveLayout, CancellationToken, ExtractOptions, ExtractionSync, MetadataCapture, ReaderOptions, WriterOptions, VERSION};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    panic::{catch_unwind, AssertUnwindSafe},
    sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, atomic::{AtomicU64, Ordering}},
    thread::{self, JoinHandle},
};

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}
#[derive(Default)]
struct State {
    terminal: Option<Reply>,
    consumed: bool,
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

fn start(operation: &'static str, task: impl FnOnce(CancellationToken) -> Reply + Send + 'static) -> Reply {
    // Checked monotonic allocation on both supported Rust toolchains.
    let mut current = NEXT_HANDLE.load(Ordering::Relaxed);
    let id = loop {
        let next = current.checked_add(1)
            .ok_or_else(|| bridge_error(operation,"invalidInput","operation handles exhausted"))?;
        match NEXT_HANDLE.compare_exchange_weak(current, next, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(previous) => break previous,
            Err(observed) => current = observed,
        }
    };
    let entry = Arc::new(Operation {
        token: CancellationToken::new(), state: Mutex::new(State::default()),
        ready: Condvar::new(), worker: Mutex::new(None),
    });
    let running = Arc::clone(&entry);
    let worker = thread::Builder::new().name("remvibe-archive-operation".into()).spawn(move || {
        let result = catch_unwind(AssertUnwindSafe(|| task(running.token.clone())))
            .unwrap_or_else(|_| Err(bridge_error(operation,"panic","native operation panicked")));
        lock(&running.state).terminal = Some(result);
        running.ready.notify_all();
    }).map_err(|e| bridge_error(operation,"workerFailed",e.to_string()))?;
    *lock(&entry.worker) = Some(worker);
    registry().insert(id, entry);
    Ok(json!({"handle":id.to_string()}))
}
#[derive(Deserialize)]
struct HandleInput { handle: String }
unsafe fn handle(op: &str, data: *const u8, len: usize) -> Result<u64, Value> {
    let raw = decode::<HandleInput>(op, data, len)?.handle;
    let id = raw.parse::<u64>().map_err(|_| bridge_error(op,"invalidInput","invalid operation handle"))?;
    if id == 0 || id.to_string() != raw { return Err(bridge_error(op,"invalidInput","invalid operation handle")); }
    Ok(id)
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

/// Blocking receive, one terminal result per operation. No registry lock while waiting.
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_operation_recv(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    reply("operation_recv", || {
        let id = handle("operation_recv", data, len)?;
        let entry = { registry().get(&id).cloned() }
            .ok_or_else(|| bridge_error("operation_recv","invalidHandle","unknown operation handle"))?;
        let mut state = lock(&entry.state);
        loop {
            if state.consumed { return Err(bridge_error("operation_recv","invalidHandle","terminal result already consumed")); }
            if let Some(terminal) = state.terminal.take() {
                state.consumed = true;
                entry.ready.notify_all();
                return Ok(json!({"kind":"terminal","result":envelope(terminal)}));
            }
            state = entry.ready.wait(state).unwrap_or_else(|e| e.into_inner());
        }
    })
}

/// Request only; successful completion may have won the race. Closed is a no-op.
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_operation_cancel(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    reply("operation_cancel", || {
        let id = handle("operation_cancel", data, len)?;
        let entry = { registry().get(&id).cloned() };
        if let Some(entry) = entry { entry.token.cancel(); }
        Ok(Value::Null)
    })
}

/// Explicit, idempotent release; cancel and join outside the registry lock.
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_operation_close(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    reply("operation_close", || {
        let id = handle("operation_close", data, len)?;
        let entry = { registry().remove(&id) };
        if let Some(entry) = entry {
            entry.token.cancel();
            let worker = lock(&entry.worker).take();
            if let Some(worker) = worker {
                worker.join().map_err(|_| bridge_error("operation_close","workerFailed","native worker join failed"))?;
            }
        }
        Ok(Value::Null)
    })
}
