//! Focused F acceptance, including portable split-set exchange.
use remvibe_archive::*;
use sha2::{Digest, Sha256};
use std::{fs, io::{Read, Seek, SeekFrom}, path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH}};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const PART_SIZE: u64 = 4096;
const DATA_BYTES: usize = 32 * 1024 + 17;

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Result<Self> {
        let root = std::env::temp_dir().join(format!("remvibe-split-probe-{}-{}", std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()));
        fs::create_dir(&root)?;
        Ok(Self(fs::canonicalize(root)?))
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Err(e) = fs::remove_dir_all(&self.0) { eprintln!("fixture cleanup failed at {:?}: {e}", self.0); }
    }
}
fn rel(s: &str) -> ArchivePath { ArchivePath::from_relative(Path::new(s)).unwrap() }
fn absolute(path: &Path) -> Result<PathBuf> {
    Ok(if path.is_absolute() { path.to_owned() } else { std::env::current_dir()?.join(path) })
}
fn data() -> Vec<u8> {
    let mut x = 0x0123456789abcdefu64;
    (0..DATA_BYTES).map(|_| { x ^= x << 13; x ^= x >> 7; x ^= x << 17; x as u8 }).collect()
}
fn options(part_size: u64) -> WriterOptions {
    WriterOptions { layout: ArchiveLayout::Split { max_part_size: part_size },
        buffer_size: 1024, ..Default::default() }
}
fn part(dir: &Path, index: u64) -> PathBuf { dir.join(format!("part.{index:06}")) }
fn no_stage(root: &Path) -> Result<()> {
    for entry in fs::read_dir(root)? {
        assert!(!entry?.file_name().to_string_lossy().starts_with(".remvibe-rva-"));
    }
    Ok(())
}
fn produce(destination: &Path, marker: &str) -> Result<WriterResult> {
    let fixture = Fixture::new()?;
    let source = fixture.0.join("source.bin");
    let origin = fixture.0.join("origin.txt");
    let empty = fixture.0.join("empty");
    fs::write(&source, data())?;
    fs::write(&origin, marker)?;
    fs::create_dir(&empty)?;
    let mut writer = ArchiveWriter::new(destination, options(PART_SIZE))?;
    writer.add_file_with_compression(&source, rel("data/none.bin"), Compression::None)?;
    writer.add_file_with_compression(&source, rel("data/zlib.bin"), Compression::Zlib)?;
    writer.add_file_with_compression(&source, rel("data/çalışma.bin"), Compression::Zstd)?;
    writer.add_file(&origin, rel("origin.txt"))?;
    writer.add_directory(&empty, rel("empty-dir"), false)?;
    let empty_file = fixture.0.join("empty.bin");
    fs::write(&empty_file, [])?;
    writer.add_file(&empty_file, rel("empty.bin"))?;
    assert!(!destination.exists());
    let result = writer.finish()?;
    assert_eq!(result.entry_count, 6);
    assert_eq!(result.source_bytes, (DATA_BYTES * 3 + marker.len()) as u64);
    assert!(result.part_count > 3);
    assert_eq!(result.physical_bytes, result.archive_bytes + result.part_count * SPLIT_PART_HEADER_LEN);
    let mut physical = 0;
    for index in 1..=result.part_count {
        let len = fs::metadata(part(destination, index))?.len();
        assert!(len <= PART_SIZE);
        if index != result.part_count { assert_eq!(len, PART_SIZE); }
        physical += len;
    }
    assert_eq!(physical, result.physical_bytes);
    println!("PASS: split produced origin={marker} parts={} logical_bytes={} physical_bytes={} max_part_size={PART_SIZE}",
        result.part_count, result.archive_bytes, result.physical_bytes);
    Ok(result)
}
fn consume(directory: &Path, marker: &str, root: &Path) -> Result<()> {
    let options = ReaderOptions { buffer_size: 113, ..Default::default() };
    let mut reader = ArchiveReader::open_split(directory, options)?;
    assert_eq!(reader.entries().len(), 6);
    for (path, expected) in [("data/none.bin", Compression::None), ("data/zlib.bin", Compression::Zlib),
        ("data/çalışma.bin", Compression::Zstd)] {
        let index = reader.entries().iter().position(|e| e.path == rel(path)).unwrap();
        let EntryKind::File { payload } = &reader.entries()[index].entry else { panic!("expected file") };
        let capacity = PART_SIZE - SPLIT_PART_HEADER_LEN;
        assert_eq!(payload.compression, expected);
        assert!(payload.offset / capacity < (payload.offset + payload.stored_size - 1) / capacity);
        let mut actual = Vec::new();
        reader.read_entry_to(index, &mut actual)?;
        assert_eq!(actual, data());
    }
    assert_eq!(reader.verify()?.output_bytes, (DATA_BYTES * 3 + marker.len()) as u64);
    let target = root.join("restored");
    let result = reader.extract_to(&target, ExtractOptions::default())?;
    assert_eq!(result.entry_count, 6);
    assert_eq!(result.output_bytes, (DATA_BYTES * 3 + marker.len()) as u64);
    for path in ["data/none.bin", "data/zlib.bin", "data/çalışma.bin"] {
        assert_eq!(fs::read(target.join(path))?, data());
    }
    assert_eq!(fs::read(target.join("origin.txt"))?, marker.as_bytes());
    assert_eq!(fs::metadata(target.join("empty.bin"))?.len(), 0);
    assert!(target.join("empty-dir").is_dir());
    println!("PASS: split consumed origin={marker} target={} entries={} output_bytes={} all three codecs/selected read/verify/extract/Unicode/empty entries",
        std::env::consts::OS, result.entry_count, result.output_bytes);
    Ok(())
}
fn reject(directory: &Path) {
    assert!(ArchiveReader::open_split(directory, ReaderOptions::default()).is_err());
}
fn local() -> Result<()> {
    let fixture = Fixture::new()?;
    let root = &fixture.0;
    let archive = root.join("fixture.rva.parts");
    let result = produce(&archive, std::env::consts::OS)?;
    consume(&archive, std::env::consts::OS, root)?;

    // The virtual source yields the exact inner RVA bytes, with no envelopes.
    // This small fixture is assembled in memory only to independently check seek.
    let mut expected = Vec::new();
    for index in 1..=result.part_count {
        expected.extend_from_slice(&fs::read(part(&archive, index))?[SPLIT_PART_HEADER_LEN as usize..]);
    }
    let first = fs::read(part(&archive, 1))?;
    assert_eq!(&first[8..40], Sha256::digest(&expected).as_slice());
    let token = CancellationToken::new();
    let mut stream = SplitReader::open(&archive, &token)?;
    assert_eq!(stream.part_count(), result.part_count);
    assert_eq!(stream.logical_length(), result.archive_bytes);
    assert_eq!(stream.physical_bytes(), result.physical_bytes);
    assert_eq!(stream.max_part_size(), PART_SIZE);
    let mut logical = Vec::new();
    stream.read_to_end(&mut logical)?;
    assert_eq!(logical, expected);
    let boundary = PART_SIZE - SPLIT_PART_HEADER_LEN - 2;
    stream.seek(SeekFrom::Start(boundary))?;
    let mut cross = [0; 7];
    stream.read_exact(&mut cross)?;
    assert_eq!(cross.as_slice(), &expected[boundary as usize..boundary as usize + 7]);
    stream.seek(SeekFrom::Current(-3))?;
    assert_eq!(stream.stream_position()?, boundary + 4);
    stream.seek(SeekFrom::End(-(FOOTER_LEN as i64)))?;
    let mut footer = [0; FOOTER_LEN];
    stream.read_exact(&mut footer)?;
    Footer::decode(&footer)?;
    assert_eq!(stream.read(&mut cross)?, 0);
    assert!(stream.seek(SeekFrom::End(-(result.archive_bytes as i64) - 1)).is_err());
    token.cancel();
    assert!(stream.read(&mut cross).is_err());
    drop(stream);
    let mut ordinary = ArchiveReader::from_reader(std::io::Cursor::new(logical), ReaderOptions::default())?;
    assert_eq!(ordinary.verify()?.entry_count, result.entry_count);
    drop(ordinary);
    println!("PASS: logical stream identity and cross-part seek; inner RVA unchanged");

    // Tiny parts force even the 72-byte RVA footer to span parts.
    let tiny = root.join("tiny.parts");
    let tiny_result = ArchiveWriter::new(&tiny, options(SPLIT_PART_HEADER_LEN + 31))?.finish()?;
    assert!(tiny_result.part_count >= 3);
    assert_eq!(ArchiveReader::open_split(&tiny, ReaderOptions::default())?.verify()?.entry_count, 0);
    let one = root.join("one.parts");
    assert_eq!(ArchiveWriter::new(&one, options(PART_SIZE))?.finish()?.part_count, 1);
    assert_eq!(ArchiveReader::open_split(&one, ReaderOptions::default())?.verify()?.entry_count, 0);
    assert!(ArchiveWriter::new(&root.join("invalid.parts"), options(SPLIT_PART_HEADER_LEN)).is_err());
    println!("PASS: empty and one-part split sets, footer across part boundaries, invalid size rejected");

    let second = part(&archive, 2);
    let third = part(&archive, 3);
    let held = root.join("held");
    fs::rename(&second, &held)?;
    reject(&archive);
    fs::rename(&held, &second)?;
    fs::rename(&second, &held)?;
    fs::rename(&third, &second)?;
    fs::rename(&held, &third)?;
    reject(&archive);
    fs::rename(&third, &held)?;
    fs::rename(&second, &third)?;
    fs::rename(&held, &second)?;
    let other = root.join("other.parts");
    produce(&other, "different archive marker")?;
    let original = fs::read(&second)?;
    fs::copy(part(&other, 2), &second)?;
    reject(&archive);
    fs::write(&second, &original)?;
    fs::write(&second, &original[..original.len() - 1])?;
    reject(&archive);
    fs::write(&second, &original)?;
    fs::write(archive.join("extra"), b"unexpected")?;
    reject(&archive);
    fs::remove_file(archive.join("extra"))?;

    let mut bad = original.clone();
    bad[SPLIT_PART_HEADER_LEN as usize] ^= 1;
    fs::write(&second, bad)?;
    let mut reader = ArchiveReader::open_split(&archive, ReaderOptions::default())?;
    let failed = root.join("failed-extraction");
    assert!(matches!(reader.extract_to(&failed, ExtractOptions::default()), Err(ReaderError::Integrity { .. })));
    assert!(!failed.exists());
    drop(reader);
    fs::write(&second, original)?;
    assert_eq!(ArchiveReader::open_split(&archive, ReaderOptions::default())?.verify()?.entry_count, result.entry_count);
    println!("PASS: missing/reordered/mixed/truncated/extra parts and payload corruption rejected");

    let source = root.join("source.bin");
    fs::write(&source, data())?;
    let cancelled = root.join("cancelled.parts");
    let token = CancellationToken::new();
    let mut writer = ArchiveWriter::new(&cancelled, WriterOptions {
        cancellation: token.clone(), compression: Compression::None, ..options(PART_SIZE)
    })?;
    let callback = token.clone();
    writer.set_progress_handler(move |p| {
        if p.phase == WriterPhase::Writing && p.source_bytes_read >= 8192 { callback.cancel(); }
    });
    assert!(matches!(writer.add_file(&source, rel("source.bin")), Err(WriterError::Cancelled)));
    assert!(!cancelled.exists());
    no_stage(root)?;

    let conflict = root.join("conflict.parts");
    let mut writer = ArchiveWriter::new(&conflict, options(PART_SIZE))?;
    writer.add_file(&source, rel("source.bin"))?;
    fs::create_dir(&conflict)?;
    fs::write(conflict.join("keep.txt"), b"keep")?;
    assert!(matches!(writer.finish(), Err(WriterError::DestinationExists(_))));
    assert_eq!(fs::read(conflict.join("keep.txt"))?, b"keep");
    no_stage(root)?;

    let abandoned = root.join("abandoned.parts");
    let mut writer = ArchiveWriter::new(&abandoned, options(PART_SIZE))?;
    writer.add_file(&source, rel("source.bin"))?;
    writer.abort()?;
    assert!(!abandoned.exists());
    no_stage(root)?;

    let token = CancellationToken::new();
    token.cancel();
    assert!(matches!(ArchiveReader::open_split(&archive, ReaderOptions { cancellation: token, ..Default::default() }), Err(ReaderError::Cancelled)));
    println!("PASS: split cancellation, destination preservation, explicit abort and staging cleanup");
    Ok(())
}
fn main() -> Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    match args.first().and_then(|s| s.to_str()) {
        None => local(),
        Some("produce") if args.len() == 2 => { produce(&absolute(Path::new(&args[1]))?, std::env::consts::OS)?; Ok(()) }
        Some("consume") if args.len() == 3 => {
            let marker = args[2].to_str().ok_or("invalid origin OS")?;
            if marker == std::env::consts::OS { return Err("consume requires a different origin OS".into()); }
            let fixture = Fixture::new()?;
            consume(&absolute(Path::new(&args[1]))?, marker, &fixture.0)
        }
        _ => Err("usage: split_probe [produce <absent-directory> | consume <directory> <other-os>]".into()),
    }
}
