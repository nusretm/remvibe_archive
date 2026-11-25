//! Stateful adapter for the accepted Reader Core. No format or extraction logic.
use crate::{bridge_error, decode, reply, RemVibeArchiveBuffer, Reply};
use crate::operations::{allocate_handle, lock, parse_handle, start_with_token, start_with_mode, HandleInput, OperationContext, StreamCancelled};
use crate::path::{native, NativeUnits};
use crate::writer::{native_path, u64_value, usize_value, LimitsInput};
use remvibe_archive::{ArchiveReader, ArchiveMetadata, ArchiveTimestamp, CancellationToken,
    EntryKind, ExtractOptions, ExtractResult, ExtractionSync, MetadataApplyResult, MetadataPolicy,
    MetadataRequirement, ReaderError, ReaderOptions, ReaderPhase, ReaderProgress, ReadResult, SplitReader};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashMap, fs::File, io::{Read, Seek}, path::{Path, PathBuf},
    sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock}};

trait ReadSeek: Read + Seek + Send {}
impl<T: Read + Seek + Send> ReadSeek for T {}
type CoreReader = ArchiveReader<Box<dyn ReadSeek>>;

#[derive(Deserialize)]
#[serde(tag="kind", rename_all="camelCase", deny_unknown_fields)]
enum SourceInput {
    Single,
    Split,
    Embedded { offset: String, length: String },
}
#[derive(Default, Deserialize)]
#[serde(default, rename_all="camelCase", deny_unknown_fields)]
struct OptionsInput {
    buffer_size: Option<String>,
    limits: Option<LimitsInput>,
}
impl OptionsInput {
    fn apply(self, op: &str, token: CancellationToken) -> Result<ReaderOptions, Value> {
        let mut options = ReaderOptions { cancellation: token, ..ReaderOptions::default() };
        if let Some(v) = self.buffer_size { options.buffer_size = usize_value(op,&v)?; }
        if let Some(v) = self.limits { options.limits = v.apply(op)?; }
        Ok(options)
    }
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all="camelCase")]
enum Requirement { Ignore, IfSupported, BestEffort, Required }
impl From<Requirement> for MetadataRequirement {
    fn from(value: Requirement) -> Self {
        match value {
            Requirement::Ignore => Self::Ignore,
            Requirement::IfSupported => Self::IfSupported,
            Requirement::BestEffort => Self::BestEffort,
            Requirement::Required => Self::Required,
        }
    }
}
#[derive(Default, Deserialize)]
#[serde(default, rename_all="camelCase", deny_unknown_fields)]
struct PolicyInput {
    modified_time: Option<Requirement>, accessed_time: Option<Requirement>,
    created_time: Option<Requirement>, posix_mode: Option<Requirement>,
    ownership: Option<Requirement>, windows_acl: Option<Requirement>,
    windows_attributes: Option<Requirement>, readonly: Option<Requirement>,
    allow_privileged_mode: Option<bool>,
}
impl PolicyInput {
    fn into_core(self) -> MetadataPolicy {
        let mut p = MetadataPolicy::default();
        if let Some(v) = self.modified_time { p.modified_time = v.into(); }
        if let Some(v) = self.accessed_time { p.accessed_time = v.into(); }
        if let Some(v) = self.created_time { p.created_time = v.into(); }
        if let Some(v) = self.posix_mode { p.posix_mode = v.into(); }
        if let Some(v) = self.ownership { p.ownership = v.into(); }
        if let Some(v) = self.windows_acl { p.windows_acl = v.into(); }
        if let Some(v) = self.windows_attributes { p.windows_attributes = v.into(); }
        if let Some(v) = self.readonly { p.readonly = v.into(); }
        if let Some(v) = self.allow_privileged_mode { p.allow_privileged_mode = v; }
        p
    }
}
#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
enum SyncInput { Buffered, PerFile }
#[derive(Default, Deserialize)]
#[serde(default, rename_all="camelCase", deny_unknown_fields)]
struct ExtractInput {
    // Omitted policy means default; explicit defer skips all application.
    defer_metadata: bool,
    metadata_policy: Option<PolicyInput>,
    sync: Option<SyncInput>,
}
impl ExtractInput {
    fn apply(self, op: &str) -> Result<ExtractOptions, Value> {
        if self.defer_metadata && self.metadata_policy.is_some() {
            return Err(bridge_error(op,"invalidInput","deferred metadata cannot include a policy"));
        }
        Ok(ExtractOptions {
            metadata_policy: if self.defer_metadata { None } else {
                Some(self.metadata_policy.map(PolicyInput::into_core).unwrap_or_default())
            },
            sync: match self.sync {
                None | Some(SyncInput::Buffered) => ExtractionSync::Buffered,
                Some(SyncInput::PerFile) => ExtractionSync::PerFile,
            }
        })
    }
}

