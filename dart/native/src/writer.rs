//! Stateful FFI adapter over the accepted Core writer; no archive algorithms.
use crate::{bridge_error, decode, reply, RemVibeArchiveBuffer, Reply};
use crate::operations::{allocate_handle, lock, parse_handle, start_with_token, HandleInput, OperationContext};
use crate::path::{native, NativeUnits};
use remvibe_archive::{ArchiveLayout, ArchivePath, ArchiveWriter, CancellationToken, Compression,
    ManifestLimits, MetadataCapture, WriterError, WriterOptions, WriterPhase, WriterProgress, WriterResult};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashMap, path::PathBuf, sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock}};

pub(crate) fn native_path(op: &str, value: NativeUnits) -> Result<PathBuf, Value> {
    value.into_os().map(PathBuf::from).map_err(|e| bridge_error(op,"invalidInput",e))
}
pub(crate) fn u64_value(op: &str, raw: &str) -> Result<u64, Value> {
    let value = raw.parse::<u64>().map_err(|_| bridge_error(op,"invalidInput","expected decimal u64"))?;
    if value.to_string() != raw { return Err(bridge_error(op,"invalidInput","noncanonical decimal u64")); }
    Ok(value)
}
pub(crate) fn usize_value(op: &str, raw: &str) -> Result<usize, Value> {
    usize::try_from(u64_value(op, raw)?).map_err(|_| bridge_error(op,"invalidInput","value exceeds native usize"))
}

#[derive(Deserialize)]
#[serde(tag="kind", rename_all="camelCase", deny_unknown_fields)]
enum LayoutInput {
    Single,
    Split { #[serde(rename="maxPartSize")] max_part_size: String },
}
#[derive(Deserialize)]
#[serde(rename_all="camelCase", deny_unknown_fields)]
enum CaptureInput { Basic, Full }

#[derive(Default, Deserialize)]
#[serde(default, rename_all="camelCase", deny_unknown_fields)]
pub(crate) struct LimitsInput {
    max_manifest_bytes: Option<String>,
    max_entries: Option<String>,
    max_depth: Option<String>,
    max_file_bytes: Option<String>,
    max_total_bytes: Option<String>,
}
impl LimitsInput {
    pub(crate) fn apply(self, op: &str) -> Result<ManifestLimits, Value> {
        let mut limits = ManifestLimits::default();
        if let Some(v) = self.max_manifest_bytes { limits.max_manifest_bytes = u64_value(op,&v)?; }
        if let Some(v) = self.max_entries { limits.max_entries = usize_value(op,&v)?; }
        if let Some(v) = self.max_depth { limits.max_depth = usize_value(op,&v)?; }
        if let Some(v) = self.max_file_bytes { limits.max_file_bytes = u64_value(op,&v)?; }
        if let Some(v) = self.max_total_bytes { limits.max_total_bytes = u64_value(op,&v)?; }
        Ok(limits)
    }
}
#[derive(Default, Deserialize)]
#[serde(default, rename_all="camelCase", deny_unknown_fields)]
struct OptionsInput {
    layout: Option<LayoutInput>,
    compression: Option<Compression>,
    manifest_compression: Option<Compression>,
    zlib_level: Option<u32>,
    zstd_level: Option<i32>,
    buffer_size: Option<String>,
    metadata_capture: Option<CaptureInput>,
    limits: Option<LimitsInput>,
}
impl OptionsInput {
    fn apply(self, op: &str, token: CancellationToken) -> Result<WriterOptions, Value> {
        let mut options = WriterOptions { cancellation: token, ..WriterOptions::default() };
        if let Some(v) = self.layout {
            options.layout = match v {
                LayoutInput::Single => ArchiveLayout::Single,
                LayoutInput::Split { max_part_size } => ArchiveLayout::Split { max_part_size: u64_value(op,&max_part_size)? },
            };
        }
        if let Some(v) = self.compression { options.compression = v; }
        if let Some(v) = self.manifest_compression { options.manifest_compression = v; }
        if let Some(v) = self.zlib_level { options.zlib_level = v; }
        if let Some(v) = self.zstd_level { options.zstd_level = v; }
        if let Some(v) = self.buffer_size { options.buffer_size = usize_value(op,&v)?; }
        if let Some(v) = self.metadata_capture {
            options.metadata_capture = match v { CaptureInput::Basic => MetadataCapture::Basic, CaptureInput::Full => MetadataCapture::Full };
        }
        if let Some(v) = self.limits { options.limits = v.apply(op)?; }
        Ok(options)
    }
}

pub(crate) fn writer_error(op: &str, error: WriterError) -> Value {
    let message = error.to_string();
    let (kind, details) = match error {
        WriterError::Io { path, source } => ("io", json!({"path":native(path.as_os_str()),"osCode":source.raw_os_error(),"ioKind":format!("{:?}",source.kind()),"reason":source.to_string()})),
        WriterError::FileSystem(e) => {
            let name = format!("{:?}",e.kind);
            let kind = name.get(..1).unwrap_or("").to_ascii_lowercase() + name.get(1..).unwrap_or("");
            ("fileSystem", json!({"fileSystem":{"kind":kind,"operation":e.operation,"path":e.path.as_ref().map(|p| native(p.as_os_str())),"osCode":e.os_code,"message":e.message}}))
        }
        WriterError::Path(e) => ("path", json!({"reason":e.to_string()})),
        WriterError::Manifest(e) => ("manifest", json!({"reason":e.to_string()})),
        WriterError::Invalid(reason) => ("invalid", json!({"reason":reason})),
        WriterError::Unsupported(path) => ("unsupported",json!({"path":native(path.as_os_str())})),
        WriterError::SourceChanged(path) => ("sourceChanged",json!({"path":native(path.as_os_str())})),
        WriterError::DestinationExists(path) => ("destinationExists",json!({"path":native(path.as_os_str())})),
        WriterError::Cancelled => ("cancelled",json!({})),
        WriterError::Closed => ("closed",json!({})),
        WriterError::Cleanup { path, original, source } => ("cleanup",json!({
            "path":native(path.as_os_str()),"original":writer_error(op,*original),
            "osCode":source.raw_os_error(),"ioKind":format!("{:?}",source.kind()),"reason":source.to_string()
        })),
    };
    let mut result = json!({"domain":"archive","kind":kind,"operation":op,"message":message});
    if let (Some(output), Value::Object(fields)) = (result.as_object_mut(), details) { output.extend(fields); }
    result
}

fn progress(context: &OperationContext, p: &WriterProgress) {
    let phase = match p.phase {
        WriterPhase::Preparing => "preparing", WriterPhase::Writing => "writing",
        WriterPhase::EntryCompleted => "entryCompleted", WriterPhase::Finalizing => "finalizing",
        WriterPhase::Completed => "completed",
    };
    context.emit(phase, json!({
        "phase":phase,"path":p.path,"entriesCompleted":p.entries_completed.to_string(),
        "sourceBytesRead":p.source_bytes_read.to_string(),"entryBytesRead":p.entry_bytes_read.to_string(),
        "entryTotalBytes":p.entry_total_bytes.map(|n| n.to_string()),
    }));
}
fn result(value: WriterResult) -> Value {
    json!({"path":native(value.path.as_os_str()),"entryCount":value.entry_count.to_string(),
        "sourceBytes":value.source_bytes.to_string(),"archiveBytes":value.archive_bytes.to_string(),
        "partCount":value.part_count.to_string(),"physicalBytes":value.physical_bytes.to_string()})
}

struct WriterState {
    writer: Option<ArchiveWriter>,
    busy: bool,
    closing: bool,
}
struct WriterSlot {
    token: CancellationToken,
    state: Mutex<WriterState>,
    ready: Condvar,
}
static WRITERS: OnceLock<Mutex<HashMap<u64, Arc<WriterSlot>>>> = OnceLock::new();
fn writers() -> MutexGuard<'static, HashMap<u64, Arc<WriterSlot>>> {
    lock(WRITERS.get_or_init(|| Mutex::new(HashMap::new())))
}

