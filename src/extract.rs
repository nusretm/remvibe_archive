//! Staged extraction; native metadata operations and publication use FileSystem.
use crate::{ArchivePath, ArchiveReader, EntryKind, PathComponent, ReaderError, ReaderPhase};
use crate::reader::Operation;
use remvibe_filesystem_core::{FileSystemService, MetadataApplyResult, MetadataPolicy};
use std::{collections::HashMap, fs::{self, File, OpenOptions}, io::{self, Read, Seek},
    path::{Path, PathBuf}, sync::atomic::{AtomicU64, Ordering}};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExtractionSync { PerFile, Buffered }

#[derive(Debug, Clone)]
pub struct ExtractOptions {
    /// None: defer all metadata application to caller (e.g. multi-archive transfer).
    pub metadata_policy: Option<MetadataPolicy>,
    /// Buffered checks writes and integrity but does not force stable storage per file.
    pub sync: ExtractionSync,
}
impl Default for ExtractOptions {
    fn default() -> Self { Self { metadata_policy: Some(MetadataPolicy::default()), sync: ExtractionSync::PerFile } }
}
#[derive(Debug)]
pub struct EntryMetadataResult {
    pub path: ArchivePath,
    pub result: MetadataApplyResult,
}
#[derive(Debug)]
pub struct ExtractResult {
    pub path: PathBuf,
    pub entry_count: usize,
    pub output_bytes: u64,
    /// Per-entry application results, at the time of application.
    pub metadata: Vec<EntryMetadataResult>,
}

static NEXT_STAGE: AtomicU64 = AtomicU64::new(0);
fn absent(path: &Path) -> Result<(), ReaderError> {
    match fs::symlink_metadata(path) {
        Ok(_) => Err(ReaderError::DestinationExists(path.to_owned())),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}
fn destination_path(path: &Path) -> Result<PathBuf, ReaderError> {
    if !path.is_absolute() || path.components().any(|c| matches!(c, std::path::Component::ParentDir)) {
        return Err(ReaderError::Invalid("absolute destination without parent traversal required"));
    }
    let name = path.file_name().ok_or(ReaderError::Invalid("missing destination name"))?;
    PathComponent::from_native(name)?.to_native()?;
    let parent = path.parent().ok_or(ReaderError::Invalid("missing destination parent"))?;
    let destination = fs::canonicalize(parent)?.join(name);
    absent(&destination)?;
    Ok(destination)
}

/// Private sibling staging object. Cleanup never touches the final destination.
/// Permission recovery uses FileSystem's public methods on staged objects only.
struct Stage {
    path: Option<PathBuf>,
    metadata_paths: Vec<(PathBuf, bool)>,
}
impl Stage {
    fn new(destination: &Path, directory: bool) -> Result<Self, ReaderError> {
        let parent = destination.parent().ok_or(ReaderError::Invalid("missing destination parent"))?;
        for _ in 0..1024 {
            let id = NEXT_STAGE.fetch_add(1, Ordering::Relaxed);
            let path = parent.join(format!(".remvibe-rva-extract-{}-{id}.tmp", std::process::id()));
            if path == destination { continue; }
            let result = if directory { fs::create_dir(&path) }
                else { OpenOptions::new().write(true).create_new(true).open(&path).map(drop) };
            match result {
                Ok(()) => return Ok(Self { path: Some(path), metadata_paths: Vec::new() }),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e.into()),
            }
        }
        Err(ReaderError::Invalid("cannot reserve extraction staging object"))
    }
    fn path(&self) -> &Path { self.path.as_deref().expect("stage is live") }
    fn cleanup(&mut self) -> Result<(), remvibe_filesystem_core::FileSystemError> {
        let Some(path) = self.path.as_ref() else { return Ok(()); };
        let service = FileSystemService::instance();
        // Metadata may have made the staged tree readonly or inaccessible.
        // Re-enable access on our own staged objects (parents before children).
        // Explicit foreign owner/ACL restoration may still prevent cleanup.
        self.metadata_paths.sort_by_key(|(p, _)| p.components().count());
        for (entry, directory) in &self.metadata_paths {
            #[cfg(unix)]
            if *directory { let _ = service.chmod(entry, 0o700); }
            #[cfg(windows)]
            { let _ = directory; let _ = service.set_readonly(entry, false); }
        }
        match service.delete(path) {
            Ok(()) => { self.path = None; Ok(()) }
            Err(e) if e.kind == remvibe_filesystem_core::FileSystemErrorKind::NotFound => { self.path = None; Ok(()) }
            Err(e) => Err(e),
        }
    }
    fn fail(&mut self, original: ReaderError) -> ReaderError {
        match self.cleanup() {
            Ok(()) => original,
            Err(source) => {
                let path = self.path.take().expect("failed stage cleanup retains path");
                ReaderError::Cleanup { path, original: Box::new(original), source }
            }
        }
    }
    fn publish(&mut self, destination: &Path) -> Result<(), ReaderError> {
        absent(destination)?;
        FileSystemService::instance().rename(self.path(), destination.file_name().ok_or(ReaderError::Invalid("missing destination name"))?)?;
        self.path = None;
        Ok(())
    }
}
impl Drop for Stage { fn drop(&mut self) { let _ = self.cleanup(); } }

