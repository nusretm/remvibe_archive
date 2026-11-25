//! RVA manifest wire model and structural/integrity validation.
use crate::{ArchiveMetadata, ArchivePath, ArchiveRegion, Footer, HEADER_LEN};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{collections::HashMap, fmt};

#[derive(Debug)]
pub enum ManifestError {
    Format(crate::FormatError),
    Json(serde_json::Error),
    Invalid(&'static str),
}
impl fmt::Display for ManifestError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self { Self::Format(e) => e.fmt(f), Self::Json(e) => e.fmt(f), Self::Invalid(s) => f.write_str(s) }
    }
}
impl std::error::Error for ManifestError {}
impl From<crate::FormatError> for ManifestError { fn from(e: crate::FormatError) -> Self { Self::Format(e) } }
impl From<serde_json::Error> for ManifestError { fn from(e: serde_json::Error) -> Self { Self::Json(e) } }

/// Reader/writer resource policy, not a format restriction.
#[derive(Debug, Clone, Copy)]
pub struct ManifestLimits {
    pub max_manifest_bytes: u64,
    pub max_entries: usize,
    pub max_depth: usize,
    pub max_file_bytes: u64,
    pub max_total_bytes: u64,
}
impl Default for ManifestLimits {
    fn default() -> Self {
        Self { max_manifest_bytes: 64 * 1024 * 1024, max_entries: 1_000_000, max_depth: 256,
            max_file_bytes: u64::MAX, max_total_bytes: u64::MAX }
    }
}
impl ManifestLimits {
    /// Must run before allocating a manifest buffer.
    pub fn manifest_range(&self, footer: Footer, region: ArchiveRegion) -> Result<std::ops::Range<u64>, ManifestError> {
        let range = footer.manifest_range(region)?;
        if footer.manifest_length > self.max_manifest_bytes || footer.manifest_original_length > self.max_manifest_bytes
            || usize::try_from(footer.manifest_length).is_err() || usize::try_from(footer.manifest_original_length).is_err() {
            return Err(ManifestError::Invalid("manifest exceeds byte limit"));
        }
        Ok(range)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Compression { None, Zlib, Zstd }

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FilePayload {
    pub offset: u64,
    pub stored_size: u64,
    pub original_size: u64,
    pub compression: Compression,
    /// Lowercase SHA-256 hex of uncompressed file bytes.
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum EntryKind { Directory, File { payload: FilePayload } }

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ArchiveEntry {
    pub path: ArchivePath,
    pub metadata: ArchiveMetadata,
    pub entry: EntryKind,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ArchiveManifest { pub entries: Vec<ArchiveEntry> }

impl ArchiveManifest {
    /// Validate before writer encodes or reader exposes entries.
    pub fn validate(&self, manifest_offset: u64, limits: &ManifestLimits) -> Result<(), ManifestError> {
        let invalid = ManifestError::Invalid;
        if self.entries.len() > limits.max_entries { return Err(invalid("too many entries")); }
        let mut paths = HashMap::new();
        let mut next = HEADER_LEN as u64;
        let mut total = 0u64;
        for e in &self.entries {
            if e.path.0.len() > limits.max_depth { return Err(invalid("path exceeds depth limit")); }
            e.path.validate().map_err(|_| invalid("invalid archive path"))?;
            e.metadata.validate().map_err(|_| invalid("invalid metadata"))?;
            if paths.insert(e.path.0.as_slice(), matches!(&e.entry, EntryKind::File { .. })).is_some() {
                return Err(invalid("duplicate archive path"));
            }
            if let EntryKind::File { payload: p } = &e.entry {
                if p.offset != next || p.original_size > limits.max_file_bytes {
                    return Err(invalid("invalid payload range or size"));
                }
                if p.compression == Compression::None && p.stored_size != p.original_size {
                    return Err(invalid("uncompressed payload size mismatch"));
                }
                if p.compression != Compression::None && p.stored_size == 0 {
                    return Err(invalid("empty compressed stream"));
                }
                if p.sha256.len() != 64 || !p.sha256.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
                    return Err(invalid("invalid SHA-256 hex"));
                }
                if e.metadata.size.is_some_and(|size| size != p.original_size) {
                    return Err(invalid("file metadata size mismatch"));
                }
                next = next.checked_add(p.stored_size).ok_or_else(|| invalid("payload offset overflow"))?;
                if next > manifest_offset { return Err(invalid("payload exceeds manifest offset")); }
                total = total.checked_add(p.original_size).ok_or_else(|| invalid("total size overflow"))?;
                if total > limits.max_total_bytes { return Err(invalid("total size limit exceeded")); }
            }
        }
        if next != manifest_offset { return Err(invalid("unexplained payload bytes")); }
        for e in &self.entries {
            for depth in 1..e.path.0.len() {
                if paths.get(&e.path.0[..depth]) == Some(&true) {
                    return Err(invalid("file is an ancestor of another entry"));
                }
            }
        }
        Ok(())
    }

    pub fn encode(&self, manifest_offset: u64, limits: &ManifestLimits) -> Result<(Vec<u8>, Footer), ManifestError> {
        self.encode_with_compression(manifest_offset, limits, Compression::None, 6, 3)
    }

    pub fn encode_with_compression(&self, manifest_offset: u64, limits: &ManifestLimits, compression: Compression,
        zlib_level: u32, zstd_level: i32) -> Result<(Vec<u8>, Footer), ManifestError> {
        self.validate(manifest_offset, limits)?;
        let bytes = serde_json::to_vec(self)?;
        let manifest_length = u64::try_from(bytes.len()).map_err(|_| ManifestError::Invalid("manifest length overflow"))?;
        if manifest_length > limits.max_manifest_bytes { return Err(ManifestError::Invalid("manifest exceeds byte limit")); }
        let digest = Sha256::digest(&bytes).into();
        let stored = crate::codec::encode_manifest(bytes, compression, zlib_level, zstd_level)
            .map_err(|_| ManifestError::Invalid("manifest compression failed"))?;
        let stored_length = stored.len() as u64;
        if stored_length > limits.max_manifest_bytes { return Err(ManifestError::Invalid("stored manifest exceeds byte limit")); }
        let footer = Footer { manifest_offset, manifest_length: stored_length, manifest_original_length: manifest_length,
            manifest_compression: compression, manifest_sha256: digest };
        Ok((stored, footer))
    }

    pub fn decode(bytes: &[u8], footer: Footer, region: ArchiveRegion, limits: &ManifestLimits) -> Result<Self, ManifestError> {
        limits.manifest_range(footer, region)?;
        if u64::try_from(bytes.len()).ok() != Some(footer.manifest_length) {
            return Err(ManifestError::Invalid("manifest length mismatch"));
        }
        let decoded = crate::codec::decode_manifest(bytes, footer.manifest_compression, footer.manifest_original_length as usize)
            .map_err(|_| ManifestError::Invalid("invalid compressed manifest"))?;
        let digest: [u8; 32] = Sha256::digest(decoded.as_ref()).into();
        if digest != footer.manifest_sha256 { return Err(ManifestError::Invalid("manifest hash mismatch")); }
        let manifest: Self = serde_json::from_slice(decoded.as_ref())?;
        manifest.validate(footer.manifest_offset, limits)?;
        Ok(manifest)
    }
}