fn lower_camel(value: impl std::fmt::Debug) -> String {
    let name = format!("{value:?}");
    name.get(..1).unwrap_or("").to_ascii_lowercase() + name.get(1..).unwrap_or("")
}
// Type inference keeps the private FFI dependent on the root archive crate only.
macro_rules! fs_error {
    ($error:expr) => {{
        let e = $error;
        json!({"kind":lower_camel(e.kind),"operation":e.operation,
            "path":e.path.as_ref().map(|p| native(p.as_os_str())),
            "osCode":e.os_code,"message":e.message})
    }};
}
fn metadata_result(r: &MetadataApplyResult) -> Value {
    json!({"isSuccess":r.is_success(),"fields":r.fields.iter().map(|f| json!({
        "field":lower_camel(f.field),"status":lower_camel(f.status),"fatal":f.fatal,
        "error":f.error.as_ref().map(|e| fs_error!(e))
    })).collect::<Vec<_>>()})
}

pub(crate) fn reader_error(op: &str, error: ReaderError) -> Value {
    let message = error.to_string();
    let (kind, details) = match error {
        ReaderError::Io(e) => ("io", json!({"osCode":e.raw_os_error(),"ioKind":format!("{:?}",e.kind()),"reason":e.to_string()})),
        ReaderError::Format(e) => ("format",json!({"reason":e.to_string()})),
        ReaderError::Manifest(e) => ("manifest",json!({"reason":e.to_string()})),
        ReaderError::Path(e) => ("path",json!({"reason":e.to_string()})),
        ReaderError::MetadataCodec(e) => ("metadataCodec",json!({"reason":e.to_string()})),
        ReaderError::FileSystem(e) => ("fileSystem",json!({"fileSystem":fs_error!(&e)})),
        ReaderError::Invalid(reason) => ("invalid",json!({"reason":reason})),
        ReaderError::EntryNotFound(index) => ("entryNotFound",json!({"index":index.to_string()})),
        ReaderError::NotFile(index) => ("notFile",json!({"index":index.to_string()})),
        ReaderError::Integrity {index,reason} => ("integrity",json!({"index":index.to_string(),"reason":reason})),
        ReaderError::DestinationExists(path) => ("destinationExists",json!({"path":native(path.as_os_str())})),
        ReaderError::Collision(path) => ("collision",json!({"path":native(path.as_os_str())})),
        ReaderError::Metadata {path,result} => ("metadata",json!({"archivePath":path,"metadataResult":metadata_result(&result)})),
        ReaderError::Cancelled => ("cancelled",json!({})),
        ReaderError::Cleanup {path,original,source} => ("cleanup",json!({
            "path":native(path.as_os_str()),"original":reader_error(op,*original),
            "fileSystem":fs_error!(&source),"osCode":source.os_code
        })),
    };
    let mut out = json!({"domain":"archive","kind":kind,"operation":op,"message":message});
    if let (Some(output),Value::Object(fields)) = (out.as_object_mut(),details) { output.extend(fields); }
    out
}
fn closed(op: &str) -> Value {
    json!({"domain":"archive","kind":"closed","operation":op,"message":"Reader is closed or cancelled; close and reopen"})
}

