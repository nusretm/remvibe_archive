# remvibe_archive

Native Rust archive library for the new RVA V3 (.rva) format. Direct Cargo dependency for Rust consumers, including future File Transfer, Deployment and SFX. No backward compatibility with NTA V2.

## Layout

- Cargo.toml, src/, examples/: independent Rust library named remvibe_archive.
- dart/: future remvibe_archive_dart package (ARCHIVE-FFI-01 only); its native/ directory contains the private Rust FFI crate remvibe_archive_ffi, not a separate product.
- docs/: current format and continuity documentation.
- _legacy/: exact pre-redesign repository snapshot, including historical Dart/C++ implementation, docs, examples and retired workflow. Not part of the new build. Legacy consumers continue using their pinned commits until coordinated migration.

Read [AGENTS.md](AGENTS.md), [WORKING_RULES.md](WORKING_RULES.md), [current target](docs/continuity/CURRENT_TARGET.md), [ARCHIVE-RUST-01](docs/continuity/ARCHIVE_RUST_01.md) and [RVA V3 format](docs/RVA_V3_FORMAT.md).

Checkpoint A is in progress; this initial foundation implements envelope encoding/decoding and region boundary validation only, not a working archive reader/writer. Runtime acceptance not started.