fn exclusive_dir(path: &Path) -> Result<(), ReaderError> {
    match fs::create_dir(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => Err(ReaderError::Collision(path.to_owned())),
        Err(e) => Err(e.into()),
    }
}
fn exclusive_file(path: &Path) -> Result<(), ReaderError> {
    match OpenOptions::new().write(true).create_new(true).open(path) {
        Ok(_) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => Err(ReaderError::Collision(path.to_owned())),
        Err(e) => Err(e.into()),
    }
}

impl<R: Read + Seek> ArchiveReader<R> {
    /// Extract the entire archive into an absent directory, publishing only
    /// after every selected stream and requested metadata operation succeeds.
    pub fn extract_to(&mut self, destination: &Path, options: ExtractOptions) -> Result<ExtractResult, ReaderError> {
        self.check_cancel()?;
        let destination = destination_path(destination)?;
        let mut op = self.all_operation()?;
        let mut stage = Stage::new(&destination, true)?;
        let result = self.extract_tree(&destination, &mut stage, &mut op, &options);
        result.map_err(|e| stage.fail(e))
    }

    /// Extract one regular file to an explicit absent filename; no directory
    /// subtree selection or merge. The archive name is not used as a target path.
    pub fn extract_entry_to(&mut self, index: usize, destination: &Path, options: ExtractOptions) -> Result<ExtractResult, ReaderError> {
        self.check_cancel()?;
        let destination = destination_path(destination)?;
        let mut op = self.file_operation(index)?;
        let mut stage = Stage::new(&destination, false)?;
        let result = (|| {
            let target = stage.path().to_owned();
            self.event(&op, ReaderPhase::Preparing, None, 0, None);
            self.check_cancel()?;
            self.extract_file(index, &target, &mut op, options.sync)?;
            let mut metadata = Vec::new();
            if let Some(policy) = &options.metadata_policy {
                metadata.push(self.apply_entry_metadata(index, &target, false, policy, &mut stage, &op)?);
            }
            self.publish_stage(&destination, &mut stage, &op, metadata)
        })();
        result.map_err(|e| stage.fail(e))
    }