// FS-compatible signed floor seconds, positive nanoseconds. Never convert to
// a native time or a JSON floating point number; preserve full RVA range.
fn timestamp(t: ArchiveTimestamp) -> Value {
    let (seconds,nanos) = if !t.before_epoch { (i128::from(t.seconds),t.nanos) }
        else if t.nanos == 0 { (-i128::from(t.seconds),0) }
        else { (-i128::from(t.seconds)-1,1_000_000_000-t.nanos) };
    json!({"seconds":seconds.to_string(),"nanoseconds":nanos})
}
fn metadata(op: &str, m: &ArchiveMetadata) -> Result<Value, Value> {
    // Permissions are intentionally private in RVA. Read the accepted
    // serialized representation; translate only its wire tags, not OS data.
    let mut wire = serde_json::to_value(m).map_err(|e| bridge_error(op,"invalidResponse",e.to_string()))?;
    let mut permissions = wire["permissions"].take();
    if let Some(p) = permissions.as_object_mut() {
        if let Some(platform) = p.remove("platform") { p.insert("kind".into(),platform); }
        if let Some(entries) = p.get_mut("dacl").and_then(|d| d.get_mut("entries")).and_then(Value::as_array_mut) {
            for entry in entries {
                if let Some(ace) = entry.as_object_mut() {
                    if let Some(allow) = ace.remove("allow") {
                        ace.insert("accessType".into(),json!(if allow == Value::Bool(true) {"allow"} else {"deny"}));
                    }
                }
            }
        }
    }
    Ok(json!({
        "size":m.size.map(|n| n.to_string()),
        "createdAt":m.created_at.map(timestamp),"modifiedAt":m.modified_at.map(timestamp),
        "accessedAt":m.accessed_at.map(timestamp),
        "attributes":{"readonly":m.readonly,"windows":m.windows_attributes},
        "permissions":permissions
    }))
}
fn manifest(op: &str, reader: &CoreReader, context: &OperationContext) -> Reply {
    let mut entries = Vec::with_capacity(reader.entries().len());
    let mut total = 0u64;
    let token = context.token();
    for (index, entry) in reader.entries().iter().enumerate() {
        if token.is_cancelled() { return Err(reader_error(op,ReaderError::Cancelled)); }
        let (kind,payload) = match &entry.entry {
            EntryKind::Directory => ("directory",Value::Null),
            EntryKind::File {payload} => {
                total = total.checked_add(payload.original_size)
                    .ok_or_else(|| reader_error(op,ReaderError::Invalid("total size overflow")))?;
                ("file",json!({
                    "offset":payload.offset.to_string(),"storedSize":payload.stored_size.to_string(),
                    "originalSize":payload.original_size.to_string(),"compression":payload.compression,"sha256":payload.sha256
                }))
            }
        };
        entries.push(json!({"index":index.to_string(),"path":entry.path,"kind":kind,
            "payload":payload,"metadata":metadata(op,&entry.metadata)?}));
    }
    Ok(json!({"entries":entries,"totalBytes":total.to_string()}))
}
fn progress(context: &OperationContext, p: &ReaderProgress) {
    let phase = match p.phase {
        ReaderPhase::Reading => "reading", ReaderPhase::Verifying => "verifying",
        ReaderPhase::Preparing => "preparing", ReaderPhase::Extracting => "extracting",
        ReaderPhase::EntryCompleted => "entryCompleted", ReaderPhase::ApplyingMetadata => "applyingMetadata",
        ReaderPhase::Finalizing => "finalizing", ReaderPhase::Completed => "completed",
    };
    context.emit(phase,json!({"phase":phase,"path":p.path,
        "entriesCompleted":p.entries_completed.to_string(),"totalEntries":p.total_entries.to_string(),
        "outputBytes":p.output_bytes.to_string(),"totalBytes":p.total_bytes.to_string(),
        "entryBytesRead":p.entry_bytes.to_string(),"entryTotalBytes":p.entry_total_bytes.map(|n| n.to_string())}));
}
fn read_result(v: ReadResult) -> Value {
    json!({"entryCount":v.entry_count.to_string(),"outputBytes":v.output_bytes.to_string()})
}
fn extract_result(v: ExtractResult) -> Value {
    json!({"path":native(v.path.as_os_str()),"entryCount":v.entry_count.to_string(),"outputBytes":v.output_bytes.to_string(),
        "metadata":v.metadata.iter().map(|m| json!({"path":m.path,"result":metadata_result(&m.result)})).collect::<Vec<_>>()})
}