// Reserve synchronously before spawning. A spawn failure drops the lease and
// restores idle state without moving the core writer out of the slot.
struct Lease(Arc<WriterSlot>);
impl Drop for Lease {
    fn drop(&mut self) {
        lock(&self.0.state).busy = false;
        self.0.ready.notify_all();
    }
}
fn reserve(op: &str, raw: &str) -> Result<Lease, Value> {
    let id = parse_handle(op, raw)?;
    let slot = { writers().get(&id).cloned() }
        .ok_or_else(|| bridge_error(op,"invalidHandle","unknown writer handle"))?;
    {
        let mut state = lock(&slot.state);
        if state.closing { return Err(writer_error(op, WriterError::Closed)); }
        if state.busy { return Err(bridge_error(op,"busy","writer already has an active operation")); }
        if state.writer.is_none() { return Err(writer_error(op, WriterError::Closed)); }
        state.busy = true;
    }
    Ok(Lease(slot))
}

enum Command {
    AddFile { source: PathBuf, path: ArchivePath, compression: Option<Compression> },
    AddDirectory { source: PathBuf, path: ArchivePath, recursive: bool },
    Finish,
    Abort,
}

fn run_command(op: &'static str, raw: &str, command: Command) -> Reply {
    let lease = reserve(op, raw)?;
    let token = lease.0.token.clone();
    start_with_token(op, token, move |context| {
        let mut writer = lock(&lease.0.state).writer.take()
            .ok_or_else(|| writer_error(op, WriterError::Closed))?;
        let events = context.clone();
        writer.set_progress_handler(move |p| progress(&events,p));
        let added = match command {
            Command::AddFile { source, path, compression } => match compression {
                Some(codec) => writer.add_file_with_compression(&source,path,codec),
                None => writer.add_file(&source,path),
            },
            Command::AddDirectory { source, path, recursive } => writer.add_directory(&source,path,recursive),
            Command::Finish => {
                let outcome = writer.finish().map(result).map_err(|e| writer_error(op,e));
                context.seal();
                return outcome;
            }
            Command::Abort => {
                let outcome = writer.abort().map(|()| Value::Null).map_err(|e| writer_error(op,e));
                context.seal();
                return outcome;
            }
        };
        // Detach the per-command callback before restoring the writer.
        writer.set_progress_handler(|_| {});
        context.seal();
        match added {
            Err(e) => Err(writer_error(op,e)), // Core failed and discarded staging.
            Ok(()) if context.token().is_cancelled() => {
                // Cancellation accepted before the command was sealed, even if
                // the final chunk already completed. Discard unpublished staging.
                writer.abort().map_err(|e| writer_error(op,e))?;
                Err(writer_error(op,WriterError::Cancelled))
            }
            Ok(()) => {
                lock(&lease.0.state).writer = Some(writer);
                Ok(Value::Null)
            }
        }
    })
}

