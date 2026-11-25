//! Focused real Writer -> Reader acceptance. No new dependency.
use remvibe_archive::*;
use std::{fs, io::Cursor, path::{Path, PathBuf},
    sync::{Arc, Mutex}, time::{SystemTime, UNIX_EPOCH}};

struct Fixture(PathBuf);
impl Drop for Fixture { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }
fn rel(name: &str) -> ArchivePath { ArchivePath::from_relative(Path::new(name)).unwrap() }
fn no_stage(root: &Path) {
    assert!(!fs::read_dir(root).unwrap().any(|e| e.unwrap().file_name().to_string_lossy().starts_with(".remvibe-rva-extract-")));
}
fn find<R: std::io::Read + std::io::Seek>(reader: &ArchiveReader<R>, name: &str) -> usize {
    reader.entries().iter().position(|e| e.path == rel(name)).unwrap()
}
fn rebuild(payload_bytes: &[u8], manifest: &ArchiveManifest) -> Vec<u8> {
    let mut bytes = Header.encode().to_vec();
    bytes.extend_from_slice(payload_bytes);
    let (json, footer) = manifest.encode(bytes.len() as u64, &ManifestLimits::default()).unwrap();
    bytes.extend_from_slice(&json);
    bytes.extend_from_slice(&footer.encode());
    bytes
}
fn reader(bytes: Vec<u8>) -> ArchiveReader<Cursor<Vec<u8>>> {
    ArchiveReader::from_reader(Cursor::new(bytes), ReaderOptions::default()).unwrap()
}