struct ReaderState { reader: Option<CoreReader>, busy: bool, closing: bool }
struct ReaderSlot { token: CancellationToken, state: Mutex<ReaderState>, ready: Condvar }
static READERS: OnceLock<Mutex<HashMap<u64, Arc<ReaderSlot>>>> = OnceLock::new();
fn readers() -> MutexGuard<'static, HashMap<u64, Arc<ReaderSlot>>> {
    lock(READERS.get_or_init(|| Mutex::new(HashMap::new())))
}
struct Lease(Arc<ReaderSlot>);
impl Drop for Lease {
    fn drop(&mut self) {
        lock(&self.0.state).busy = false;
        self.0.ready.notify_all();
    }
}
fn reserve(op: &str, raw: &str) -> Result<Lease, Value> {
    let id = parse_handle(op,raw)?;
    let slot = {readers().get(&id).cloned()}
        .ok_or_else(|| bridge_error(op,"invalidHandle","unknown reader handle"))?;
    {
        let mut state = lock(&slot.state);
        if state.closing { return Err(closed(op)); }
        if state.busy { return Err(bridge_error(op,"busy","reader already has an active operation")); }
        if state.reader.is_none() || slot.token.is_cancelled() { return Err(closed(op)); }
        state.busy = true;
    }
    Ok(Lease(slot))
}
enum Command {
    Manifest, Verify, Read { index: usize }, Extract { destination: PathBuf, options: ExtractOptions, index: Option<usize> },
}
fn run_command(op: &'static str, raw: &str, command: Command) -> Reply {
    let lease = reserve(op,raw)?;
    let token = lease.0.token.clone();
    let streaming = matches!(&command, Command::Read { .. });
    start_with_mode(op,token,streaming,move |context| {
        let mut reader = lock(&lease.0.state).reader.take().ok_or_else(|| closed(op))?;
        let events = context.clone();
        reader.set_progress_handler(move |p| progress(&events,p));
        let outcome = match command {
            Command::Manifest => manifest(op,&reader,&context),
            Command::Verify => reader.verify().map(read_result).map_err(|e| reader_error(op,e)),
            Command::Read { index } => reader.read_entry_to(index, &mut context.stream_sink())
                .map(read_result).map_err(|e| {
                    let e = match e {
                        ReaderError::Io(ref io) if io.get_ref().is_some_and(|inner| inner.is::<StreamCancelled>()) => ReaderError::Cancelled,
                        other => other,
                    };
                    reader_error(op,e)
                }),
            Command::Extract { destination,options,index } => match index {
                Some(i) => reader.extract_entry_to(i,&destination,options),
                None => reader.extract_to(&destination,options),
            }.map(extract_result).map_err(|e| reader_error(op,e)),
        };
        reader.clear_progress_handler();
        context.seal();
        // Cancellation is one-way. Preserve the actual Core terminal result,
        // especially publication success; never restore a cancelled reader.
        if !context.token().is_cancelled() {
            lock(&lease.0.state).reader = Some(reader);
        }
        outcome
    })
}

