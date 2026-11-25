//! RVA V3 library: format foundation and streaming archive writer.
mod format;
mod manifest;
mod metadata;
mod path;
mod writer;

pub use format::{ArchiveRegion, Footer, FormatError, Header, FOOTER_LEN, HEADER_LEN, VERSION};
pub use manifest::{ArchiveEntry, ArchiveManifest, Compression, EntryKind, FilePayload, ManifestError, ManifestLimits};
pub use metadata::{ArchiveMetadata, ArchiveTimestamp, MetadataCodecError};
pub use path::{ArchivePath, PathComponent, PathCodecError};
pub use writer::{ArchiveWriter, CancellationToken, MetadataCapture, WriterError, WriterOptions, WriterPhase, WriterProgress, WriterResult};
