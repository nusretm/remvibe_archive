# RemVibe Archive — current target

2026-11-25: **ARCHIVE-RUST-01 / Checkpoint A IN PROGRESS**. Operator approved root Rust package remvibe_archive, Dart binding remvibe_archive_dart at dart/, private FFI crate under dart/native/ and starting development. Feature branch feature/archive-rust-01-rva-v3 from main cb444eb41fdac0cbb77502e42d51dc26eb21d495. Main remains unchanged until explicit merge approval.

Initial envelope increment fe2ce8e349249b4f6aa2169d75497bac7ba8a293: operator reported cargo check and foundation_probe PASS on Windows and Ubuntu. Expanded foundation now includes manifest/entry model and validation, SHA-256 of manifest, lossless path and metadata serialization, pinned FileSystem dependency. Expanded cargo check/probes and resolved Cargo.lock still pending. No writer/reader or full A acceptance yet. Do not start B before A acceptance. See [ARCHIVE_RUST_01.md](ARCHIVE_RUST_01.md).

Wider sequence unchanged: UI-DATAGRID-MULTISELECT-01, FS-CORE-01, FS-FFI-01, FS-FLUTTER-01 completed; ARCHIVE-RUST-01 active; ARCHIVE-FFI-01; separate Installer/Updater Rust architecture evaluation; ARCHIVE-MIGRATION-01; FT-NETWORKING-01, FT-CORE-01, FT-FFI-01, UC-FILESYSTEM-01A–E. Deployment remains dormant, no new project implementation authorized.
