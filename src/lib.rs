//! RVA V3 format foundation. No legacy or FFI dependencies.
//! Full manifest validation, archive reading and writing are later checkpoints.
mod format;

pub use format::{ArchiveRegion, Footer, FormatError, Header, FOOTER_LEN, HEADER_LEN, VERSION};