fn main() {
    let root = std::env::temp_dir().join(format!("remvibe-reader-probe-{}-{}", std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
    fs::create_dir(&root).unwrap();
    let fixture = Fixture(root);
    let root = fs::canonicalize(&fixture.0).unwrap();
    let source = root.join("source");
    fs::create_dir_all(source.join("empty-dir")).unwrap();
    let content = vec![0x52; 2 * 1024 * 1024 + 19];
    fs::write(source.join("large.bin"), &content).unwrap();
    fs::write(source.join("çalışma.txt"), "RVA V3").unwrap();
    fs::write(source.join("empty.bin"), b"").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(source.join("çalışma.txt"), fs::Permissions::from_mode(0o755)).unwrap();
    }
    let archive = root.join("sample.rva");
    let mut writer = ArchiveWriter::new(&archive, WriterOptions { metadata_capture: MetadataCapture::Full, ..Default::default() }).unwrap();
    writer.add_directory(&source, rel("tree"), true).unwrap();
    writer.add_file_with_compression(&source.join("çalışma.txt"), rel("implicit/plain.txt"), Compression::None).unwrap();
    writer.finish().unwrap();
    let bytes = fs::read(&archive).unwrap();

    let mut opened = ArchiveReader::open(&archive, ReaderOptions::default()).unwrap();
    assert_eq!(opened.entries().len(), 6);
    let index = find(&opened, "tree/large.bin");
    let mut actual = Vec::new();
    assert_eq!(opened.read_entry_to(index, &mut actual).unwrap().output_bytes, content.len() as u64);
    assert_eq!(actual, content);
    let verified = opened.verify().unwrap();
    assert_eq!(verified.entry_count, 6);

    let mut host = vec![0xab; 777];
    host.extend_from_slice(&bytes);
    host.extend_from_slice(&[0xcd; 57]);
    let host_path = root.join("embedded.bin");
    fs::write(&host_path, &host).unwrap();
    let mut embedded = ArchiveReader::open_region(&host_path, 777, bytes.len() as u64, ReaderOptions::default()).unwrap();
    assert_eq!(embedded.verify().unwrap(), verified);
    assert!(ArchiveReader::open(&host_path, ReaderOptions::default()).is_err());
    assert!(ArchiveReader::open_region(&host_path, 777, bytes.len() as u64 + 1, ReaderOptions::default()).is_err());
    let mut memory = ArchiveReader::from_region(Cursor::new(host), 777, bytes.len() as u64,
        ReaderOptions { buffer_size: 113, ..Default::default() }).unwrap();
    assert_eq!(memory.verify().unwrap(), verified);
    let events = Arc::new(Mutex::new(Vec::<ReaderProgress>::new()));
    let received = events.clone();
    opened.set_progress_handler(move |p| received.lock().unwrap().push(p.clone()));
    let extracted = root.join("extracted");
    let result = opened.extract_to(&extracted, ExtractOptions::default()).unwrap();
    assert_eq!(result.entry_count, 6);
    assert_eq!(result.output_bytes, verified.output_bytes);
    assert_eq!(result.metadata.len(), 6);
    assert_eq!(fs::read(extracted.join("tree/large.bin")).unwrap(), content);
    assert_eq!(fs::read(extracted.join("tree/çalışma.txt")).unwrap(), b"RVA V3");
    assert_eq!(fs::read(extracted.join("implicit/plain.txt")).unwrap(), b"RVA V3");
    assert!(extracted.join("tree/empty-dir").is_dir());
    assert_eq!(fs::metadata(extracted.join("tree/empty.bin")).unwrap().len(), 0);
    let source_meta = fs::metadata(source.join("çalışma.txt")).unwrap();
    let target_meta = fs::metadata(extracted.join("tree/çalışma.txt")).unwrap();
    assert_eq!(target_meta.modified().unwrap(), source_meta.modified().unwrap());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(target_meta.permissions().mode() & 0o7777, 0o755);
    }
    assert!(result.metadata.iter().all(|r| r.result.is_success()));
    let events = events.lock().unwrap();
    assert_eq!(events.last().unwrap().phase, ReaderPhase::Completed);
    assert_eq!(events.last().unwrap().output_bytes, verified.output_bytes);
    assert!(events.windows(2).all(|w| w[0].output_bytes <= w[1].output_bytes));
    assert!(events.iter().filter(|p| p.phase == ReaderPhase::Extracting && p.path.as_ref() == Some(&rel("tree/large.bin"))).count() >= 3);
    drop(events);
    opened.clear_progress_handler();
    let single = root.join("single.txt");
    let index = find(&opened, "implicit/plain.txt");
    let single_result = opened.extract_entry_to(index, &single, ExtractOptions { metadata_policy: None, ..Default::default() }).unwrap();
    assert!(single_result.metadata.is_empty());
    assert_eq!(fs::read(&single).unwrap(), b"RVA V3");
    no_stage(&root);
    println!("PASS: bounded Reader, file/memory/embedded regions, selected streaming, full verification, extraction, metadata and progress");

    // Manifest corruption, uncompressed corruption, zlib trailing/truncated
    // streams and decoded size overflow. Rebuild valid manifests for malformed
    // payloads so the payload decoder, not just manifest checks, is exercised.
    let mut bad_header = bytes.clone();
    bad_header[0] ^= 1;
    assert!(ArchiveReader::from_reader(Cursor::new(bad_header), ReaderOptions::default()).is_err());
    let footer = Footer::decode(bytes[bytes.len() - FOOTER_LEN..].try_into().unwrap()).unwrap();
    let mut bad_manifest = bytes.clone();
    bad_manifest[footer.manifest_offset as usize] ^= 1;
    assert!(ArchiveReader::from_reader(Cursor::new(bad_manifest), ReaderOptions::default()).is_err());
    let mut bad_payload = bytes.clone();
    let EntryKind::File { payload } = &opened.entries()[index].entry else { panic!("file expected"); };
    bad_payload[payload.offset as usize] ^= 1;
    let mut corrupt = reader(bad_payload);
    let failed = root.join("corrupt");
    assert!(matches!(corrupt.extract_to(&failed, ExtractOptions::default()), Err(ReaderError::Integrity { .. })));
    assert!(!failed.exists());
    no_stage(&root);

    // Repeat the same corruption checks on independently encoded Zlib and Zstd.
    for compression in [Compression::Zlib, Compression::Zstd] {
    let large = find(&opened, "tree/large.bin");
    let mut one = opened.entries()[large].clone();
    let EntryKind::File { payload } = &mut one.entry else { panic!("file expected"); };
    let mut compressed = match compression {
        Compression::Zlib => {
            use std::io::Write;
            let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::new(6));
            encoder.write_all(&content).unwrap();
            encoder.finish().unwrap()
        }
        Compression::Zstd => zstd::bulk::compress(&content, 3).unwrap(),
        Compression::None => unreachable!(),
    };
    let original_compressed = compressed.clone();
    payload.compression = compression;
    payload.stored_size = compressed.len() as u64;
    payload.offset = HEADER_LEN as u64;
    let mut manifest = ArchiveManifest { entries: vec![one] };
    compressed.push(0);
    if let EntryKind::File { payload } = &mut manifest.entries[0].entry { payload.stored_size += 1; }
    assert!(matches!(reader(rebuild(&compressed, &manifest)).verify(), Err(ReaderError::Integrity { .. })));
    compressed.truncate(compressed.len() - 2);
    if let EntryKind::File { payload } = &mut manifest.entries[0].entry { payload.stored_size -= 2; }
    assert!(matches!(reader(rebuild(&compressed, &manifest)).verify(), Err(ReaderError::Integrity { .. })));
    // Restore full compressed stream but declare a smaller output size.
    let compressed = &original_compressed;
    if let EntryKind::File { payload } = &mut manifest.entries[0].entry {
        payload.stored_size = compressed.len() as u64;
        payload.original_size = 1;
    }
    manifest.entries[0].metadata.size = Some(1);
    assert!(matches!(reader(rebuild(compressed, &manifest)).verify(), Err(ReaderError::Integrity { .. })));
    }

    let cancelled = root.join("cancelled");
    let token = CancellationToken::new();
    let mut cancel_reader = ArchiveReader::open(&archive, ReaderOptions { cancellation: token.clone(), ..Default::default() }).unwrap();
    cancel_reader.set_progress_handler(move |p| { if p.phase == ReaderPhase::Extracting { token.cancel(); } });
    assert!(matches!(cancel_reader.extract_to(&cancelled, ExtractOptions::default()), Err(ReaderError::Cancelled)));
    assert!(!cancelled.exists());
    no_stage(&root);

    let conflict = root.join("conflict");
    let conflict_target = conflict.clone();
    opened.set_progress_handler(move |p| {
        if p.phase == ReaderPhase::Finalizing { fs::create_dir(&conflict_target).unwrap(); fs::write(conflict_target.join("keep"), b"keep").unwrap(); }
    });
    assert!(matches!(opened.extract_to(&conflict, ExtractOptions::default()), Err(ReaderError::DestinationExists(_))));
    assert_eq!(fs::read(conflict.join("keep")).unwrap(), b"keep");
    opened.clear_progress_handler();
    no_stage(&root);

    let mut missing = opened.manifest().clone();
    missing.entries.iter_mut().for_each(|e| e.metadata.created_at = None);
    let mut missing_reader = reader(rebuild(&bytes[HEADER_LEN..footer.manifest_offset as usize], &missing));
    let required = root.join("required");
    let policy = MetadataPolicy { created_time: MetadataRequirement::Required, ..Default::default() };
    assert!(matches!(missing_reader.extract_to(&required, ExtractOptions { metadata_policy: Some(policy), ..Default::default() }), Err(ReaderError::Metadata { .. })));
    assert!(!required.exists());
    no_stage(&root);

    // Exercise actual target case behavior, rather than assume Windows volume
    // settings. Both logical entries are allowed by the portable wire format.
    let alias_archive = root.join("alias.rva");
    let mut writer = ArchiveWriter::new(&alias_archive, WriterOptions::default()).unwrap();
    writer.add_file(&source.join("çalışma.txt"), rel("Folder/a.txt")).unwrap();
    writer.add_file(&source.join("çalışma.txt"), rel("folder/b.txt")).unwrap();
    writer.finish().unwrap();
    let case_test = root.join("CaseProbe");
    fs::create_dir(&case_test).unwrap();
    let case_insensitive = root.join("caseprobe").exists();
    fs::remove_dir(&case_test).unwrap();
    let alias_target = root.join("alias-target");
    let mut alias_reader = ArchiveReader::open(&alias_archive, ReaderOptions::default()).unwrap();
    if case_insensitive {
        assert!(matches!(alias_reader.extract_to(&alias_target, ExtractOptions::default()), Err(ReaderError::Collision(_))));
        assert!(!alias_target.exists());
    } else {
        alias_reader.extract_to(&alias_target, ExtractOptions::default()).unwrap();
        assert!(alias_target.join("Folder/a.txt").is_file());
        assert!(alias_target.join("folder/b.txt").is_file());
    }
    #[cfg(windows)]
    {
        assert!(PathComponent::Utf8("CON.txt".into()).to_native().is_err());
        assert!(PathComponent::Utf8("name. ".into()).to_native().is_err());
    }
    no_stage(&root);
    println!("PASS: corruption, strict zlib/zstd bounds, cancellation, destination conflict, required metadata failure and target path collisions");
}
