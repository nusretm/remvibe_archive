//! Inspect actual Writer output without implementing the Reader.
use flate2::read::ZlibDecoder;
use remvibe_archive::*;
use sha2::{Digest, Sha256};
use std::{fs::{self, File}, io::{Read, Seek, SeekFrom, Write}, path::{Path, PathBuf},
    sync::{Arc, Mutex}, time::{SystemTime, UNIX_EPOCH}};

struct Fixture(PathBuf);
impl Drop for Fixture {
    fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
}
fn rel(s: &str) -> ArchivePath { ArchivePath::from_relative(Path::new(s)).unwrap() }
fn no_stage(path: &Path) {
    assert!(!fs::read_dir(path).unwrap().any(|e| e.unwrap().file_name().to_string_lossy().starts_with(".remvibe-rva-")));
}
fn inspect(path: &Path, source: &Path) -> ArchiveManifest {
    let mut file = File::open(path).unwrap();
    let len = file.metadata().unwrap().len();
    let mut header = [0; HEADER_LEN];
    file.read_exact(&mut header).unwrap();
    Header::decode(&header).unwrap();
    file.seek(SeekFrom::End(-(FOOTER_LEN as i64))).unwrap();
    let mut footer = [0; FOOTER_LEN];
    file.read_exact(&mut footer).unwrap();
    let footer = Footer::decode(&footer).unwrap();
    let region = ArchiveRegion::new(0, len, len).unwrap();
    let limits = ManifestLimits::default();
    let range = limits.manifest_range(footer, region).unwrap();
    let mut json = vec![0; (range.end - range.start) as usize];
    file.seek(SeekFrom::Start(range.start)).unwrap();
    file.read_exact(&mut json).unwrap();
    let manifest = ArchiveManifest::decode(&json, footer, region, &limits).unwrap();
    for entry in &manifest.entries {
        if let EntryKind::File { payload } = &entry.entry {
            let relative = entry.path.to_relative().unwrap();
            let original = if relative == Path::new("selected.txt") || relative == Path::new("selected-zlib.txt") {
                fs::read(source.join("tree").join("small.txt")).unwrap()
            } else { fs::read(source.join(&relative)).unwrap() };
            file.seek(SeekFrom::Start(payload.offset)).unwrap();
            let mut actual = Vec::new();
            match payload.compression {
                Compression::None => { (&mut file).take(payload.stored_size).read_to_end(&mut actual).unwrap(); }
                Compression::Zlib => {
                    let mut decoder = ZlibDecoder::new((&mut file).take(payload.stored_size));
                    decoder.read_to_end(&mut actual).unwrap();
                    assert_eq!(decoder.total_in(), payload.stored_size);
                }
                Compression::Zstd => {
                    let mut decoder = zstd::stream::read::Decoder::new((&mut file).take(payload.stored_size)).unwrap();
                    decoder.read_to_end(&mut actual).unwrap();
                }
            }
            assert_eq!(actual, original);
            assert_eq!(payload.original_size, original.len() as u64);
            assert_eq!(payload.sha256, format!("{:x}", Sha256::digest(&original)));
        }
    }
    manifest
}

