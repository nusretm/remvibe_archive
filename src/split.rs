//! Physical split volumes for an otherwise unchanged logical RVA V3 stream.
use crate::{ArchiveReader, CancellationToken, ReaderError, ReaderOptions};
use sha2::{Digest, Sha256};
use std::{error::Error, fmt, fs::{self, File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write}, path::{Path, PathBuf}};

pub const SPLIT_PART_HEADER_LEN: u64 = 72;
pub const MAX_SPLIT_PARTS: u64 = 999_999;
const MAGIC: &[u8; 8] = b"RVASPL3\n";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ArchiveLayout {
    #[default]
    Single,
    /// Destination is an absent directory; size includes the physical header.
    Split { max_part_size: u64 },
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}
#[derive(Debug)]
pub(crate) struct SplitCancelled;
impl fmt::Display for SplitCancelled {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { f.write_str("split archive creation cancelled") }
}
impl Error for SplitCancelled {}
fn check_write(token: &CancellationToken) -> io::Result<()> {
    if token.is_cancelled() { Err(io::Error::other(SplitCancelled)) } else { Ok(()) }
}
fn check_read(token: &CancellationToken) -> Result<(), ReaderError> {
    if token.is_cancelled() { Err(ReaderError::Cancelled) } else { Ok(()) }
}
fn part_path(dir: &Path, index: u64) -> PathBuf {
    dir.join(format!("part.{index:06}"))
}
fn part_count(total: u64, capacity: u64) -> Option<u64> {
    if total == 0 || capacity == 0 { return None; }
    let count = 1 + (total - 1) / capacity;
    (count <= MAX_SPLIT_PARTS).then_some(count)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PartHeader {
    set_digest: [u8; 32],
    index: u64,
    count: u64,
    total: u64,
    capacity: u64,
}
impl PartHeader {
    fn encode(self) -> [u8; SPLIT_PART_HEADER_LEN as usize] {
        let mut bytes = [0; SPLIT_PART_HEADER_LEN as usize];
        bytes[..8].copy_from_slice(MAGIC);
        bytes[8..40].copy_from_slice(&self.set_digest);
        bytes[40..48].copy_from_slice(&self.index.to_be_bytes());
        bytes[48..56].copy_from_slice(&self.count.to_be_bytes());
        bytes[56..64].copy_from_slice(&self.total.to_be_bytes());
        bytes[64..72].copy_from_slice(&self.capacity.to_be_bytes());
        bytes
    }
    fn decode(bytes: &[u8; SPLIT_PART_HEADER_LEN as usize]) -> io::Result<Self> {
        if &bytes[..8] != MAGIC { return Err(invalid("invalid split part magic")); }
        let header = Self {
            set_digest: bytes[8..40].try_into().unwrap(),
            index: u64::from_be_bytes(bytes[40..48].try_into().unwrap()),
            count: u64::from_be_bytes(bytes[48..56].try_into().unwrap()),
            total: u64::from_be_bytes(bytes[56..64].try_into().unwrap()),
            capacity: u64::from_be_bytes(bytes[64..72].try_into().unwrap()),
        };
        if header.index == 0 || header.index > header.count
            || part_count(header.total, header.capacity) != Some(header.count)
            || header.capacity.checked_add(SPLIT_PART_HEADER_LEN).is_none()
            || header.physical_bytes().is_none() {
            return Err(invalid("invalid split part bounds"));
        }
        Ok(header)
    }
    fn payload_len(self) -> u64 {
        // Validated count/index guarantees this multiplication is <= total.
        (self.total - (self.index - 1) * self.capacity).min(self.capacity)
    }
    fn physical_bytes(self) -> Option<u64> {
        self.count.checked_mul(SPLIT_PART_HEADER_LEN)?.checked_add(self.total)
    }
}

/// Owns only the active write handle. Parts are already in the private staging
/// directory; finish fills their fixed envelopes and syncs each physical file.
pub(crate) struct SplitOutput {
    dir: PathBuf,
    capacity: u64,
    count: u64,
    position: u64,
    used: u64,
    file: Option<File>,
    digest: Sha256,
    token: CancellationToken,
}
impl SplitOutput {
    pub(crate) fn new(dir: PathBuf, max_part_size: u64, token: CancellationToken) -> Self {
        Self { dir, capacity: max_part_size - SPLIT_PART_HEADER_LEN, count: 0,
            position: 0, used: 0, file: None, digest: Sha256::new(), token }
    }
    pub(crate) fn position(&self) -> u64 { self.position }

    fn next_part(&mut self) -> io::Result<()> {
        check_write(&self.token)?;
        drop(self.file.take());
        let index = self.count + 1;
        if index > MAX_SPLIT_PARTS { return Err(invalid("split part count limit exceeded")); }
        let path = part_path(&self.dir, index);
        let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
        file.write_all(&[0; SPLIT_PART_HEADER_LEN as usize])?;
        self.count = index;
        self.used = 0;
        self.file = Some(file);
        Ok(())
    }

    pub(crate) fn finish(mut self) -> io::Result<(u64, u64)> {
        check_write(&self.token)?;
        drop(self.file.take());
        if part_count(self.position, self.capacity) != Some(self.count) {
            return Err(invalid("invalid written split part count"));
        }
        let header = PartHeader {
            set_digest: self.digest.finalize().into(), index: 1,
            count: self.count, total: self.position, capacity: self.capacity,
        };
        let physical_bytes = header.physical_bytes().ok_or_else(|| invalid("split physical size overflow"))?;
        for index in 1..=header.count {
            check_write(&self.token)?;
            let part = PartHeader { index, ..header };
            let path = part_path(&self.dir, index);
            let mut file = OpenOptions::new().write(true).open(path)?;
            if file.metadata()?.len() != SPLIT_PART_HEADER_LEN + part.payload_len() {
                return Err(invalid("staging split part size changed"));
            }
            file.write_all(&part.encode())?;
            file.sync_all()?;
        }
        check_write(&self.token)?;
        Ok((header.count, physical_bytes))
    }
}
impl Write for SplitOutput {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        check_write(&self.token)?;
        if bytes.is_empty() { return Ok(0); }
        if self.file.is_none() || self.used == self.capacity { self.next_part()?; }
        let n = (bytes.len() as u64).min(self.capacity - self.used) as usize;
        self.position.checked_add(n as u64).ok_or_else(|| invalid("split stream size overflow"))?;
        let written = self.file.as_mut().unwrap().write(&bytes[..n])?;
        self.digest.update(&bytes[..written]);
        self.position += written as u64;
        self.used += written as u64;
        Ok(written)
    }
    fn flush(&mut self) -> io::Result<()> {
        match self.file.as_mut() { Some(file) => file.flush(), None => Ok(()) }
    }
}

