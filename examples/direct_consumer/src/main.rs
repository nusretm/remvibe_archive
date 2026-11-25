//! Independent Cargo consumer for ARCHIVE-RUST-01 / D.
use remvibe_archive::{
    ArchivePath, ArchiveReader, ArchiveWriter, Compression, EntryKind, ExtractOptions,
    MetadataCapture, MetadataPolicy, MetadataRequirement, PathComponent, ReaderOptions, WriterOptions,
};
use std::{
    ffi::{OsStr, OsString}, fs::{self, File, FileTimes}, path::{Path, PathBuf},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const FILE_BYTES: usize = 4096;
const FIXED_TIME: u64 = 1_700_000_000;
struct Fixture(PathBuf);
impl Fixture {
    fn new(parent: &Path) -> Result<Self> {
        let parent = fs::canonicalize(parent)?;
        let path = parent.join(format!("remvibe-archive-acceptance-{}-{}", std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()));
        fs::create_dir(&path)?;
        Ok(Self(path))
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        #[cfg(windows)]
        fn unlock(path: &Path) {
            if let Ok(m) = fs::symlink_metadata(path) {
                if m.is_dir() {
                    if let Ok(entries) = fs::read_dir(path) {
                        for entry in entries.flatten() { unlock(&entry.path()); }
                    }
                } else if m.permissions().readonly() {
                    let mut p = m.permissions();
                    p.set_readonly(false);
                    let _ = fs::set_permissions(path, p);
                }
            }
        }
        #[cfg(windows)]
        unlock(&self.0);
        if let Err(e) = fs::remove_dir_all(&self.0) {
            eprintln!("fixture cleanup failed at {:?}: {e}", self.0);
        }
    }
}
fn rel(path: &str) -> ArchivePath { ArchivePath::from_relative(Path::new(path)).unwrap() }
fn absolute(path: &OsStr) -> Result<PathBuf> {
    let path = Path::new(path);
    Ok(if path.is_absolute() { path.to_owned() } else { std::env::current_dir()?.join(path) })
}
fn set_time(path: &Path) -> Result<()> {
    File::options().write(true).open(path)?.set_times(FileTimes::new().set_modified(UNIX_EPOCH + Duration::from_secs(FIXED_TIME)))?;
    Ok(())
}
fn check_time(path: &Path) -> Result<()> {
    assert_eq!(fs::metadata(path)?.modified()?, UNIX_EPOCH + Duration::from_secs(FIXED_TIME));
    Ok(())
}
fn data(index: usize) -> [u8; FILE_BYTES] {
    let mut bytes = [0; FILE_BYTES];
    if index % 2 == 0 {
        bytes.fill((index % 251) as u8);
    } else {
        let mut x = index as u64 + 1;
        for b in &mut bytes {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17;
            *b = x as u8;
        }
    }
    bytes
}
fn produce(archive: &Path) -> Result<()> {
    let fixture = Fixture::new(&std::env::temp_dir())?;
    let source = fixture.0.join("payload");
    fs::create_dir_all(source.join("nested"))?;
    fs::create_dir(source.join("empty-dir"))?;
    fs::write(source.join("empty.bin"), b"")?;
    fs::write(source.join("çalışma.txt"), "RVA V3 — portable Unicode")?;
    fs::write(source.join("nested/data.bin"), data(37))?;
    set_time(&source.join("çalışma.txt"))?;
    let origin = fixture.0.join("origin.txt");
    fs::write(&origin, std::env::consts::OS)?;
    let mut writer = ArchiveWriter::new(archive, WriterOptions { metadata_capture: MetadataCapture::Full, ..Default::default() })?;
    writer.add_directory(&source, rel("payload"), true)?;
    writer.add_file_with_compression(&origin, rel("origin.txt"), Compression::None)?;
    let result = writer.finish()?;
    assert_eq!(result.entry_count, 7);
    println!("PASS: produced portable RVA; origin={} entries={} source_bytes={} archive_bytes={} path={:?}",
        std::env::consts::OS, result.entry_count, result.source_bytes, result.archive_bytes, result.path);
    Ok(())
}
fn consume(archive: &Path, expected_origin: &str) -> Result<()> {
    if expected_origin == std::env::consts::OS {
        return Err("consume requires the other OS as expected origin".into());
    }
    let fixture = Fixture::new(&std::env::temp_dir())?;
    let mut reader = ArchiveReader::open(archive, ReaderOptions::default())?;
    assert_eq!(reader.entries().len(), 7);
    let index = reader.entries().iter().position(|e| e.path == rel("origin.txt")).ok_or("missing origin")?;
    let mut origin = Vec::new();
    reader.read_entry_to(index, &mut origin)?;
    assert_eq!(origin, expected_origin.as_bytes());
    assert!(matches!(&reader.entries()[index].entry, EntryKind::File { payload } if payload.compression == Compression::None));
    assert!(reader.entries().iter().any(|e| matches!(&e.entry, EntryKind::File { payload } if payload.compression == Compression::Zlib)));
    let target = fixture.0.join("restored");
    let result = reader.extract_to(&target, ExtractOptions::default())?;
    assert_eq!(result.entry_count, 7);
    assert!(result.metadata.iter().all(|e| e.result.is_success()));
    assert_eq!(fs::read(target.join("origin.txt"))?, expected_origin.as_bytes());
    assert_eq!(fs::read(target.join("payload/çalışma.txt"))?, "RVA V3 — portable Unicode".as_bytes());
    assert_eq!(fs::read(target.join("payload/nested/data.bin"))?, data(37));
    assert_eq!(fs::metadata(target.join("payload/empty.bin"))?.len(), 0);
    assert!(target.join("payload/empty-dir").is_dir());
    check_time(&target.join("payload/çalışma.txt"))?;
    println!("PASS: cross-platform RVA {} -> {}; entries={} output_bytes={} Unicode/empty entries/mtime/content verified",
        expected_origin, std::env::consts::OS, result.entry_count, result.output_bytes);
    Ok(())
}
fn native() -> Result<()> {
    let fixture = Fixture::new(&std::env::temp_dir())?;
    let source = fixture.0.join("source");
    fs::create_dir(&source)?;
    #[cfg(unix)]
    let name = {
        use std::os::unix::ffi::OsStringExt;
        OsString::from_vec(b"native-\xff.bin".to_vec())
    };
    #[cfg(windows)]
    let name = {
        use std::os::windows::ffi::OsStringExt;
        OsString::from_wide(&[110, 97, 116, 105, 118, 101, 45, 0xd800, 46, 98, 105, 110])
    };
    let path = source.join(&name);
    fs::write(&path, b"native filename round trip")?;
    set_time(&path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o751))?;
    }
    #[cfg(windows)]
    {
        let mut permissions = fs::metadata(&path)?.permissions();
        permissions.set_readonly(true);
        fs::set_permissions(&path, permissions)?;
    }
    let archive = fixture.0.join("native.rva");
    let mut writer = ArchiveWriter::new(&archive, WriterOptions { metadata_capture: MetadataCapture::Full, ..Default::default() })?;
    writer.add_file(&path, ArchivePath::from_relative(Path::new(&name))?)?;
    writer.finish()?;
    let mut reader = ArchiveReader::open(&archive, ReaderOptions::default())?;
    assert_eq!(reader.entries().len(), 1);
    let component = &reader.entries()[0].path.0[0];
    #[cfg(unix)]
    assert!(matches!(component, PathComponent::UnixBytes(_)));
    #[cfg(windows)]
    assert!(matches!(component, PathComponent::WindowsUtf16(_)));
    assert_eq!(component.to_native()?, name);
    let captured = reader.entries()[0].metadata.to_filesystem()?;
    assert!(captured.permissions.is_some());
    assert_eq!(captured.modified_at, Some(UNIX_EPOCH + Duration::from_secs(FIXED_TIME)));
    let policy = MetadataPolicy {
        modified_time: MetadataRequirement::Required,
        #[cfg(unix)]
        posix_mode: MetadataRequirement::Required,
        #[cfg(windows)]
        readonly: MetadataRequirement::Required,
        #[cfg(windows)]
        windows_acl: MetadataRequirement::BestEffort,
        ..Default::default()
    };
    let target = fixture.0.join("restored");
    let result = reader.extract_to(&target, ExtractOptions { metadata_policy: Some(policy) })?;
    let actual_names: Vec<OsString> = fs::read_dir(&target)?.map(|e| e.map(|x| x.file_name())).collect::<std::io::Result<_>>()?;
    assert_eq!(actual_names, vec![name.clone()]);
    let actual = target.join(name);
    assert_eq!(fs::read(&actual)?, b"native filename round trip");
    check_time(&actual)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(&actual)?.permissions().mode() & 0o7777, 0o751);
    }
    #[cfg(windows)]
    assert!(fs::metadata(&actual)?.permissions().readonly());
    for entry in &result.metadata {
        for field in &entry.result.fields {
            println!("METADATA field={:?} status={:?} fatal={} error={:?}", field.field, field.status, field.fatal, field.error);
        }
    }
    println!("PASS: native filename and metadata round trip; os={} raw name/bytes/mtime/required platform metadata verified", std::env::consts::OS);
    Ok(())
}
fn benchmark(parent: &Path) -> Result<()> {
    let fixture = Fixture::new(parent)?;
    println!("BENCH environment os={} arch={} profile={} root={:?} file_bytes={} distribution=half_repeated_half_pseudorandom metadata=default",
        std::env::consts::OS, std::env::consts::ARCH, if cfg!(debug_assertions) { "debug" } else { "release" }, fixture.0, FILE_BYTES);
    if cfg!(debug_assertions) { return Err("benchmark requires --release".into()); }
    for count in [1000usize, 10000] {
        let source = fixture.0.join(format!("source-{count}"));
        fs::create_dir(&source)?;
        for index in 0..count {
            let sub = source.join(format!("group-{:04}", index / 100));
            if index % 100 == 0 { fs::create_dir(&sub)?; }
            fs::write(sub.join(format!("file-{index:05}.bin")), data(index))?;
        }
        for compression in [Compression::Zlib, Compression::None] {
            let archive = fixture.0.join(format!("{count}-{compression:?}.rva"));
            let target = fixture.0.join(format!("{count}-{compression:?}-restored"));
            let start = Instant::now();
            let mut writer = ArchiveWriter::new(&archive, WriterOptions { compression, ..Default::default() })?;
            writer.add_directory(&source, rel("files"), true)?;
            let written = writer.finish()?;
            let pack = start.elapsed();
            let start = Instant::now();
            let mut reader = ArchiveReader::open(&archive, ReaderOptions::default())?;
            let extracted = reader.extract_to(&target, ExtractOptions::default())?;
            let unpack = start.elapsed();
            let original_bytes = (count * FILE_BYTES) as u64;
            assert_eq!(written.entry_count, count + count / 100 + 1);
            assert_eq!(written.entry_count, extracted.entry_count);
            assert_eq!(written.source_bytes, original_bytes);
            assert_eq!(extracted.output_bytes, original_bytes);
            // Byte-for-byte fixture validation is outside the measured interval.
            for index in 0..count {
                let path = target.join("files").join(format!("group-{:04}", index / 100)).join(format!("file-{index:05}.bin"));
                assert_eq!(fs::read(path)?, data(index));
            }
            println!("BENCH files={count} compression={compression:?} source_bytes={original_bytes} archive_bytes={} pack_ms={:.3} extract_ms={:.3} archive_pct={:.2} pack_files_s={:.2} extract_files_s={:.2} verified=PASS",
                written.archive_bytes, pack.as_secs_f64() * 1000.0, unpack.as_secs_f64() * 1000.0,
                written.archive_bytes as f64 * 100.0 / original_bytes as f64,
                count as f64 / pack.as_secs_f64(), count as f64 / unpack.as_secs_f64());
            fs::remove_file(&archive)?;
            fs::remove_dir_all(&target)?;
        }
        fs::remove_dir_all(&source)?;
    }
    println!("PASS: release small-file benchmark and byte verification");
    Ok(())
}
fn main() -> Result<()> {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    match args.first().and_then(|s| s.to_str()) {
        Some("produce") if args.len() == 2 => produce(&absolute(&args[1])?),
        Some("consume") if args.len() == 3 => consume(&absolute(&args[1])?, args[2].to_str().ok_or("invalid origin OS")?),
        Some("native") if args.len() == 1 => native(),
        Some("bench") if args.len() == 1 => benchmark(&std::env::temp_dir()),
        Some("bench") if args.len() == 2 => benchmark(&absolute(&args[1])?),
        _ => Err("usage: produce <archive> | consume <archive> <origin-os> | native | bench [existing-work-dir]".into()),
    }
}
