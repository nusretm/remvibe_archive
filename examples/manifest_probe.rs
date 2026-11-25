use remvibe_archive::*;
use remvibe_filesystem_core::{FileSystemMetadata, FileSystemAttributes, FileSystemPermissions, UnixPermissions, WindowsPermissions, WindowsDacl, WindowsAce, WindowsAccessType};
use std::{path::Path, time::{Duration, UNIX_EPOCH}};

fn main() {
    let metadata = FileSystemMetadata {
        size: Some(3), modified_at: Some(UNIX_EPOCH - Duration::new(1, 123)),
        permissions: Some(FileSystemPermissions::Unix(UnixPermissions { mode: 0o755, uid: 1000, gid: 1000 })),
        ..Default::default()
    };
    let archive_meta = ArchiveMetadata::from(&metadata);
    assert_eq!(archive_meta.to_filesystem().unwrap(), metadata);
    let windows = FileSystemMetadata {
        permissions: Some(FileSystemPermissions::Windows(WindowsPermissions {
            owner_sid: Some("S-1-5-18".into()), group_sid: None, inheritance_enabled: false,
            dacl: WindowsDacl::Entries { revision: 2, entries: vec![
                WindowsAce::Access { sid: "S-1-5-18".into(), access_mask: 1, access_type: WindowsAccessType::Allow, flags: 0 },
                WindowsAce::Opaque(vec![0, 0, 4, 0]),
            ] },
        })),
        attributes: FileSystemAttributes { readonly: Some(false), windows: Some(32) },
        ..Default::default()
    };
    let json = serde_json::to_vec(&ArchiveMetadata::from(&windows)).unwrap();
    let restored: ArchiveMetadata = serde_json::from_slice(&json).unwrap();
    assert_eq!(restored.to_filesystem().unwrap(), windows);
    let path = ArchivePath::from_relative(Path::new("dir/çalışma.txt")).unwrap();
    assert_eq!(path.to_relative().unwrap(), Path::new("dir/çalışma.txt"));
    assert!(ArchivePath(vec![PathComponent::Utf8("..".into())]).validate().is_err());
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let name = std::ffi::OsStr::from_bytes(b"native-\xff");
        let component = PathComponent::from_native(name).unwrap();
        assert_eq!(component.to_native().unwrap(), name);
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStringExt;
        let name = std::ffi::OsString::from_wide(&[110, 0xd800]);
        let component = PathComponent::from_native(&name).unwrap();
        assert_eq!(component.to_native().unwrap(), name);
    }
    let manifest = ArchiveManifest { entries: vec![ArchiveEntry {
        path, metadata: archive_meta, entry: EntryKind::File { payload: FilePayload {
            offset: 16, stored_size: 3, original_size: 3, compression: Compression::None,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad".into(),
        } },
    }] };
    let limits = ManifestLimits::default();
    let (bytes, footer) = manifest.encode(19, &limits).unwrap();
    let len = 19 + bytes.len() as u64 + FOOTER_LEN as u64;
    let region = ArchiveRegion::new(1024, len, 1024 + len).unwrap();
    assert_eq!(ArchiveManifest::decode(&bytes, footer, region, &limits).unwrap(), manifest);
    let mut bad = bytes.clone(); bad[0] ^= 1;
    assert!(ArchiveManifest::decode(&bad, footer, region, &limits).is_err());
    let mut duplicate = manifest.clone(); duplicate.entries.push(manifest.entries[0].clone());
    assert!(duplicate.validate(19, &limits).is_err());
    assert!(manifest.validate(20, &limits).is_err());
    let limited = ManifestLimits { max_manifest_bytes: 1, ..limits };
    assert!(limited.manifest_range(footer, region).is_err());
    println!("PASS: RVA manifest, native names, metadata and validation probe");
}
