//! Single-pass, manifest-last archive creation. No transport or extraction logic.
use crate::{ArchiveEntry, ArchiveManifest, ArchiveMetadata, ArchivePath, Compression, EntryKind,
    FilePayload, Header, ManifestError, ManifestLimits, PathCodecError, PathComponent, ArchiveLayout, SPLIT_PART_HEADER_LEN};
use crate::split::{SplitOutput, SplitCancelled};
use flate2::write::ZlibEncoder;
use remvibe_filesystem_core::{FileSystemError, FileSystemItem, FileSystemItemKind, FileSystemLocation,
    FileSystemMetadata, FileSystemService};
use sha2::{Digest, Sha256};
use std::{collections::HashSet, error::Error, fmt, fs::{self, File, OpenOptions},
    io::{self, Read, Seek, Write}, path::{Path, PathBuf},
    sync::{Arc, atomic::{AtomicBool, AtomicU64, Ordering}}};

#[derive(Debug, Clone, Default)]
pub struct CancellationToken(Arc<AtomicBool>);
impl CancellationToken {
    pub fn new() -> Self { Self::default() }
    pub fn cancel(&self) { self.0.store(true, Ordering::Release); }
    pub fn is_cancelled(&self) -> bool { self.0.load(Ordering::Acquire) }
    fn check(&self) -> Result<(), WriterError> {
        if self.is_cancelled() { Err(WriterError::Cancelled) } else { Ok(()) }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MetadataCapture { Basic, Full }

#[derive(Debug, Clone)]
pub struct WriterOptions {
    pub layout: ArchiveLayout,
    pub compression: Compression,
    pub zlib_level: u32,
    pub zstd_level: i32,
    pub manifest_compression: Compression,
    pub buffer_size: usize,
    pub metadata_capture: MetadataCapture,
    pub limits: ManifestLimits,
    pub cancellation: CancellationToken,
}
impl Default for WriterOptions {
    fn default() -> Self {
        Self { layout: ArchiveLayout::Single, compression: Compression::Zstd, zlib_level: 6, zstd_level: 3, manifest_compression: Compression::Zstd, buffer_size: 1024 * 1024,
            metadata_capture: MetadataCapture::Basic, limits: ManifestLimits::default(),
            cancellation: CancellationToken::new() }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriterPhase { Preparing, Writing, EntryCompleted, Finalizing, Completed }

/// Source byte counters are cumulative actual reads, not estimated progress.
/// Total archive input is unknown because callers may add more entries.
/// A completed entry has been written to the staging file, not published yet.
#[derive(Debug, Clone)]
pub struct WriterProgress {
    pub phase: WriterPhase,
    pub path: Option<ArchivePath>,
    pub entries_completed: usize,
    pub source_bytes_read: u64,
    pub entry_bytes_read: u64,
    pub entry_total_bytes: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WriterResult {
    pub path: PathBuf,
    pub entry_count: usize,
    pub source_bytes: u64,
    /// Logical RVA bytes, without split envelopes.
    pub archive_bytes: u64,
    pub part_count: u64,
    pub physical_bytes: u64,
}

#[derive(Debug)]
pub enum WriterError {
    Io { path: PathBuf, source: io::Error },
    FileSystem(FileSystemError),
    Path(PathCodecError),
    Manifest(ManifestError),
    Invalid(&'static str),
    Unsupported(PathBuf),
    SourceChanged(PathBuf),
    DestinationExists(PathBuf),
    Cancelled,
    Closed,
    Cleanup { path: PathBuf, original: Box<WriterError>, source: io::Error },
}
impl fmt::Display for WriterError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io { path, source } => write!(f, "{path:?}: {source}"),
            Self::FileSystem(e) => write!(f, "{e}"),
            Self::Path(e) => write!(f, "{e}"),
            Self::Manifest(e) => write!(f, "{e}"),
            Self::Invalid(s) => f.write_str(s),
            Self::Unsupported(p) => write!(f, "unsupported source entry: {p:?}"),
            Self::SourceChanged(p) => write!(f, "source changed during archive creation: {p:?}"),
            Self::DestinationExists(p) => write!(f, "archive destination exists: {p:?}"),
            Self::Cancelled => f.write_str("archive creation cancelled"),
            Self::Closed => f.write_str("archive writer is closed"),
            Self::Cleanup { path, original, source } => write!(f, "{original}; could not remove staging archive {path:?}: {source}"),
        }
    }
}
impl Error for WriterError {}
impl From<FileSystemError> for WriterError { fn from(e: FileSystemError) -> Self { Self::FileSystem(e) } }
impl From<PathCodecError> for WriterError { fn from(e: PathCodecError) -> Self { Self::Path(e) } }
impl From<ManifestError> for WriterError { fn from(e: ManifestError) -> Self { Self::Manifest(e) } }
fn io_at(path: &Path, source: io::Error) -> WriterError {
    if source.get_ref().is_some_and(|e| e.is::<SplitCancelled>()) { WriterError::Cancelled }
    else { WriterError::Io { path: path.to_owned(), source } }
}

enum ArchiveOutput {
    Single(File),
    Split(SplitOutput),
}
impl ArchiveOutput {
    fn position(&mut self) -> io::Result<u64> {
        match self { Self::Single(file) => file.stream_position(), Self::Split(split) => Ok(split.position()) }
    }
    fn finish(self, logical_bytes: u64) -> io::Result<(u64, u64)> {
        match self {
            Self::Single(file) => { file.sync_all()?; Ok((1, logical_bytes)) }
            Self::Split(split) => split.finish(),
        }
    }
}
impl Write for ArchiveOutput {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        match self { Self::Single(file) => file.write(bytes), Self::Split(split) => split.write(bytes) }
    }
    fn flush(&mut self) -> io::Result<()> {
        match self { Self::Single(file) => file.flush(), Self::Split(split) => split.flush() }
    }
}

static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

/// Owns a sibling staging file or a private sibling split-set directory. Any failed add or finish aborts the
/// complete archive; a failed writer cannot be reused. Call abort explicitly
/// for a reportable cleanup result; Drop is only best-effort.
pub struct ArchiveWriter {
    destination: PathBuf,
    stage: Option<PathBuf>,
    output: Option<ArchiveOutput>,
    options: WriterOptions,
    manifest: ArchiveManifest,
    paths: HashSet<ArchivePath>,
    source_bytes: u64,
    buffer: Vec<u8>,
    progress: Option<Box<dyn FnMut(&WriterProgress) + Send>>,
}

fn require_absolute(path: &Path) -> Result<(), WriterError> {
    if !path.is_absolute() || path.components().any(|c| matches!(c, std::path::Component::ParentDir)) {
        return Err(WriterError::Invalid("an absolute native path without unresolved parent components is required"));
    }
    Ok(())
}

fn require_absent(path: &Path) -> Result<(), WriterError> {
    match fs::symlink_metadata(path) {
        Ok(_) => Err(WriterError::DestinationExists(path.to_owned())),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(io_at(path, e)),
    }
}

fn regular_item(item: &FileSystemItem) -> bool {
    // FileSystem supplies the raw attribute bits; reject all Windows reparse
    // entries, including non-directory ones not classified as links by stat.
    matches!(item.kind, FileSystemItemKind::File | FileSystemItemKind::Directory)
        && !item.metadata.attributes.windows.is_some_and(|bits| bits & 0x400 != 0)
}

impl ArchiveWriter {
    pub fn new(destination: &Path, options: WriterOptions) -> Result<Self, WriterError> {
        options.cancellation.check()?;
        if options.zlib_level > 9 || !(1..=19).contains(&options.zstd_level) || options.buffer_size == 0 || options.buffer_size > 64 * 1024 * 1024 {
            return Err(WriterError::Invalid("invalid compression level or buffer size"));
        }
        if let ArchiveLayout::Split { max_part_size } = options.layout {
            if max_part_size <= SPLIT_PART_HEADER_LEN {
                return Err(WriterError::Invalid("split part size must exceed physical header size"));
            }
        }
        require_absolute(destination)?;
        let name = destination.file_name().ok_or(WriterError::Invalid("missing archive filename"))?;
        PathComponent::from_native(name)?.to_native()?;
        let parent = destination.parent().ok_or(WriterError::Invalid("missing archive parent"))?;
        let parent = fs::canonicalize(parent).map_err(|e| io_at(parent, e))?;
        let destination = parent.join(name);
        require_absent(&destination)?;
        let mut reserved = None;
        for _ in 0..1024 {
            let id = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
            let stage = parent.join(format!(".remvibe-rva-{}-{id}.tmp", std::process::id()));
            if stage == destination { continue; }
            let result = match options.layout {
                ArchiveLayout::Single => OpenOptions::new().write(true).create_new(true).open(&stage).map(ArchiveOutput::Single),
                ArchiveLayout::Split { max_part_size } => fs::create_dir(&stage)
                    .map(|()| ArchiveOutput::Split(SplitOutput::new(stage.clone(), max_part_size, options.cancellation.clone()))),
            };
            match result {
                Ok(output) => { reserved = Some((stage, output)); break; }
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(io_at(&stage, e)),
            }
        }
        let (stage, output) = reserved.ok_or(WriterError::Invalid("cannot reserve sibling staging archive"))?;
        let buffer_size = options.buffer_size;
        let mut writer = Self { destination, stage: Some(stage), output: Some(output), options,
            manifest: ArchiveManifest::default(), paths: HashSet::new(), source_bytes: 0,
            buffer: Vec::new(), progress: None };
        let initialized = (|| {
            require_absent(&writer.destination)?;
            writer.buffer.try_reserve_exact(buffer_size).map_err(|_| WriterError::Invalid("cannot allocate writer buffer"))?;
            writer.buffer.resize(buffer_size, 0);
            let stage = writer.stage.as_ref().unwrap();
            writer.output.as_mut().unwrap().write_all(&Header.encode()).map_err(|e| io_at(stage, e))?;
            Ok(())
        })();
        if let Err(error) = initialized { return Err(writer.fail(error)); }
        Ok(writer)
    }

    pub fn set_progress_handler(&mut self, handler: impl FnMut(&WriterProgress) + Send + 'static) {
        self.progress = Some(Box::new(handler));
    }

    fn event(&mut self, phase: WriterPhase, path: Option<&ArchivePath>, entry_bytes_read: u64, total: Option<u64>) {
        if let Some(handler) = &mut self.progress {
            handler(&WriterProgress { phase, path: path.cloned(), entries_completed: self.manifest.entries.len(),
                source_bytes_read: self.source_bytes, entry_bytes_read, entry_total_bytes: total });
        }
    }

    fn ensure_open(&self) -> Result<(), WriterError> {
        if self.output.is_none() { Err(WriterError::Closed) } else { self.options.cancellation.check() }
    }

    fn reserve_path(&mut self, path: &ArchivePath) -> Result<(), WriterError> {
        path.validate()?;
        if path.0.len() > self.options.limits.max_depth || self.manifest.entries.len() >= self.options.limits.max_entries {
            return Err(WriterError::Invalid("archive path depth or entry limit exceeded"));
        }
        if !self.paths.insert(path.clone()) { return Err(WriterError::Invalid("duplicate archive path")); }
        Ok(())
    }

    fn capture(&self, path: &Path, item: &FileSystemItem) -> Result<FileSystemMetadata, WriterError> {
        Ok(match self.options.metadata_capture {
            MetadataCapture::Basic => item.metadata.clone(),
            MetadataCapture::Full => FileSystemService::instance().get_metadata(path)?,
        })
    }

    fn source_item(&self, source: &Path) -> Result<FileSystemItem, WriterError> {
        require_absolute(source)?;
        let item = FileSystemService::instance().stat(source)?;
        if !regular_item(&item) { return Err(WriterError::Unsupported(source.to_owned())); }
        // The final entry must not be a link. Caller-selected parent paths may
        // contain OS aliases. Never archive the staging file itself.
        if item.kind == FileSystemItemKind::File {
            let actual = fs::canonicalize(source).map_err(|e| io_at(source, e))?;
            let stage = fs::canonicalize(self.stage.as_ref().ok_or(WriterError::Closed)?)
                .map_err(|e| io_at(self.stage.as_ref().unwrap(), e))?;
            if actual == stage || actual.starts_with(&stage) { return Err(WriterError::Invalid("cannot archive the staging archive")); }
        }
        Ok(item)
    }

    pub fn add_file(&mut self, source: &Path, path: ArchivePath) -> Result<(), WriterError> {
        self.add_file_with_compression(source, path, self.options.compression)
    }

    pub fn add_file_with_compression(&mut self, source: &Path, path: ArchivePath, compression: Compression) -> Result<(), WriterError> {
        let result = self.write_file(source, path, compression);
        result.map_err(|error| self.fail(error))
    }

    fn write_file(&mut self, source: &Path, path: ArchivePath, compression: Compression) -> Result<(), WriterError> {
        self.ensure_open()?;
        self.reserve_path(&path)?;
        self.event(WriterPhase::Preparing, Some(&path), 0, None);
        self.options.cancellation.check()?;
        let item = self.source_item(source)?;
        if item.kind != FileSystemItemKind::File { return Err(WriterError::Unsupported(source.to_owned())); }
        let metadata = self.capture(source, &item)?;
        let expected = metadata.size.ok_or(WriterError::Invalid("source file size unavailable"))?;
        if expected > self.options.limits.max_file_bytes
            || self.source_bytes.checked_add(expected).map_or(true, |n| n > self.options.limits.max_total_bytes) {
            return Err(WriterError::Invalid("source byte limit exceeded"));
        }
        let mut input = File::open(source).map_err(|e| io_at(source, e))?;
        let before = input.metadata().map_err(|e| io_at(source, e))?;
        if !before.is_file() || before.len() != expected || before.modified().ok() != metadata.modified_at {
            return Err(WriterError::SourceChanged(source.to_owned()));
        }
        let stage = self.stage.as_ref().ok_or(WriterError::Closed)?.clone();
        let output = self.output.as_mut().ok_or(WriterError::Closed)?;
        let offset = output.position().map_err(|e| io_at(&stage, e))?;
        let token = &self.options.cancellation;
        let progress = &mut self.progress;
        let entries_completed = self.manifest.entries.len();
        let total = &mut self.source_bytes;
        let mut on_chunk = |entry_bytes_read: u64, n: u64| {
            *total += n; // bounded by expected and checked total above
            if let Some(handler) = progress {
                handler(&WriterProgress { phase: WriterPhase::Writing, path: Some(path.clone()),
                    entries_completed, source_bytes_read: *total, entry_bytes_read, entry_total_bytes: Some(expected) });
            }
        };
        let sha256 = match compression {
            Compression::None => copy_stream(&mut input, &mut *output, &mut self.buffer, expected, source, &stage, token, &mut on_chunk)?,
            Compression::Zlib => {
                let mut encoder = ZlibEncoder::new(&mut *output, flate2::Compression::new(self.options.zlib_level));
                let hash = copy_stream(&mut input, &mut encoder, &mut self.buffer, expected, source, &stage, token, &mut on_chunk)?;
                encoder.finish().map_err(|e| io_at(&stage, e))?;
                hash
            }
            Compression::Zstd => {
                let mut encoder = zstd::stream::write::Encoder::new(&mut *output, self.options.zstd_level).map_err(|e| io_at(&stage, e))?;
                // Known input length lets Zstd choose suitable parameters for small files.
                encoder.set_pledged_src_size(Some(expected)).map_err(|e| io_at(&stage, e))?;
                let hash = copy_stream(&mut input, &mut encoder, &mut self.buffer, expected, source, &stage, token, &mut on_chunk)?;
                encoder.finish().map_err(|e| io_at(&stage, e))?;
                hash
            }
        };
        let stored_size = output.position().map_err(|e| io_at(&stage, e))?
            .checked_sub(offset).ok_or(WriterError::Invalid("invalid stored payload position"))?;
        let after = input.metadata().map_err(|e| io_at(source, e))?;
        let current = self.source_item(source)?;
        if !after.is_file() || after.len() != expected || after.modified().ok() != before.modified().ok()
            || current.kind != FileSystemItemKind::File || current.metadata.size != Some(expected)
            || current.metadata.modified_at != metadata.modified_at {
            return Err(WriterError::SourceChanged(source.to_owned()));
        }
        self.manifest.entries.push(ArchiveEntry { path: path.clone(), metadata: ArchiveMetadata::from(&metadata),
            entry: EntryKind::File { payload: FilePayload { offset, stored_size, original_size: expected, compression, sha256 } } });
        self.event(WriterPhase::EntryCompleted, Some(&path), expected, Some(expected));
        self.options.cancellation.check()
    }

    /// Nonrecursive adds only the directory entry. Recursive adds every
    /// supported descendant including empty directories; no link traversal.
    pub fn add_directory(&mut self, source: &Path, path: ArchivePath, recursive: bool) -> Result<(), WriterError> {
        let result = self.write_directory(source, path, recursive);
        result.map_err(|error| self.fail(error))
    }

    fn write_directory(&mut self, source: &Path, path: ArchivePath, recursive: bool) -> Result<(), WriterError> {
        self.ensure_open()?;
        let root = self.source_item(source)?;
        if root.kind != FileSystemItemKind::Directory { return Err(WriterError::Unsupported(source.to_owned())); }
        if recursive {
            let root = fs::canonicalize(source).map_err(|e| io_at(source, e))?;
            if self.stage.as_ref().ok_or(WriterError::Closed)?.starts_with(&root) {
                return Err(WriterError::Invalid("archive destination is inside recursively selected source"));
            }
        }
        let mut pending = vec![(source.to_owned(), path)];
        while let Some((source, path)) = pending.pop() {
            self.ensure_open()?;
            let item = self.source_item(&source)?;
            if item.kind == FileSystemItemKind::File {
                self.write_file(&source, path, self.options.compression)?;
                continue;
            }
            self.reserve_path(&path)?;
            self.event(WriterPhase::Preparing, Some(&path), 0, None);
            self.options.cancellation.check()?;
            let metadata = self.capture(&source, &item)?;
            self.manifest.entries.push(ArchiveEntry { path: path.clone(), metadata: ArchiveMetadata::from(&metadata),
                entry: EntryKind::Directory });
            self.event(WriterPhase::EntryCompleted, Some(&path), 0, None);
            self.options.cancellation.check()?;
            if recursive {
                let mut children = FileSystemService::instance().list_directory(&FileSystemLocation::Path(source))?;
                children.sort_by(|a, b| a.name.cmp(&b.name));
                for child in children.into_iter().rev() {
                    if !regular_item(&child) {
                        let FileSystemLocation::Path(p) = child.location else { return Err(WriterError::Invalid("unexpected volume entry")); };
                        return Err(WriterError::Unsupported(p));
                    }
                    let mut child_path = path.clone();
                    child_path.0.push(PathComponent::from_native(&child.name)?);
                    let FileSystemLocation::Path(child_source) = child.location else { return Err(WriterError::Invalid("unexpected volume entry")); };
                    pending.push((child_source, child_path));
                }
            }
        }
        Ok(())
    }

    pub fn finish(mut self) -> Result<WriterResult, WriterError> {
        let result = self.finish_inner();
        result.map_err(|error| self.fail(error))
    }

    fn finish_inner(&mut self) -> Result<WriterResult, WriterError> {
        self.ensure_open()?;
        self.event(WriterPhase::Finalizing, None, 0, None);
        self.options.cancellation.check()?;
        let stage = self.stage.as_ref().ok_or(WriterError::Closed)?.clone();
        let mut output = self.output.take().ok_or(WriterError::Closed)?;
        let offset = output.position().map_err(|e| io_at(&stage, e))?;
        let (manifest, footer) = self.manifest.encode_with_compression(offset, &self.options.limits, self.options.manifest_compression,
            self.options.zlib_level, self.options.zstd_level)?;
        self.options.cancellation.check()?;
        output.write_all(&manifest).map_err(|e| io_at(&stage, e))?;
        output.write_all(&footer.encode()).map_err(|e| io_at(&stage, e))?;
        let archive_bytes = output.position().map_err(|e| io_at(&stage, e))?;
        let (part_count, physical_bytes) = output.finish(archive_bytes).map_err(|e| io_at(&stage, e))?;
        self.options.cancellation.check()?;
        require_absent(&self.destination)?;
        // Shared FileSystem native no-replace rename; same canonical parent.
        let name = self.destination.file_name().ok_or(WriterError::Invalid("missing archive filename"))?;
        self.options.cancellation.check()?;
        FileSystemService::instance().rename(&stage, name)?;
        self.stage = None; // publication won; subsequent cancellation does not undo it
        self.event(WriterPhase::Completed, None, 0, None);
        Ok(WriterResult { path: self.destination.clone(), entry_count: self.manifest.entries.len(),
            source_bytes: self.source_bytes, archive_bytes, part_count, physical_bytes })
    }

    /// Explicitly discard a staging archive. Reports cleanup failures.
    pub fn abort(mut self) -> Result<(), WriterError> {
        self.cleanup().map_err(|(path, source)| WriterError::Cleanup {
            path, original: Box::new(WriterError::Cancelled), source })
    }

    fn cleanup(&mut self) -> Result<(), (PathBuf, io::Error)> {
        drop(self.output.take());
        if let Some(path) = self.stage.take() {
            let removed = match self.options.layout {
                ArchiveLayout::Single => fs::remove_file(&path),
                ArchiveLayout::Split { .. } => fs::remove_dir_all(&path),
            };
            match removed {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => { self.stage = Some(path.clone()); return Err((path, e)); }
            }
        }
        Ok(())
    }

    fn fail(&mut self, error: WriterError) -> WriterError {
        match self.cleanup() {
            Ok(()) => error,
            Err((path, source)) => WriterError::Cleanup { path, original: Box::new(error), source },
        }
    }
}
impl Drop for ArchiveWriter {
    fn drop(&mut self) { let _ = self.cleanup(); }
}

fn copy_stream(input: &mut File, output: &mut impl Write, buffer: &mut [u8], expected: u64,
    source: &Path, stage: &Path, token: &CancellationToken, on_chunk: &mut impl FnMut(u64, u64))
    -> Result<String, WriterError> {
    let mut hash = Sha256::new();
    let mut count = 0u64;
    loop {
        token.check()?;
        let n = match input.read(buffer) {
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(io_at(source, e)),
        };
        if n == 0 { break; }
        count = count.checked_add(n as u64).ok_or_else(|| WriterError::SourceChanged(source.to_owned()))?;
        if count > expected { return Err(WriterError::SourceChanged(source.to_owned())); }
        output.write_all(&buffer[..n]).map_err(|e| io_at(stage, e))?;
        hash.update(&buffer[..n]);
        on_chunk(count, n as u64);
    }
    if count != expected { return Err(WriterError::SourceChanged(source.to_owned())); }
    token.check()?;
    Ok(format!("{:x}", hash.finalize()))
}