fn open_part(dir: &Path, index: u64, expected: Option<PartHeader>) -> io::Result<(File, PartHeader)> {
    let path = part_path(dir, index);
    if !fs::symlink_metadata(&path)?.is_file() { return Err(invalid("split part is not a regular file")); }
    let mut file = File::open(path)?;
    let mut bytes = [0; SPLIT_PART_HEADER_LEN as usize];
    file.read_exact(&mut bytes)?;
    let header = PartHeader::decode(&bytes)?;
    if header.index != index || expected.is_some_and(|first| header != (PartHeader { index, ..first })) {
        return Err(invalid("split part order or set identity mismatch"));
    }
    if file.metadata()?.len() != SPLIT_PART_HEADER_LEN + header.payload_len() {
        return Err(invalid("split part physical size mismatch"));
    }
    Ok((file, header))
}

/// Seekable logical stream over a complete set of parts. Headers are validated
/// on open and whenever a part is reopened. Only one read handle is retained.
/// As for a single ArchiveReader, callers must keep the backing set immutable.
pub struct SplitReader {
    dir: PathBuf,
    header: PartHeader,
    position: u64,
    active: Option<(u64, File)>,
}
impl SplitReader {
    pub fn open(directory: &Path, cancellation: &CancellationToken) -> Result<Self, ReaderError> {
        check_read(cancellation)?;
        let dir = fs::canonicalize(directory)?;
        let (first, header) = open_part(&dir, 1, None)?;
        drop(first);
        // Count actual directory entries before walking header-declared names.
        // The set directory contains exactly the numbered volume files.
        let mut count = 0;
        for entry in fs::read_dir(&dir)? {
            check_read(cancellation)?;
            entry?;
            count += 1;
            if count > header.count { return Err(invalid("unexpected split directory entries").into()); }
        }
        if count != header.count { return Err(invalid("missing split parts").into()); }
        for index in 2..=header.count {
            check_read(cancellation)?;
            open_part(&dir, index, Some(header))?;
        }
        check_read(cancellation)?;
        Ok(Self { dir, header, position: 0, active: None })
    }
    pub fn part_count(&self) -> u64 { self.header.count }
    pub fn logical_length(&self) -> u64 { self.header.total }
    pub fn max_part_size(&self) -> u64 { self.header.capacity + SPLIT_PART_HEADER_LEN }
    pub fn physical_bytes(&self) -> u64 { self.header.physical_bytes().unwrap() }
}
impl Read for SplitReader {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        if bytes.is_empty() || self.position >= self.header.total { return Ok(0); }
        let index = self.position / self.header.capacity + 1;
        let inside = self.position % self.header.capacity;
        let n = (bytes.len() as u64).min(self.header.capacity - inside)
            .min(self.header.total - self.position) as usize;
        if !self.active.as_ref().is_some_and(|(current, _)| *current == index) {
            self.active = None;
            let (file, _) = open_part(&self.dir, index, Some(self.header))?;
            self.active = Some((index, file));
        }
        let file = &mut self.active.as_mut().unwrap().1;
        file.seek(SeekFrom::Start(SPLIT_PART_HEADER_LEN + inside))?;
        let read = file.read(&mut bytes[..n])?;
        if read == 0 { return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "truncated split part")); }
        self.position += read as u64;
        Ok(read)
    }
}
impl Seek for SplitReader {
    fn seek(&mut self, from: SeekFrom) -> io::Result<u64> {
        let position = match from {
            SeekFrom::Start(n) => n as i128,
            SeekFrom::End(n) => self.header.total as i128 + n as i128,
            SeekFrom::Current(n) => self.position as i128 + n as i128,
        };
        self.position = u64::try_from(position).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid split seek"))?;
        Ok(self.position)
    }
}
impl ArchiveReader<SplitReader> {
    pub fn open_split(directory: &Path, options: ReaderOptions) -> Result<Self, ReaderError> {
        let source = SplitReader::open(directory, &options.cancellation)?;
        Self::from_reader(source, options)
    }
}
