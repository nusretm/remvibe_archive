# remvibe_archive

Native Rust archive library for the new RVA V3 (.rva) format. Direct Cargo dependency for Rust consumers, including future File Transfer, Deployment and SFX. No backward compatibility with NTA V2.

## Layout

- Cargo.toml, src/, examples/: independent Rust library named remvibe_archive.
- dart/: future remvibe_archive_dart package (ARCHIVE-FFI-01 only); its native/ directory contains the private Rust FFI crate remvibe_archive_ffi, not a separate product.
- docs/: current format and continuity documentation.
- _legacy/: exact pre-redesign repository snapshot, including historical Dart/C++ implementation, docs, examples and retired workflow. Not part of the new build. Legacy consumers continue using their pinned commits until coordinated migration.

Read [AGENTS.md](AGENTS.md), [WORKING_RULES.md](WORKING_RULES.md), [current target](docs/continuity/CURRENT_TARGET.md), [ARCHIVE-RUST-01](docs/continuity/ARCHIVE_RUST_01.md) and [RVA V3 format](docs/RVA_V3_FORMAT.md).

Checkpoint A accepted and closed on 2026-11-25: envelope and manifest encoding/decoding, bounded region checks, native path and metadata codecs. Both foundation probes passed on Windows and Ubuntu; the committed Cargo.lock is identical to the independently resolved Ubuntu lockfile and cargo check --locked passed on both platforms. Checkpoint B authorized and in progress: ArchiveWriter source and writer_probe added; Windows and Ubuntu cargo check and all three probes passed at 25228a4; updated Cargo.lock commit and equality verification remain pending. Reader/extraction remain C.

## Writer (Checkpoint B)

Use absolute source/destination paths and explicit relative ArchivePath values. ArchiveWriter::new, add_file, add_file_with_compression, add_directory (recursive or entry only), finish or abort. WriterOptions defaults to Zlib level 6, 1 MiB buffer and basic FileSystem metadata; full metadata is opt-in. Progress callback and thread-safe CancellationToken are available. Output is published only at finish, without replacing a destination. Any add/finish error aborts staging. Run cargo run --example writer_probe for focused acceptance.
