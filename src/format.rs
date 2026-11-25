//! Fixed RVA V3 envelope and checked region-relative bounds.
use std::{error::Error, fmt};
use crate::manifest::Compression;

pub const HEADER_LEN: usize = 16;
pub const FOOTER_LEN: usize = 72;
pub const VERSION: u16 = 3;
const HEADER_MAGIC: [u8; 8] = *b"RVA3\r\n\x1a\n";
const FOOTER_MAGIC: [u8; 8] = *b"RVA3CMP\n";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FormatError {
    InvalidHeaderMagic,
    UnsupportedVersion(u16),
    UnsupportedFlags(u16),
    NonzeroReserved,
    InvalidFooterMagic,
    InvalidRegion,
    InvalidManifestRange,
}

impl fmt::Display for FormatError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidHeaderMagic => f.write_str("invalid RVA header magic"),
            Self::UnsupportedVersion(v) => write!(f, "unsupported RVA version {v}"),
            Self::UnsupportedFlags(v) => write!(f, "unsupported RVA flags {v:#x}"),
            Self::NonzeroReserved => f.write_str("nonzero RVA reserved field"),
            Self::InvalidFooterMagic => f.write_str("invalid RVA footer magic"),
            Self::InvalidRegion => f.write_str("invalid RVA region"),
            Self::InvalidManifestRange => f.write_str("invalid RVA manifest range"),
        }
    }
}
impl Error for FormatError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Header;
impl Header {
    pub fn encode(self) -> [u8; HEADER_LEN] {
        let mut bytes = [0; HEADER_LEN];
        bytes[..8].copy_from_slice(&HEADER_MAGIC);
        bytes[8..10].copy_from_slice(&VERSION.to_be_bytes());
        bytes
    }

    pub fn decode(bytes: &[u8; HEADER_LEN]) -> Result<Self, FormatError> {
        if bytes[..8] != HEADER_MAGIC { return Err(FormatError::InvalidHeaderMagic); }
        let version = u16::from_be_bytes([bytes[8], bytes[9]]);
        if version != VERSION { return Err(FormatError::UnsupportedVersion(version)); }
        let flags = u16::from_be_bytes([bytes[10], bytes[11]]);
        if flags != 0 { return Err(FormatError::UnsupportedFlags(flags)); }
        if bytes[12..].iter().any(|&b| b != 0) { return Err(FormatError::NonzeroReserved); }
        Ok(Self)
    }
}

/// A checked byte region within a seekable source, measured in bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ArchiveRegion {
    offset: u64,
    length: u64,
}

impl ArchiveRegion {
    pub fn new(offset: u64, length: u64, source_length: u64) -> Result<Self, FormatError> {
        let end = offset.checked_add(length).ok_or(FormatError::InvalidRegion)?;
        if length < (HEADER_LEN + FOOTER_LEN + 1) as u64 || end > source_length {
            return Err(FormatError::InvalidRegion);
        }
        Ok(Self { offset, length })
    }

    pub fn offset(self) -> u64 { self.offset }
    pub fn length(self) -> u64 { self.length }
    pub fn footer_offset(self) -> u64 { self.length - FOOTER_LEN as u64 }

    /// Convert a region-relative range to its physical source offset.
    pub fn absolute_range(self, offset: u64, length: u64) -> Result<std::ops::Range<u64>, FormatError> {
        let end = offset.checked_add(length).ok_or(FormatError::InvalidRegion)?;
        if end > self.length { return Err(FormatError::InvalidRegion); }
        // The region constructor has already checked offset + region length.
        Ok((self.offset + offset)..(self.offset + end))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Footer {
    pub manifest_offset: u64,
    pub manifest_length: u64,
    pub manifest_original_length: u64,
    pub manifest_compression: Compression,
    pub manifest_sha256: [u8; 32],
}

impl Footer {
    pub fn encode(self) -> [u8; FOOTER_LEN] {
        let mut bytes = [0; FOOTER_LEN];
        bytes[..8].copy_from_slice(&FOOTER_MAGIC);
        bytes[8..16].copy_from_slice(&self.manifest_offset.to_be_bytes());
        bytes[16..24].copy_from_slice(&self.manifest_length.to_be_bytes());
        bytes[24..32].copy_from_slice(&self.manifest_original_length.to_be_bytes());
        bytes[32] = match self.manifest_compression { Compression::None => 0, Compression::Zlib => 1, Compression::Zstd => 2 };
        bytes[40..].copy_from_slice(&self.manifest_sha256);
        bytes
    }

    pub fn decode(bytes: &[u8; FOOTER_LEN]) -> Result<Self, FormatError> {
        if bytes[..8] != FOOTER_MAGIC { return Err(FormatError::InvalidFooterMagic); }
        let mut offset = [0; 8];
        let mut length = [0; 8];
        let mut digest = [0; 32];
        offset.copy_from_slice(&bytes[8..16]);
        length.copy_from_slice(&bytes[16..24]);
        let mut original = [0; 8];
        original.copy_from_slice(&bytes[24..32]);
        if bytes[33..40].iter().any(|&b| b != 0) { return Err(FormatError::NonzeroReserved); }
        let manifest_compression = match bytes[32] { 0 => Compression::None, 1 => Compression::Zlib, 2 => Compression::Zstd, _ => return Err(FormatError::InvalidManifestRange) };
        digest.copy_from_slice(&bytes[40..]);
        Ok(Self {
            manifest_offset: u64::from_be_bytes(offset),
            manifest_length: u64::from_be_bytes(length),
            manifest_original_length: u64::from_be_bytes(original),
            manifest_compression,
            manifest_sha256: digest,
        })
    }

    /// Structural check only; manifest size limit, hash and schema checked separately.
    pub fn manifest_range(self, region: ArchiveRegion) -> Result<std::ops::Range<u64>, FormatError> {
        if self.manifest_offset < HEADER_LEN as u64
            || self.manifest_length == 0 || self.manifest_original_length == 0
            || (self.manifest_compression == Compression::None && self.manifest_length != self.manifest_original_length)
            || self.manifest_offset.checked_add(self.manifest_length) != Some(region.footer_offset())
        {
            return Err(FormatError::InvalidManifestRange);
        }
        region.absolute_range(self.manifest_offset, self.manifest_length)
    }
}
