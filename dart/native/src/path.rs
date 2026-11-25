//! Native filesystem path boundary, compatible with FS-FFI-01 units.
use crate::{bridge_error, decode, reply, RemVibeArchiveBuffer};
use serde::Deserialize;
use serde_json::{json, Value};
use std::ffi::{OsStr, OsString};

#[derive(Deserialize)]
#[serde(tag = "encoding", content = "units")]
pub(crate) enum NativeUnits {
    #[serde(rename = "windowsUtf16")]
    WindowsUtf16(Vec<u16>),
    #[serde(rename = "unixBytes")]
    UnixBytes(Vec<u8>),
}
impl NativeUnits {
    pub(crate) fn into_os(self) -> Result<OsString, &'static str> {
        match self {
            #[cfg(windows)]
            Self::WindowsUtf16(units) => {
                use std::os::windows::ffi::OsStringExt;
                if units.is_empty() || units.contains(&0) { return Err("empty or NUL-containing path"); }
                Ok(OsString::from_wide(&units))
            }
            #[cfg(unix)]
            Self::UnixBytes(units) => {
                use std::os::unix::ffi::OsStringExt;
                if units.is_empty() || units.contains(&0) { return Err("empty or NUL-containing path"); }
                Ok(OsString::from_vec(units))
            }
            #[cfg(windows)]
            Self::UnixBytes(units) => { drop(units); Err("native path encoding does not match host") }
            #[cfg(unix)]
            Self::WindowsUtf16(units) => { drop(units); Err("native path encoding does not match host") }
        }
    }
}
pub(crate) fn native(value: &OsStr) -> Value {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        json!({"encoding":"windowsUtf16","units":value.encode_wide().collect::<Vec<_>>()})
    }
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        json!({"encoding":"unixBytes","units":value.as_bytes()})
    }
}

/// Lexical diagnostic; does not access disk or normalize path units.
#[no_mangle]
pub unsafe extern "C" fn remvibe_archive_native_path_roundtrip(data: *const u8, len: usize) -> *mut RemVibeArchiveBuffer {
    reply("native_path_roundtrip", || {
        let path = decode::<NativeUnits>("native_path_roundtrip", data, len)?
            .into_os().map_err(|e| bridge_error("native_path_roundtrip","invalidInput",e))?;
        Ok(native(&path))
    })
}
