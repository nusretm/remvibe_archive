//! RVA V3 library: streaming archive writer, bounded reader and extraction.
mod format;
mod manifest;
mod metadata;
mod path;
mod writer;
mod reader;
mod extract;
mod codec;

pub use format::{ArchiveRegion, Footer, FormatError, Header, FOOTER_LEN, HEADER_LEN, VERSION};
pub use manifest::{ArchiveEntry, ArchiveManifest, Compression, EntryKind, FilePayload, ManifestError, ManifestLimits};
pub use metadata::{ArchiveMetadata, ArchiveTimestamp, MetadataCodecError};
pub use path::{ArchivePath, PathComponent, PathCodecError};
pub use writer::{ArchiveWriter, CancellationToken, MetadataCapture, WriterError, WriterOptions, WriterPhase, WriterProgress, WriterResult};
pub use reader::{ArchiveReader, ReaderError, ReaderOptions, ReaderPhase, ReaderProgress, ReadResult};
pub use extract::{ExtractOptions, ExtractResult, EntryMetadataResult, ExtractionSync};
pub use remvibe_filesystem_core::{MetadataPolicy, MetadataRequirement, MetadataApplyResult, MetadataApplyStatus, MetadataField};
