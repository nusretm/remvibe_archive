//! Private C ABI adapter. Archive algorithms remain in the root rlib.
mod operations;
mod path;
mod writer;

use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use std::{panic::{catch_unwind, AssertUnwindSafe}, ptr, slice};

pub struct RemVibeArchiveBuffer(Vec<u8>);
type Reply = Result<Value, Value>;

fn bridge_error(operation: &str, kind: &str, message: impl Into<String>) -> Value {
    json!({"domain":"bridge","kind":kind,"operation":operation,"message":message.into()})
}
fn envelope(result: Reply) -> Value {
    match result {
        Ok(value) => json!({"ok":true,"value":value}),
        Err(error) => json!({"ok":false,"error":error}),
    }
}
fn reply(operation: &str, f: impl FnOnce() -> Reply) -> *mut RemVibeArchiveBuffer {
    let result = catch_unwind(AssertUnwindSafe(|| serde_json::to_vec(&envelope(f()))));
    let bytes = match result {
        Ok(Ok(bytes)) => bytes,
        Ok(Err(_)) => return ptr::null_mut(),
        Err(_) => match serde_json::to_vec(&envelope(Err(bridge_error(operation,"panic","native call panicked")))) {
            Ok(bytes) => bytes,
            Err(_) => return ptr::null_mut(),
        },
    };
    Box::into_raw(Box::new(RemVibeArchiveBuffer(bytes)))
}

// Caller supplies readable bytes for the duration of this call.
unsafe fn decode<T: DeserializeOwned>(operation: &str, data: *const u8, len: usize) -> Result<T, Value> {
    if data.is_null() || len == 0 || len > isize::MAX as usize {
        return Err(bridge_error(operation,"invalidInput","invalid input buffer"));
    }
    serde_json::from_slice(slice::from_raw_parts(data, len))
        .map_err(|e| bridge_error(operation,"invalidInput",e.to_string()))
}

#[no_mangle]
pub extern "C" fn remvibe_archive_abi_version() -> u32 { 1 }

#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_buffer_data(buffer: *const RemVibeArchiveBuffer) -> *const u8 {
    buffer.as_ref().map_or(ptr::null(), |b| b.0.as_ptr())
}
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_buffer_len(buffer: *const RemVibeArchiveBuffer) -> usize {
    buffer.as_ref().map_or(0, |b| b.0.len())
}
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_buffer_free(buffer: *mut RemVibeArchiveBuffer) {
    if !buffer.is_null() { drop(Box::from_raw(buffer)); }
}
