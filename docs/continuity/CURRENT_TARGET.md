# RemVibe Archive — current target

2026-11-25: **ARCHIVE-RUST-01 A–F ACCEPTED AND CLOSED; ARCHIVE-FFI-01 READY FOR PLANNING.** Operator authorized final fast-forward merge and cleanup. Verify actual main/branch refs before starting next checkpoint. No FFI implementation authorized yet.

## Accepted baseline
- Source HEAD 1a07cc6d5f993ca18314fd78c10449c89ec63ca0; source tree 0072d4061a9c1f0e04805c5c3c1d8979e16ee3d9; final acceptance continuity 26f5503e659739722acf797fa99172ddbf8db18e.
- Windows and Ubuntu locked checks, all five probes, independent native consumer, actual bidirectional Single RVA E-format and 25-part split exchange PASS. Full acceptance history and E benchmark results in [ARCHIVE_RUST_01.md](ARCHIVE_RUST_01.md).
- Root lock 357348eb8dd94d2ad0b3c1bb6bac5af03f3a20c1 and consumer lock 45d20088bc6d4cdb310e93a33010f20f27379d47 independently matched across OSs. Legacy snapshot tree 9e578dc48bb8971c2d178b5c96bb8c1993248c4c preserved exactly.
- RVA V3, Single default and Split/Embedded support, Zstd level 3 file/manifest default, Zlib/None retained, Buffered extraction default and explicit PerFile. No NTA V2 compatibility; existing legacy consumers pinned until migration. No macOS runtime, static linkage inspection, crash recovery or large-volume split benchmark claimed.

## Next target
[ARCHIVE-FFI-01](ARCHIVE_FFI_01.md): root remvibe_archive remains direct Rust dependency; Dart package remvibe_archive_dart at dart/, private native crate remvibe_archive_ffi at dart/native/. Review actual sources and accepted contracts, propose bounded implementation checkpoints for approval. No FFI scaffolding or consumer migration yet.

Wider sequence: UI-DATAGRID-MULTISELECT-01, FS-CORE-01, FS-FFI-01, FS-FLUTTER-01, ARCHIVE-RUST-01 completed acceptance; ARCHIVE-FFI-01; separate Installer/Updater Rust architecture evaluation; ARCHIVE-MIGRATION-01; FT-NETWORKING-01, FT-CORE-01, FT-FFI-01, UC-FILESYSTEM-01A–E. Deployment dormant. No unrelated implementation authorized.
