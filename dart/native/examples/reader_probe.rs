//! C fixture and native disk verification, through unchanged direct Rust Core.
use remvibe_archive::{ArchiveLayout, ArchivePath, ArchiveWriter, Compression, MetadataCapture, WriterOptions};
use std::{error::Error, ffi::OsString, fs::{self, File, FileTimes, OpenOptions},
    io::{Read, Seek, SeekFrom, Write}, path::{Path, PathBuf}, time::{Duration, UNIX_EPOCH}};

fn raw_name() -> OsString {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStringExt;
        let mut units: Vec<u16> = "raw-".encode_utf16().collect();
        units.push(0xd800);
        units.extend(".bin".encode_utf16());
        OsString::from_wide(&units)
    }
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStringExt;
        OsString::from_vec(b"raw-\xff.bin".to_vec())
    }
}
fn path(s: impl AsRef<Path>) -> ArchivePath {
    ArchivePath::from_relative(s.as_ref()).unwrap()
}
fn flip(file: &Path, at: SeekFrom) -> std::io::Result<()> {
    let mut file = OpenOptions::new().read(true).write(true).open(file)?;
    let position = file.seek(at)?;
    let mut byte = [0u8; 1];
    file.read_exact(&mut byte)?;
    byte[0] ^= 1;
    file.seek(SeekFrom::Start(position))?;
    file.write_all(&byte)
}
fn prepare(root: &Path) -> Result<(), Box<dyn Error>> {
    assert!(root.is_dir() && fs::read_dir(root)?.next().is_none(),"empty work directory required");
    let source = root.join("source");
    fs::create_dir(&source)?;
    fs::create_dir_all(source.join("tree/nested"))?;
    fs::create_dir(source.join("tree/empty"))?;
    let mut payload = vec![0u8; 48 * 1024];
    let mut random = 1007u32;
    for b in &mut payload {
        random ^= random << 13; random ^= random >> 17; random ^= random << 5;
        *b = random as u8;
    }
    let payload_path = source.join("payload.bin");
    fs::write(&payload_path,&payload)?;
    let modified = UNIX_EPOCH - Duration::new(2,500_000_000);
    OpenOptions::new().write(true).open(&payload_path)?.set_times(FileTimes::new().set_modified(modified))?;
    assert_eq!(fs::metadata(&payload_path)?.modified()?, modified,"pre-epoch fixture filesystem timestamp");
    fs::write(source.join("empty.bin"),[])?;
    fs::write(source.join(raw_name()),b"raw-name")?;
    fs::write(source.join("tree/root.txt"),b"root content")?;
    fs::write(source.join("tree/nested/İstanbul.txt"),b"nested content")?;
    for (name,layout,manifest_codec) in [
        ("single.rva",ArchiveLayout::Single,Compression::Zstd),
        ("split.rva.parts",ArchiveLayout::Split {max_part_size:4096},Compression::Zlib),
    ] {
        let mut writer = ArchiveWriter::new(&root.join(name),WriterOptions {
            layout, manifest_compression:manifest_codec, metadata_capture:MetadataCapture::Full, ..Default::default()
        })?;
        writer.add_file_with_compression(&payload_path,path("none.bin"),Compression::None)?;
        writer.add_file_with_compression(&payload_path,path("zlib.bin"),Compression::Zlib)?;
        writer.add_file(&source.join("empty.bin"),path("empty.bin"))?;
        writer.add_file(&source.join(raw_name()),path(raw_name()))?;
        writer.add_directory(&source.join("tree"),path("tree"),true)?;
        writer.add_directory(&source.join("tree"),path("shallow"),false)?;
        assert_eq!(writer.finish()?.entry_count,10);
    }
    let single = root.join("single.rva");
    let archive = fs::read(&single)?;
    let mut embedded = File::create(root.join("embedded.bin"))?;
    embedded.write_all(&[0x42; 37])?;
    embedded.write_all(&archive)?;
    embedded.write_all(&[0x24; 19])?;
    drop(embedded);
    for (name,offset) in [
        ("bad-header.rva",SeekFrom::Start(0)),
        ("bad-manifest.rva",SeekFrom::End(-1)),
        ("bad-payload.rva",SeekFrom::Start(16)),
    ] {
        let target = root.join(name);
        fs::copy(&single,&target)?;
        flip(&target,offset)?;
    }
    let broken = root.join("missing-parts");
    fs::create_dir(&broken)?;
    let mut parts = fs::read_dir(root.join("split.rva.parts"))?.collect::<Result<Vec<_>,_>>()?;
    parts.sort_by_key(|p| p.file_name());
    parts.pop().expect("at least one split part");
    assert!(!parts.is_empty());
    for part in parts { fs::copy(part.path(),broken.join(part.file_name()))?; }
    ArchiveWriter::new(&root.join("empty.rva"),WriterOptions::default())?.finish()?;
    // Real large payload for cooperative extraction cancellation; no synthetic waits.
    let large_path = source.join("large.bin");
    let mut large = File::create(&large_path)?;
    let mut chunk = vec![0u8;1024*1024];
    for b in &mut chunk {
        random ^= random << 13; random ^= random >> 17; random ^= random << 5;
        *b = random as u8;
    }
    for _ in 0..128 { large.write_all(&chunk)?; }
    drop(large);
    let mut writer = ArchiveWriter::new(&root.join("large.rva"),WriterOptions::default())?;
    writer.add_file(&large_path,path("large.bin"))?;
    writer.finish()?;
    println!("READER_RUST_FIXTURES_PREPARED region_offset=37 region_length={} raw_native=true",archive.len());
    Ok(())
}
fn check_tree(root: &Path, name: &str) -> Result<(), Box<dyn Error>> {
    let source = root.join("source");
    let target = root.join(name);
    for (from,to) in [
        (source.join("payload.bin"),target.join("none.bin")),
        (source.join("payload.bin"),target.join("zlib.bin")),
        (source.join("empty.bin"),target.join("empty.bin")),
        (source.join(raw_name()),target.join(raw_name())),
        (source.join("tree/root.txt"),target.join("tree/root.txt")),
        (source.join("tree/nested/İstanbul.txt"),target.join("tree/nested/İstanbul.txt")),
    ] {
        assert_eq!(fs::read(&from)?,fs::read(&to)?,"content mismatch {to:?}");
        assert_eq!(fs::metadata(&from)?.modified()?,fs::metadata(&to)?.modified()?,"modified time {to:?}");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&from)?.permissions().mode() & 0o777,fs::metadata(&to)?.permissions().mode() & 0o777);
        }
    }
    assert_eq!(fs::read_dir(target.join("tree/empty"))?.count(),0);
    assert_eq!(fs::read_dir(target.join("shallow"))?.count(),0);
    Ok(())
}
fn verify(root: &Path) -> Result<(), Box<dyn Error>> {
    for name in ["single-out","split-out","embedded-out"] { check_tree(root,name)?; }
    assert_eq!(fs::read(root.join("selected.bin"))?,fs::read(root.join("source/payload.bin"))?);
    assert_eq!(fs::read(root.join("deferred.bin"))?,fs::read(root.join("source/payload.bin"))?);
    assert_eq!(fs::read_dir(root.join("empty-out"))?.count(),0);
    assert_eq!(fs::read(root.join("existing.bin"))?,b"keep");
    for name in ["not-file.bin","missing-entry.bin","metadata-failed.bin","bad-payload-out","cancelled-out","active-close-out"] {
        assert!(!root.join(name).exists(),"unexpected destination {name}");
    }
    for entry in fs::read_dir(root)? {
        assert!(!entry?.file_name().to_string_lossy().starts_with(".remvibe-rva-"),"orphan staging");
    }
    println!("READER_RUST_EXTRACTED_CONTENT_RAW_NAMES_METADATA_PASS");
    println!("ARCHIVE_FFI_C_RUST_INTEROP_COMPLETED");
    Ok(())
}
fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len()!=2 { return Err("usage: reader_probe prepare|verify <absolute-work-directory>".into()); }
    let root = PathBuf::from(&args[1]);
    if !root.is_absolute() { return Err("absolute work directory required".into()); }
    match args[0].to_str() {
        Some("prepare") => prepare(&root),
        Some("verify") => verify(&root),
        _ => Err("expected prepare or verify".into()),
    }
}
