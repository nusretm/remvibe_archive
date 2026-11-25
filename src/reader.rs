//! Bounded RVA reading. All operations reuse the same owned seekable source.
use crate::{ArchiveEntry, ArchiveManifest, ArchivePath, ArchiveRegion, CancellationToken, Compression,
    EntryKind, Footer, FormatError, Header, ManifestError, ManifestLimits, MetadataCodecError,
    PathCodecError, FOOTER_LEN, HEADER_LEN};
use flate2::{Decompress, FlushDecompress, Status};
use remvibe_filesystem_core::{FileSystemError, MetadataApplyResult};
use sha2::{Digest, Sha256};
use std::{error::Error, fmt, fs::File, io::{self, Read, Seek, SeekFrom, Write}, path::{Path, PathBuf}};

#[derive(Debug)]
pub enum ReaderError {
    Io(io::Error),
    Format(FormatError),
    Manifest(ManifestError),
    Path(PathCodecError),
    MetadataCodec(MetadataCodecError),
    FileSystem(FileSystemError),
    Invalid(&'static str),
    EntryNotFound(usize),
    NotFile(usize),
    Integrity { index: usize, reason: &'static str },
    DestinationExists(PathBuf),
    Collision(PathBuf),
    Metadata { path: ArchivePath, result: MetadataApplyResult },
    Cancelled,
    Cleanup { path: PathBuf, original: Box<ReaderError>, source: FileSystemError },
}
impl fmt::Display for ReaderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(e) => write!(f, "{e}"),
            Self::Format(e) => write!(f, "{e}"),
            Self::Manifest(e) => write!(f, "{e}"),
            Self::Path(e) => write!(f, "{e}"),
            Self::MetadataCodec(e) => write!(f, "{e}"),
            Self::FileSystem(e) => write!(f, "{e}"),
            Self::Invalid(s) => f.write_str(s),
            Self::EntryNotFound(i) => write!(f, "archive entry not found: {i}"),
            Self::NotFile(i) => write!(f, "archive entry is not a file: {i}"),
            Self::Integrity { index, reason } => write!(f, "entry {index}: {reason}"),
            Self::DestinationExists(p) => write!(f, "extraction destination exists: {p:?}"),
            Self::Collision(p) => write!(f, "target path collision: {p:?}"),
            Self::Metadata { path, result } => write!(f, "metadata application failed at {path:?}: {:?}", result.fields),
            Self::Cancelled => f.write_str("archive operation cancelled"),
            Self::Cleanup { path, original, source } => write!(f, "{original}; staging cleanup failed at {path:?}: {source}"),
        }
    }
}
impl Error for ReaderError {}
impl From<io::Error> for ReaderError {
    fn from(e: io::Error) -> Self {
        if e.get_ref().is_some_and(|inner| inner.is::<crate::split::SplitCancelled>()) { Self::Cancelled }
        else { Self::Io(e) }
    }
}
impl From<FormatError> for ReaderError { fn from(e: FormatError) -> Self { Self::Format(e) } }
impl From<ManifestError> for ReaderError { fn from(e: ManifestError) -> Self { Self::Manifest(e) } }
impl From<PathCodecError> for ReaderError { fn from(e: PathCodecError) -> Self { Self::Path(e) } }
impl From<MetadataCodecError> for ReaderError { fn from(e: MetadataCodecError) -> Self { Self::MetadataCodec(e) } }
impl From<FileSystemError> for ReaderError { fn from(e: FileSystemError) -> Self { Self::FileSystem(e) } }