fn open_core(path: &Path, source: SourceInput, options: ReaderOptions, op: &str) -> Result<CoreReader, Value> {
    if !path.is_absolute() || path.components().any(|c| matches!(c,std::path::Component::ParentDir)) {
        return Err(reader_error(op,ReaderError::Invalid("absolute source without parent traversal required")));
    }
    let opened = match source {
        SourceInput::Single => {
            let source = File::open(path).map_err(|e| reader_error(op,e.into()))?;
            let source: Box<dyn ReadSeek> = Box::new(source);
            ArchiveReader::from_reader(source,options)
        }
        SourceInput::Split => {
            let source = SplitReader::open(path,&options.cancellation).map_err(|e| reader_error(op,e))?;
            let source: Box<dyn ReadSeek> = Box::new(source);
            ArchiveReader::from_reader(source,options)
        }
        SourceInput::Embedded {offset,length} => {
            let offset = u64_value(op,&offset)?;
            let length = u64_value(op,&length)?;
            let source = File::open(path).map_err(|e| reader_error(op,e.into()))?;
            let source: Box<dyn ReadSeek> = Box::new(source);
            ArchiveReader::from_region(source,offset,length,options)
        }
    };
    opened.map_err(|e| reader_error(op,e))
}
#[derive(Deserialize)]
#[serde(rename_all="camelCase", deny_unknown_fields)]
struct OpenInput { path: NativeUnits, source: SourceInput, #[serde(default)] options: OptionsInput }
#[derive(Deserialize)]
#[serde(rename_all="camelCase", deny_unknown_fields)]
struct ExtractionRequest { handle: String, destination: NativeUnits, #[serde(default)] options: ExtractInput, index: Option<String> }

#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_reader_open(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    const OP: &str = "reader_open";
    reply(OP,|| {
        let v = decode::<OpenInput>(OP,data,len)?;
        let path = native_path(OP,v.path)?;
        let token = CancellationToken::new();
        let options = v.options.apply(OP,token.clone())?;
        let id = allocate_handle(OP)?;
        start_with_token(OP,token,move |context| {
            let reader = open_core(&path,v.source,options,OP)?;
            let region = reader.region();
            let entry_count = reader.entries().len();
            context.seal();
            if context.token().is_cancelled() { return Err(reader_error(OP,ReaderError::Cancelled)); }
            let slot = Arc::new(ReaderSlot {token:context.token(),
                state:Mutex::new(ReaderState {reader:Some(reader),busy:false,closing:false}),ready:Condvar::new()});
            readers().insert(id,slot);
            Ok(json!({"handle":id.to_string(),"region":{"offset":region.offset().to_string(),"length":region.length().to_string()},
                "entryCount":entry_count.to_string()}))
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_reader_manifest(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    const OP: &str = "reader_manifest";
    reply(OP,|| run_command(OP,&decode::<HandleInput>(OP,data,len)?.handle,Command::Manifest))
}
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_reader_verify(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    const OP: &str = "reader_verify";
    reply(OP,|| run_command(OP,&decode::<HandleInput>(OP,data,len)?.handle,Command::Verify))
}
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_reader_extract(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    const OP: &str = "reader_extract";
    reply(OP,|| {
        let v = decode::<ExtractionRequest>(OP,data,len)?;
        let index = v.index.as_deref().map(|n| usize_value(OP,n)).transpose()?;
        run_command(OP,&v.handle,Command::Extract {destination:native_path(OP,v.destination)?,options:v.options.apply(OP)?,index})
    })
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadRequest { handle: String, index: String }

#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_reader_read_entry(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    const OP: &str = "reader_read_entry";
    reply(OP,|| {
        let v = decode::<ReadRequest>(OP,data,len)?;
        let index = usize_value(OP,&v.index)?;
        run_command(OP,&v.handle,Command::Read {index})
    })
}

#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_reader_close(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    const OP: &str = "reader_close";
    reply(OP,|| {
        let id = parse_handle(OP,&decode::<HandleInput>(OP,data,len)?.handle)?;
        let slot = {readers().get(&id).cloned()};
        if let Some(slot) = slot {
            let mut state = lock(&slot.state);
            state.closing = true;
            if state.busy { slot.token.cancel(); }
            while state.busy { state = slot.ready.wait(state).unwrap_or_else(|e| e.into_inner()); }
            drop(state.reader.take());
            readers().remove(&id);
        }
        Ok(Value::Null)
    })
}
