//! RVA V3 library. Format foundation; streaming writer/reader follow separately.
mod format;
mod manifest;
mod metadata;
mod path;

pub use format::{ArchiveRegion, Footer, FormatError, Header, FOOTER_LEN, HEADER_LEN, VERSION};
pub use manifest::{ArchiveEntry, ArchiveManifest, Compression, EntryKind, FilePayload, ManifestError, ManifestLimits};
pub use metadata::{ArchiveMetadata, ArchiveTimestamp, MetadataCodecError};
pub use path::{ArchivePath, PathComponent, PathCodecError};
