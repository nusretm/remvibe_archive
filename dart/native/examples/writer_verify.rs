//! Focused B interoperability: prepare a real non-Unicode name, then read
//! Dart-created RVA output through the unchanged direct Rust Core API.
use remvibe_archive::{ArchivePath, ArchiveReader, CancellationToken, Compression, EntryKind,
    Footer, ReaderOptions, SplitReader, FOOTER_LEN};
use std::{error::Error, ffi::OsString, fs::{self, File}, io::{Read, Seek, SeekFrom}, path::{Path, PathBuf}};

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

fn archive_path(value: &str) -> ArchivePath {
    ArchivePath::from_relative(Path::new(value)).unwrap()
}
fn verify<R: Read + Seek>(mut reader: ArchiveReader<R>, root: &Path, full: bool) -> Result<(), Box<dyn Error>> {
    let source = root.join("source");
    let raw = raw_name();
    let files = [
        (archive_path("none.bin"), source.join("payload.bin"), Compression::None),
        (archive_path("zlib.bin"), source.join("payload.bin"), Compression::Zlib),
        (archive_path("empty.bin"), source.join("empty.bin"), Compression::Zstd),
        (ArchivePath::from_relative(Path::new(&raw))?, source.join(&raw), Compression::Zstd),
        (archive_path("tree/root.txt"), source.join("tree/root.txt"), Compression::Zstd),
        (archive_path("tree/nested/İstanbul.txt"), source.join("tree/nested/İstanbul.txt"), Compression::Zstd),
    ];
    let directories = ["tree", "tree/empty", "tree/nested", "shallow"];
    assert_eq!(reader.entries().len(), files.len() + directories.len());
    let mut expected_bytes = 0u64;
    for (path, source, codec) in files {
        let index = reader.entries().iter().position(|entry| entry.path == path).expect("file entry absent");
        let entry = &reader.entries()[index];
        let expected = fs::read(source)?;
        match &entry.entry {
            EntryKind::File {payload} => {
                assert_eq!(payload.compression, codec);
                assert_eq!(payload.original_size, expected.len() as u64);
            }
            EntryKind::Directory => panic!("expected regular file"),
        }
        assert_eq!(entry.metadata.size, Some(expected.len() as u64));
        assert!(entry.metadata.modified_at.is_some());
        if full { assert!(entry.metadata.to_filesystem()?.permissions.is_some()); }
        let mut actual = Vec::new();
        reader.read_entry_to(index, &mut actual)?;
        assert_eq!(actual, expected);
        expected_bytes += actual.len() as u64;
    }
    for name in directories {
        let path = archive_path(name);
        let entry = reader.entries().iter().find(|entry| entry.path == path).expect("directory entry absent");
        assert!(matches!(&entry.entry, EntryKind::Directory));
        if full { assert!(entry.metadata.to_filesystem()?.permissions.is_some()); }
    }
    let verified = reader.verify()?;
    assert_eq!(verified.entry_count, 10);
    assert_eq!(verified.output_bytes, expected_bytes);
    Ok(())
}
fn codec(mut reader: impl Read + Seek) -> Result<Compression, Box<dyn Error>> {
    reader.seek(SeekFrom::End(-(FOOTER_LEN as i64)))?;
    let mut footer = [0; FOOTER_LEN];
    reader.read_exact(&mut footer)?;
    Ok(Footer::decode(&footer)?.manifest_compression)
}

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 2 { return Err("usage: writer_verify prepare|verify <absolute-work-directory>".into()); }
    let root = PathBuf::from(&args[1]);
    if !root.is_absolute() { return Err("absolute work directory required".into()); }
    match args[0].to_str() {
        Some("prepare") => {
            assert!(root.is_dir() && fs::read_dir(&root)?.next().is_none(), "work directory must be empty");
            let source = root.join("source");
            fs::create_dir(&source)?;
            fs::write(source.join(raw_name()), b"raw-name")?;
            println!("WRITER_RAW_NATIVE_FIXTURE_PREPARED");
        }
        Some("verify") => {
            let single = root.join("single.rva");
            let split = root.join("split.rva.parts");
            let empty = root.join("empty-manifest.rva");
            assert_eq!(codec(File::open(&single)?)?, Compression::Zstd);
            verify(ArchiveReader::open(&single, ReaderOptions::default())?, &root, false)?;
            println!("RUST_SINGLE_CODEC_CONTENT_METADATA_PASS");
            let parts = SplitReader::open(&split, &CancellationToken::new())?;
            assert!(parts.part_count() > 1);
            assert_eq!(parts.max_part_size(), 4096);
            assert_eq!(codec(parts)?, Compression::Zlib);
            verify(ArchiveReader::open_split(&split, ReaderOptions::default())?, &root, true)?;
            println!("RUST_SPLIT_CODEC_CONTENT_FULL_METADATA_PASS");
            assert_eq!(codec(File::open(&empty)?)?, Compression::None);
            assert_eq!(ArchiveReader::open(&empty, ReaderOptions::default())?.verify()?.entry_count, 0);
            println!("RUST_EMPTY_NONE_MANIFEST_PASS");
            for entry in fs::read_dir(&root)? {
                let entry = entry?;
                assert!(!entry.file_name().to_string_lossy().starts_with(".remvibe-rva-"), "orphan staging");
            }
            println!("ARCHIVE_FFI_B_RUST_INTEROP_COMPLETED");
        }
        _ => return Err("expected prepare or verify".into()),
    }
    Ok(())
}
