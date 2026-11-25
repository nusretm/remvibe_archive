# RemVibe Archive — current target

2026-11-25: **ARCHIVE-RUST-01 A–F ACCEPTED AND CLOSED; ARCHIVE-FFI-01 CHECKPOINT A WINDOWS/UBUNTU FUNCTIONAL PASS; FOCUSED WARNING CORRECTION RETEST PENDING.** Main f81c41091e6e39d8a4e504bb81df568ddb9ae434 verified; operator approved architecture and A–E on 2026-11-25, with implementation limited to A on feature/archive-ffi-01.

## Accepted baseline
- Source HEAD 1a07cc6d5f993ca18314fd78c10449c89ec63ca0; source tree 0072d4061a9c1f0e04805c5c3c1d8979e16ee3d9; final acceptance continuity 26f5503e659739722acf797fa99172ddbf8db18e.
- Windows and Ubuntu locked checks, all five probes, independent native consumer, actual bidirectional Single RVA E-format and 25-part split exchange PASS. Full acceptance history and E benchmark results in [ARCHIVE_RUST_01.md](ARCHIVE_RUST_01.md).
- Root lock 357348eb8dd94d2ad0b3c1bb6bac5af03f3a20c1 and consumer lock 45d20088bc6d4cdb310e93a33010f20f27379d47 independently matched across OSs. Legacy snapshot tree 9e578dc48bb8971c2d178b5c96bb8c1993248c4c preserved exactly.
- RVA V3, Single default and Split/Embedded support, Zstd level 3 file/manifest default, Zlib/None retained, Buffered extraction default and explicit PerFile. No NTA V2 compatibility; existing legacy consumers pinned until migration. No macOS runtime, static linkage inspection, crash recovery or large-volume split benchmark claimed.

## Next target
[ARCHIVE-FFI-01](ARCHIVE_FFI_01.md): root remvibe_archive remains direct Rust dependency; Dart package remvibe_archive_dart at dart/, private native crate remvibe_archive_ffi at dart/native/. Approved A–E plan in ARCHIVE_FFI_01.md. A only: independent FFI foundation, native loading, versioned ABI, paths, errors, handles/operation substrate and focused probe. No Writer/Reader functionality or consumer migration. A source d0b35c3654b8ed698f4a5266261bcecd63524770 implements ABI v1, native path codec, independent cdylib and build hook, typed default inspection via native operation handle and explicit cleanup. Generate actual private Cargo.lock and dart/pubspec.lock in the existing Windows checkout, commit only generated locks; Windows/Ubuntu locked builds/analyze and both loading modes pending. No running archive cancellation/progress, writer/reader or distribution acceptance claimed. B requires explicit A acceptance and authorization.

Wider sequence: UI-DATAGRID-MULTISELECT-01, FS-CORE-01, FS-FFI-01, FS-FLUTTER-01, ARCHIVE-RUST-01 completed acceptance; ARCHIVE-FFI-01; separate Installer/Updater Rust architecture evaluation; ARCHIVE-MIGRATION-01; FT-NETWORKING-01, FT-CORE-01, FT-FFI-01, UC-FILESYSTEM-01A–E. Deployment dormant. No unrelated implementation authorized.

## Checkpoint A — Windows evidence (2026-11-25)
Operator verified exact HEAD 9be8d82f8b327a70c2eaa3382b7c7456a8fd9636 before/after. Private initial and locked check/build, root locked check, Dart pub get/analyze and both Native Assets/explicit DLL foundation runs PASS. Only private Cargo.lock and dart/pubspec.lock untracked; root lock unchanged. Commit actual generated locks and repeat locked acceptance on Windows/Ubuntu; no B authorization.

Both platforms passed at d1061012a6bddec04a9c0b54cee89334ac220c33 with identical committed locks. Ubuntu reported fetch_update deprecation; private FFI allocation loop corrected without Core or dependency changes. Corrected source runtime retest pending on both platforms. See ARCHIVE_FFI_01.md. B authorization remains separate.
