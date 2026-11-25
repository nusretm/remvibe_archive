//! Lossless archive path components. OS filesystem operations remain in FileSystem.
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::{Deserialize, Serialize};
use std::{ffi::{OsStr, OsString}, fmt, path::{Path, PathBuf}};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathCodecError(pub &'static str);
impl fmt::Display for PathCodecError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { f.write_str(self.0) }
}
impl std::error::Error for PathCodecError {}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "encoding", content = "value", rename_all = "camelCase", deny_unknown_fields)]
pub enum PathComponent {
    Utf8(String),
    UnixBytes(String),
    WindowsUtf16(String),
}

fn canonical_bytes(s: &str) -> Result<Vec<u8>, PathCodecError> {
    let bytes = STANDARD.decode(s).map_err(|_| PathCodecError("invalid base64 name"))?;
    if STANDARD.encode(&bytes) != s { return Err(PathCodecError("noncanonical base64 name")); }
    Ok(bytes)
}

fn wide(s: &str) -> Result<Vec<u16>, PathCodecError> {
    let bytes = canonical_bytes(s)?;
    if bytes.len() % 2 != 0 { return Err(PathCodecError("odd UTF-16 byte length")); }
    Ok(bytes.chunks_exact(2).map(|b| u16::from_le_bytes([b[0], b[1]])).collect())
}

impl PathComponent {
    pub fn validate(&self) -> Result<(), PathCodecError> {
        match self {
            Self::Utf8(s) => {
                if s.is_empty() || s == "." || s == ".." || s.contains('/') || s.contains('\0') {
                    return Err(PathCodecError("invalid UTF-8 path component"));
                }
            }
            Self::UnixBytes(s) => {
                let b = canonical_bytes(s)?;
                if b.is_empty() || b.contains(&0) || b.contains(&b'/') || std::str::from_utf8(&b).is_ok() {
                    return Err(PathCodecError("invalid or noncanonical Unix name"));
                }
            }
            Self::WindowsUtf16(s) => {
                let w = wide(s)?;
                if w.is_empty() || w.iter().any(|&c| matches!(c, 0 | 47 | 92 | 58))
                    || String::from_utf16(&w).is_ok() {
                    return Err(PathCodecError("invalid or noncanonical Windows name"));
                }
            }
        }
        Ok(())
    }

    pub fn from_native(name: &OsStr) -> Result<Self, PathCodecError> {
        let value = if let Some(s) = name.to_str() {
            Self::Utf8(s.to_owned())
        } else {
            #[cfg(unix)]
            {
                use std::os::unix::ffi::OsStrExt;
                Self::UnixBytes(STANDARD.encode(name.as_bytes()))
            }
            #[cfg(windows)]
            {
                use std::os::windows::ffi::OsStrExt;
                let bytes: Vec<u8> = name.encode_wide().flat_map(u16::to_le_bytes).collect();
                Self::WindowsUtf16(STANDARD.encode(bytes))
            }
            #[cfg(not(any(unix, windows)))]
            { return Err(PathCodecError("unsupported native filename encoding")); }
        };
        value.validate()?;
        Ok(value)
    }

    pub fn to_native(&self) -> Result<OsString, PathCodecError> {
        self.validate()?;
        let name = match self {
            Self::Utf8(s) => OsString::from(s),
            Self::UnixBytes(s) => {
                #[cfg(unix)]
                { use std::os::unix::ffi::OsStringExt; OsString::from_vec(canonical_bytes(s)?) }
                #[cfg(not(unix))]
                { let _ = s; return Err(PathCodecError("Unix name not representable on target")); }
            }
            Self::WindowsUtf16(s) => {
                #[cfg(windows)]
                { use std::os::windows::ffi::OsStringExt; OsString::from_wide(&wide(s)?) }
                #[cfg(not(windows))]
                { let _ = s; return Err(PathCodecError("Windows name not representable on target")); }
            }
        };
        // This is a serialization boundary, not a replacement for target filesystem
        // collision/alias checks at extraction. Reject separators and prefixes on target.
        let mut parts = Path::new(&name).components();
        match (parts.next(), parts.next()) {
            (Some(std::path::Component::Normal(n)), None) if n == name.as_os_str() => {}
            _ => return Err(PathCodecError("not a single native path component")),
        }
        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStrExt;
            if name.encode_wide().any(|c| matches!(c, 0..=31 | 34 | 42 | 58 | 60 | 62 | 63 | 124)) {
                return Err(PathCodecError("invalid Windows target name"));
            }
            let units: Vec<u16> = name.encode_wide().collect();
            if matches!(units.last().copied(), Some(32 | 46)) {
                return Err(PathCodecError("Windows target name ends in space or dot"));
            }
            // Check reserved device stems, including Win32 superscript digits.
            // Lossy text is used ONLY for rejecting reserved names, never to
            // construct the actual path or change native code units.
            let display = String::from_utf16_lossy(&units);
            let stem = display.split('.').next().unwrap_or("").trim_end_matches(' ').to_ascii_uppercase();
            if matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$")
                || stem.strip_prefix("COM").or_else(|| stem.strip_prefix("LPT"))
                    .is_some_and(|n| matches!(n, "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³")) {
                return Err(PathCodecError("reserved Windows target device name"));
            }
        }
        Ok(name)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ArchivePath(pub Vec<PathComponent>);

impl ArchivePath {
    pub fn validate(&self) -> Result<(), PathCodecError> {
        if self.0.is_empty() { return Err(PathCodecError("empty archive path")); }
        for component in &self.0 { component.validate()?; }
        Ok(())
    }

    /// Accept explicit relative paths only. No normalization of traversal.
    pub fn from_relative(path: &Path) -> Result<Self, PathCodecError> {
        let mut components = Vec::new();
        for part in path.components() {
            match part {
                std::path::Component::Normal(name) => components.push(PathComponent::from_native(name)?),
                _ => return Err(PathCodecError("archive path must be relative and normal")),
            }
        }
        let value = Self(components);
        value.validate()?;
        Ok(value)
    }

    pub fn to_relative(&self) -> Result<PathBuf, PathCodecError> {
        self.validate()?;
        let mut path = PathBuf::new();
        for component in &self.0 { path.push(component.to_native()?); }
        Ok(path)
    }
}