    fn extract_tree(&mut self, destination: &Path, stage: &mut Stage, op: &mut Operation, options: &ExtractOptions) -> Result<ExtractResult, ReaderError> {
        self.event(op, ReaderPhase::Preparing, None, 0, None);
        // Reserve the complete native target tree before writing payloads.
        // Different logical names must create distinct actual directory entries;
        // create_new/create_dir detect target case/normalization aliases.
        let mut directories: HashMap<ArchivePath, PathBuf> = HashMap::new();
        let mut targets = Vec::new();
        for entry in self.entries() {
            self.check_cancel()?;
            let mut logical = ArchivePath(Vec::new());
            let mut target = stage.path().to_owned();
            let is_dir = matches!(&entry.entry, EntryKind::Directory);
            for (i, name) in entry.path.0.iter().enumerate() {
                self.check_cancel()?;
                logical.0.push(name.clone());
                let native = name.to_native()?;
                let needs_dir = i + 1 < entry.path.0.len() || is_dir;
                if needs_dir {
                    if let Some(existing) = directories.get(&logical) {
                        target = existing.clone();
                    } else {
                        target.push(native);
                        exclusive_dir(&target)?;
                        directories.insert(logical.clone(), target.clone());
                    }
                } else {
                    target.push(native);
                    exclusive_file(&target)?;
                }
            }
            targets.push(target);
        }
        for (index, target) in targets.iter().enumerate() {
            if matches!(&self.entries()[index].entry, EntryKind::Directory) {
                self.complete_directory(index, op)?;
            } else {
                self.extract_file(index, target, op, options.sync)?;
            }
        }
        // No permissions are applied until all payloads have been verified.
        // Files first, then explicit directory metadata from deepest to root.
        let mut metadata = Vec::new();
        if let Some(policy) = &options.metadata_policy {
            let mut dirs = Vec::new();
            for (index, target) in targets.iter().enumerate() {
                if matches!(&self.entries()[index].entry, EntryKind::Directory) {
                    dirs.push(index);
                } else {
                    metadata.push(self.apply_entry_metadata(index, target, false, policy, stage, op)?);
                }
            }
            dirs.sort_by_key(|&i| std::cmp::Reverse(self.entries()[i].path.0.len()));
            for index in dirs {
                metadata.push(self.apply_entry_metadata(index, &targets[index], true, policy, stage, op)?);
            }
        }
        self.publish_stage(destination, stage, op, metadata)
    }
    fn extract_file(&mut self, index: usize, path: &Path, op: &mut Operation, sync: ExtractionSync) -> Result<(), ReaderError> {
        self.check_cancel()?;
        // Files were exclusively reserved by this operation in a private stage.
        let mut file: File = OpenOptions::new().write(true).open(path)?;
        self.pump(index, &mut file, op, ReaderPhase::Extracting)?;
        if sync == ExtractionSync::PerFile { file.sync_all()?; }
        Ok(())
    }
    fn apply_entry_metadata(&mut self, index: usize, target: &Path, directory: bool, policy: &MetadataPolicy,
        stage: &mut Stage, op: &Operation) -> Result<EntryMetadataResult, ReaderError> {
        self.check_cancel()?;
        let path = self.entries()[index].path.clone();
        let metadata = self.entries()[index].metadata.to_filesystem()?;
        self.event(op, ReaderPhase::ApplyingMetadata, Some(&path), 0, None);
        self.check_cancel()?;
        stage.metadata_paths.push((target.to_owned(), directory));
        let result = FileSystemService::instance().apply_metadata(target, &metadata, policy)?;
        if !result.is_success() { return Err(ReaderError::Metadata { path, result }); }
        Ok(EntryMetadataResult { path, result })
    }
    fn publish_stage(&mut self, destination: &Path, stage: &mut Stage, op: &Operation,
        metadata: Vec<EntryMetadataResult>) -> Result<ExtractResult, ReaderError> {
        self.event(op, ReaderPhase::Finalizing, None, 0, None);
        self.check_cancel()?;
        stage.publish(destination)?;
        // Successful publication wins over later cancellation.
        self.event(op, ReaderPhase::Completed, None, 0, None);
        Ok(ExtractResult { path: destination.to_owned(), entry_count: op.entries_completed,
            output_bytes: op.output_bytes, metadata })
    }
}