#[derive(Deserialize)]
#[serde(rename_all="camelCase", deny_unknown_fields)]
struct CreateInput { destination: NativeUnits, #[serde(default)] options: OptionsInput }
#[derive(Deserialize)]
#[serde(rename_all="camelCase", deny_unknown_fields)]
struct AddFileInput { handle: String, source: NativeUnits, path: ArchivePath, compression: Option<Compression> }
#[derive(Deserialize)]
#[serde(rename_all="camelCase", deny_unknown_fields)]
struct AddDirectoryInput { handle: String, source: NativeUnits, path: ArchivePath, recursive: bool }

#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_writer_create(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    const OP: &str = "writer_create";
    reply(OP, || {
        let input = decode::<CreateInput>(OP,data,len)?;
        let destination = native_path(OP,input.destination)?;
        let token = CancellationToken::new();
        let options = input.options.apply(OP,token.clone())?;
        let id = allocate_handle(OP)?;
        start_with_token(OP,token,move |context| {
            let writer = ArchiveWriter::new(&destination,options).map_err(|e| writer_error(OP,e))?;
            context.seal();
            if context.token().is_cancelled() {
                writer.abort().map_err(|e| writer_error(OP,e))?;
                return Err(writer_error(OP,WriterError::Cancelled));
            }
            let slot = Arc::new(WriterSlot { token:context.token(),
                state:Mutex::new(WriterState {writer:Some(writer),busy:false,closing:false}), ready:Condvar::new() });
            writers().insert(id,slot);
            Ok(json!({"handle":id.to_string()}))
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_writer_add_file(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    const OP: &str = "writer_add_file";
    reply(OP, || {
        let v = decode::<AddFileInput>(OP,data,len)?;
        run_command(OP,&v.handle,Command::AddFile {source:native_path(OP,v.source)?,path:v.path,compression:v.compression})
    })
}
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_writer_add_directory(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    const OP: &str = "writer_add_directory";
    reply(OP, || {
        let v = decode::<AddDirectoryInput>(OP,data,len)?;
        run_command(OP,&v.handle,Command::AddDirectory {source:native_path(OP,v.source)?,path:v.path,recursive:v.recursive})
    })
}
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_writer_finish(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    const OP: &str = "writer_finish";
    reply(OP, || run_command(OP,&decode::<HandleInput>(OP,data,len)?.handle,Command::Finish))
}
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_writer_abort(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    const OP: &str = "writer_abort";
    reply(OP, || run_command(OP,&decode::<HandleInput>(OP,data,len)?.handle,Command::Abort))
}

/// Idempotent explicit disposal. Cancel active work, wait outside registry lock,
/// and explicitly abort any surviving unpublished staging. Caller owns the
/// active operation result (including its cleanup error).
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_writer_close(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    const OP: &str = "writer_close";
    reply(OP, || {
        let id = parse_handle(OP,&decode::<HandleInput>(OP,data,len)?.handle)?;
        let slot = { writers().get(&id).cloned() };
        if let Some(slot) = slot {
            let mut state = lock(&slot.state);
            state.closing = true;
            if state.busy { slot.token.cancel(); }
            while state.busy {
                state = slot.ready.wait(state).unwrap_or_else(|e| e.into_inner());
            }
            // Serialize concurrent close callers for this handle until its
            // cleanup is complete, without holding the global registry lock.
            let outcome = if let Some(writer) = state.writer.take() {
                writer.abort().map_err(|e| writer_error(OP,e))
            } else { Ok(()) };
            writers().remove(&id);
            drop(state);
            outcome?;
        }
        Ok(Value::Null)
    })
}