#[derive(Debug, Clone)]
pub struct ReaderOptions {
    pub limits: ManifestLimits,
    /// Per streaming buffer; Zlib uses separate input and output buffers.
    pub buffer_size: usize,
    pub cancellation: CancellationToken,
}
impl Default for ReaderOptions {
    fn default() -> Self {
        Self { limits: ManifestLimits::default(), buffer_size: 1024 * 1024, cancellation: CancellationToken::new() }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReaderPhase { Reading, Verifying, Preparing, Extracting, EntryCompleted, ApplyingMetadata, Finalizing, Completed }

#[derive(Debug, Clone)]
pub struct ReaderProgress {
    pub phase: ReaderPhase,
    pub path: Option<ArchivePath>,
    pub entries_completed: usize,
    pub total_entries: usize,
    pub output_bytes: u64,
    pub total_bytes: u64,
    pub entry_bytes: u64,
    pub entry_total_bytes: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReadResult { pub entry_count: usize, pub output_bytes: u64 }

pub(crate) struct Operation {
    pub(crate) total_entries: usize,
    pub(crate) total_bytes: u64,
    pub(crate) entries_completed: usize,
    pub(crate) output_bytes: u64,
}
impl Operation {
    pub(crate) fn new(total_entries: usize, total_bytes: u64) -> Self {
        Self { total_entries, total_bytes, entries_completed: 0, output_bytes: 0 }
    }
    pub(crate) fn result(&self) -> ReadResult {
        ReadResult { entry_count: self.entries_completed, output_bytes: self.output_bytes }
    }
}

/// Manifest is validated on open. Payloads are verified only when read or
/// explicitly verified. The caller must keep the backing source immutable.
pub struct ArchiveReader<R: Read + Seek = File> {
    source: R,
    region: ArchiveRegion,
    manifest: ArchiveManifest,
    pub(crate) options: ReaderOptions,
    progress: Option<Box<dyn FnMut(&ReaderProgress) + Send>>,
    input: Vec<u8>,
    output: Vec<u8>,
}

impl ArchiveReader<File> {
    pub fn open(path: &Path, options: ReaderOptions) -> Result<Self, ReaderError> {
        Self::from_reader(File::open(path)?, options)
    }
    pub fn open_region(path: &Path, offset: u64, length: u64, options: ReaderOptions) -> Result<Self, ReaderError> {
        Self::from_region(File::open(path)?, offset, length, options)
    }
}

fn allocate(len: usize) -> Result<Vec<u8>, ReaderError> {
    let mut bytes = Vec::new();
    bytes.try_reserve_exact(len).map_err(|_| ReaderError::Invalid("cannot allocate reader buffer"))?;
    bytes.resize(len, 0);
    Ok(bytes)
}
fn check_cancel(token: &CancellationToken) -> Result<(), ReaderError> {
    if token.is_cancelled() { Err(ReaderError::Cancelled) } else { Ok(()) }
}

impl<R: Read + Seek> ArchiveReader<R> {
    pub fn from_reader(mut source: R, options: ReaderOptions) -> Result<Self, ReaderError> {
        let length = source.seek(SeekFrom::End(0))?;
        Self::from_region(source, 0, length, options)
    }
    pub fn from_region(mut source: R, offset: u64, length: u64, options: ReaderOptions) -> Result<Self, ReaderError> {
        check_cancel(&options.cancellation)?;
        if options.buffer_size == 0 || options.buffer_size > 64 * 1024 * 1024 {
            return Err(ReaderError::Invalid("invalid reader buffer size"));
        }
        let physical_length = source.seek(SeekFrom::End(0))?;
        let region = ArchiveRegion::new(offset, length, physical_length)?;
        source.seek(SeekFrom::Start(region.offset()))?;
        let mut header = [0; HEADER_LEN];
        source.read_exact(&mut header)?;
        Header::decode(&header)?;
        source.seek(SeekFrom::Start(region.absolute_range(region.footer_offset(), FOOTER_LEN as u64)?.start))?;
        let mut footer = [0; FOOTER_LEN];
        source.read_exact(&mut footer)?;
        let footer = Footer::decode(&footer)?;
        let range = options.limits.manifest_range(footer, region)?;
        let mut bytes = allocate(usize::try_from(footer.manifest_length).map_err(|_| ReaderError::Invalid("manifest too large"))?)?;
        source.seek(SeekFrom::Start(range.start))?;
        for chunk in bytes.chunks_mut(options.buffer_size) {
            check_cancel(&options.cancellation)?;
            source.read_exact(chunk)?;
        }
        let manifest = ArchiveManifest::decode(&bytes, footer, region, &options.limits)?;
        drop(bytes);
        check_cancel(&options.cancellation)?;
        let input = allocate(options.buffer_size)?;
        let output = allocate(options.buffer_size)?;
        Ok(Self { source, region, manifest, options, progress: None, input, output })
    }
    pub fn region(&self) -> ArchiveRegion { self.region }
    pub fn manifest(&self) -> &ArchiveManifest { &self.manifest }
    pub fn entries(&self) -> &[ArchiveEntry] { &self.manifest.entries }
    pub fn set_progress_handler(&mut self, handler: impl FnMut(&ReaderProgress) + Send + 'static) {
        self.progress = Some(Box::new(handler));
    }
    pub fn clear_progress_handler(&mut self) { self.progress = None; }
    pub(crate) fn check_cancel(&self) -> Result<(), ReaderError> { check_cancel(&self.options.cancellation) }

    pub(crate) fn event(&mut self, op: &Operation, phase: ReaderPhase, path: Option<&ArchivePath>,
        entry_bytes: u64, entry_total_bytes: Option<u64>) {
        emit(&mut self.progress, op, phase, path, entry_bytes, entry_total_bytes);
    }
    pub(crate) fn all_operation(&self) -> Result<Operation, ReaderError> {
        let mut total = 0u64;
        for entry in self.entries() {
            if let EntryKind::File { payload } = &entry.entry {
                total = total.checked_add(payload.original_size).ok_or(ReaderError::Invalid("total size overflow"))?;
            }
        }
        Ok(Operation::new(self.entries().len(), total))
    }
    pub(crate) fn file_operation(&self, index: usize) -> Result<Operation, ReaderError> {
        let entry = self.entries().get(index).ok_or(ReaderError::EntryNotFound(index))?;
        match &entry.entry {
            EntryKind::File { payload } => Ok(Operation::new(1, payload.original_size)),
            EntryKind::Directory => Err(ReaderError::NotFile(index)),
        }
    }
    /// Stream one file to a caller-owned sink. Bytes received before Ok are
    /// provisional: on any error the caller must discard them. No whole-file allocation.
    pub fn read_entry_to(&mut self, index: usize, destination: &mut impl Write) -> Result<ReadResult, ReaderError> {
        let mut op = self.file_operation(index)?;
        self.pump(index, destination, &mut op, ReaderPhase::Reading)?;
        self.check_cancel()?;
        self.event(&op, ReaderPhase::Completed, None, 0, None);
        Ok(op.result())
    }
    /// Verify every file stream and hash, without extracting or applying metadata.
    pub fn verify(&mut self) -> Result<ReadResult, ReaderError> {
        let mut op = self.all_operation()?;
        self.check_cancel()?;
        for index in 0..self.entries().len() {
            if matches!(&self.entries()[index].entry, EntryKind::Directory) {
                self.complete_directory(index, &mut op)?;
            } else {
                self.pump(index, &mut io::sink(), &mut op, ReaderPhase::Verifying)?;
            }
        }
        self.check_cancel()?;
        self.event(&op, ReaderPhase::Completed, None, 0, None);
        Ok(op.result())
    }
    pub(crate) fn complete_directory(&mut self, index: usize, op: &mut Operation) -> Result<(), ReaderError> {
        self.check_cancel()?;
        let path = self.entries()[index].path.clone();
        op.entries_completed += 1;
        self.event(op, ReaderPhase::EntryCompleted, Some(&path), 0, None);
        self.check_cancel()
    }
    pub(crate) fn pump(&mut self, index: usize, destination: &mut impl Write, op: &mut Operation,
        phase: ReaderPhase) -> Result<(), ReaderError> {
        self.check_cancel()?;
        let entry = self.entries().get(index).ok_or(ReaderError::EntryNotFound(index))?;
        let path = entry.path.clone();
        let EntryKind::File { payload } = &entry.entry else { return Err(ReaderError::NotFile(index)); };
        let payload = payload.clone();
        let bad = |reason| ReaderError::Integrity { index, reason };
        let range = self.region.absolute_range(payload.offset, payload.stored_size)?;
        self.source.seek(SeekFrom::Start(range.start))?;
        let mut remaining = payload.stored_size;
        let mut count = 0u64;
        let mut hash = Sha256::new();
        let token = &self.options.cancellation;
        let progress = &mut self.progress;
        let mut accept = |bytes: &[u8]| -> Result<(), ReaderError> {
            check_cancel(token)?;
            if bytes.is_empty() { return Ok(()); }
            count = count.checked_add(bytes.len() as u64).ok_or_else(|| bad("decoded size overflow"))?;
            if count > payload.original_size { return Err(bad("decoded output exceeds declared size")); }
            destination.write_all(bytes)?;
            hash.update(bytes);
            op.output_bytes = op.output_bytes.checked_add(bytes.len() as u64).ok_or_else(|| bad("output total overflow"))?;
            emit(progress, op, phase, Some(&path), count, Some(payload.original_size));
            Ok(())
        };
        match payload.compression {
            Compression::None => {
                while remaining != 0 {
                    check_cancel(token)?;
                    let n = remaining.min(self.input.len() as u64) as usize;
                    self.source.read_exact(&mut self.input[..n])?;
                    remaining -= n as u64;
                    accept(&self.input[..n])?;
                }
            }
            Compression::Zlib => {
                let mut decoder = Decompress::new(true);
                let mut pos = 0usize;
                let mut end = 0usize;
                loop {
                    check_cancel(token)?;
                    if pos == end && remaining != 0 {
                        let n = remaining.min(self.input.len() as u64) as usize;
                        self.source.read_exact(&mut self.input[..n])?;
                        remaining -= n as u64;
                        pos = 0; end = n;
                    }
                    let before_in = decoder.total_in();
                    let before_out = decoder.total_out();
                    let status = decoder.decompress(&self.input[pos..end], &mut self.output, FlushDecompress::None)
                        .map_err(|_| bad("invalid zlib stream"))?;
                    let used = (decoder.total_in() - before_in) as usize;
                    let produced = (decoder.total_out() - before_out) as usize;
                    pos += used;
                    accept(&self.output[..produced])?;
                    if status == Status::StreamEnd {
                        if pos != end || remaining != 0 || decoder.total_in() != payload.stored_size {
                            return Err(bad("trailing compressed payload bytes"));
                        }
                        break;
                    }
                    if used == 0 && produced == 0 { return Err(bad("truncated or stalled zlib stream")); }
                }
            }
            Compression::Zstd => {
                crate::codec::decode_zstd(&mut self.source, payload.stored_size, &mut self.input, &mut self.output,
                    || check_cancel(token), &mut accept).map_err(|e| match e {
                        ReaderError::Io(ref io) if io.kind() == io::ErrorKind::InvalidData => bad("invalid or trailing zstd frame"),
                        other => other,
                    })?;
            }
        }
        drop(accept);
        check_cancel(token)?;
        if count != payload.original_size { return Err(bad("decoded size mismatch")); }
        if format!("{:x}", hash.finalize()) != payload.sha256 { return Err(bad("payload SHA-256 mismatch")); }
        op.entries_completed += 1;
        emit(progress, op, ReaderPhase::EntryCompleted, Some(&path), count, Some(payload.original_size));
        check_cancel(token)
    }
}

fn emit(handler: &mut Option<Box<dyn FnMut(&ReaderProgress) + Send>>, op: &Operation, phase: ReaderPhase,
    path: Option<&ArchivePath>, entry_bytes: u64, entry_total_bytes: Option<u64>) {
    if let Some(handler) = handler {
        handler(&ReaderProgress { phase, path: path.cloned(), entries_completed: op.entries_completed,
            total_entries: op.total_entries, output_bytes: op.output_bytes, total_bytes: op.total_bytes,
            entry_bytes, entry_total_bytes });
    }
}