fn main() {
    let root = std::env::temp_dir().join(format!("remvibe-writer-probe-{}-{}", std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
    fs::create_dir(&root).unwrap();
    let fixture = Fixture(root);
    let root = fs::canonicalize(&fixture.0).unwrap();
    let source = root.join("source");
    let tree = source.join("tree");
    let out = root.join("out");
    fs::create_dir_all(tree.join("empty-dir")).unwrap();
    fs::create_dir_all(source.join("nonrecursive")).unwrap();
    fs::create_dir(&out).unwrap();
    fs::write(tree.join("small.txt"), "RVA V3 — çalışma").unwrap();
    fs::write(tree.join("large.bin"), vec![0x5a; 2 * 1024 * 1024 + 17]).unwrap();
    fs::write(tree.join("empty.bin"), b"").unwrap();
    fs::write(source.join("nonrecursive").join("not-selected.txt"), "excluded").unwrap();
    let archive = out.join("sample.rva");
    let events = Arc::new(Mutex::new(Vec::<WriterProgress>::new()));
    let received = events.clone();
    let mut writer = ArchiveWriter::new(&archive, WriterOptions { metadata_capture: MetadataCapture::Full, ..Default::default() }).unwrap();
    writer.set_progress_handler(move |p| received.lock().unwrap().push(p.clone()));
    writer.add_directory(&tree, rel("tree"), true).unwrap();
    writer.add_directory(&source.join("nonrecursive"), rel("nonrecursive"), false).unwrap();
    writer.add_file_with_compression(&tree.join("small.txt"), rel("selected.txt"), Compression::None).unwrap();
    writer.add_file_with_compression(&tree.join("small.txt"), rel("selected-zlib.txt"), Compression::Zlib).unwrap();
    assert!(!archive.exists());
    let result = writer.finish().unwrap();
    assert_eq!(result.entry_count, 8);
    assert_eq!(result.archive_bytes, fs::metadata(&archive).unwrap().len());
    let manifest = inspect(&archive, &source);
    assert_eq!(manifest.entries.len(), 8);
    assert!(manifest.entries.iter().any(|e| e.path == rel("tree/empty-dir") && matches!(&e.entry, EntryKind::Directory)));
    assert!(!manifest.entries.iter().any(|e| e.path == rel("nonrecursive/not-selected.txt")));
    assert!(manifest.entries.iter().any(|e| e.path == rel("selected.txt") && matches!(&e.entry, EntryKind::File { payload } if payload.compression == Compression::None)));
    assert!(manifest.entries.iter().any(|e| e.path == rel("tree/large.bin") && matches!(&e.entry, EntryKind::File { payload } if payload.stored_size < payload.original_size)));
    let original_total: u64 = manifest.entries.iter().filter_map(|e| match &e.entry {
        EntryKind::File { payload } => Some(payload.original_size), _ => None,
    }).sum();
    assert_eq!(result.source_bytes, original_total);
    let events = events.lock().unwrap();
    assert_eq!(events.last().unwrap().phase, WriterPhase::Completed);
    assert_eq!(events.last().unwrap().source_bytes_read, original_total);
    assert!(events.windows(2).all(|w| w[0].source_bytes_read <= w[1].source_bytes_read));
    assert!(events.iter().filter(|e| e.phase == WriterPhase::Writing && e.path.as_ref() == Some(&rel("tree/large.bin"))).count() >= 3);
    drop(events);
    no_stage(&out);
    println!("PASS: streaming RVA writer, zstd/zlib/none, full metadata, recursive/nonrecursive/empty entries and payload SHA-256");

    let cancelled = out.join("cancelled.rva");
    let token = CancellationToken::new();
    let mut writer = ArchiveWriter::new(&cancelled, WriterOptions { cancellation: token.clone(), ..Default::default() }).unwrap();
    writer.set_progress_handler(move |p| { if p.phase == WriterPhase::Writing { token.cancel(); } });
    assert!(matches!(writer.add_file(&tree.join("large.bin"), rel("large.bin")), Err(WriterError::Cancelled)));
    assert!(!cancelled.exists());
    no_stage(&out);

    let conflict = out.join("conflict.rva");
    let mut writer = ArchiveWriter::new(&conflict, WriterOptions::default()).unwrap();
    writer.add_file(&tree.join("small.txt"), rel("file")).unwrap();
    fs::write(&conflict, "keep me").unwrap();
    assert!(matches!(writer.finish(), Err(WriterError::DestinationExists(_))));
    assert_eq!(fs::read(&conflict).unwrap(), b"keep me");
    no_stage(&out);

    let changed = out.join("changed.rva");
    let input = source.join("changing.bin");
    fs::write(&input, vec![1; 2 * 1024 * 1024]).unwrap();
    let mutate = input.clone();
    let mut writer = ArchiveWriter::new(&changed, WriterOptions::default()).unwrap();
    let mut once = false;
    writer.set_progress_handler(move |p| {
        if p.phase == WriterPhase::Writing && !once {
            fs::OpenOptions::new().append(true).open(&mutate).unwrap().write_all(&[2]).unwrap();
            once = true;
        }
    });
    assert!(matches!(writer.add_file(&input, rel("changing.bin")), Err(WriterError::SourceChanged(_))));
    assert!(!changed.exists());
    no_stage(&out);

    let nested = tree.join("nested.rva");
    let mut writer = ArchiveWriter::new(&nested, WriterOptions::default()).unwrap();
    assert!(writer.add_directory(&tree, rel("tree"), true).is_err());
    assert!(!nested.exists());
    no_stage(&tree);

    let abandoned = out.join("abandoned.rva");
    let writer = ArchiveWriter::new(&abandoned, WriterOptions::default()).unwrap();
    writer.abort().unwrap();
    assert!(!abandoned.exists());
    no_stage(&out);
    println!("PASS: writer cancellation, destination preservation, source-change detection and staging cleanup");
}
