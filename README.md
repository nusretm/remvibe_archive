# remvibe_archive

Native Rust archive library for the new RVA V3 (.rva) format. Direct Cargo dependency for Rust consumers, including future File Transfer, Deployment and SFX. No backward compatibility with NTA V2.

## Layout

- Cargo.toml, src/, examples/: independent Rust library named remvibe_archive.
- dart/: future remvibe_archive_dart package (ARCHIVE-FFI-01 only); its native/ directory contains the private Rust FFI crate remvibe_archive_ffi, not a separate product.
- docs/: current format and continuity documentation.
- _legacy/: exact pre-redesign repository snapshot, including historical Dart/C++ implementation, docs, examples and retired workflow. Not part of the new build. Legacy consumers continue using their pinned commits until coordinated migration.

Read [AGENTS.md](AGENTS.md), [WORKING_RULES.md](WORKING_RULES.md), [current target](docs/continuity/CURRENT_TARGET.md), [ARCHIVE-RUST-01](docs/continuity/ARCHIVE_RUST_01.md) and [RVA V3 format](docs/RVA_V3_FORMAT.md).

Checkpoint A accepted and closed on 2026-11-25: envelope and manifest encoding/decoding, bounded region checks, native path and metadata codecs. Both foundation probes passed on Windows and Ubuntu; the committed Cargo.lock is identical to the independently resolved Ubuntu lockfile and cargo check --locked passed on both platforms. Checkpoint B accepted and closed on 2026-11-25: ArchiveWriter, streaming Zlib/None and SHA-256, metadata capture, progress/cancellation and no-replace publication. Windows and Ubuntu cargo check and all three probes passed at 25228a4; updated Cargo.lock committed and independently matched on Ubuntu, with cargo check --locked passing on both platforms at 5b45f9a. Checkpoint C accepted and closed on 2026-11-25: bounded ArchiveReader, strict payload verification and staged extraction. Windows and Ubuntu cargo check --locked and all four probes passed at 02c5cd2, with unchanged Cargo.lock and clean tracked working trees. D acceptance passed on Windows and Ubuntu at 6569dc5 on 2026-11-25: independent Cargo consumer, actual bidirectional RVA exchange, native names/metadata and small-file benchmarks. All A–D acceptance complete; explicit merge and cleanup approval pending.

## Writer (Checkpoint B)

Use absolute source/destination paths and explicit relative ArchivePath values. ArchiveWriter::new, add_file, add_file_with_compression, add_directory (recursive or entry only), finish or abort. WriterOptions defaults to Zlib level 6, 1 MiB buffer and basic FileSystem metadata; full metadata is opt-in. Progress callback and thread-safe CancellationToken are available. Output is published only at finish, without replacing a destination. Any add/finish error aborts staging. Run cargo run --example writer_probe for focused acceptance.

## Reader (Checkpoint C)

ArchiveReader::open(path, ReaderOptions), open_region(path, offset, length, options), from_reader(Read+Seek, options), from_region(source, offset, length, options). List via entries()/manifest(); read_entry_to(index, &mut Write) streams provisional bytes until success, verify() verifies all payloads, extract_to(absent directory, ExtractOptions) or extract_entry_to(index, absent filename, options) publishes only verified output. Shared MetadataPolicy default; None defers metadata. ReaderOptions controls manifest limits, buffer and cancellation. Run cargo run --locked --example reader_probe.

## Acceptance (Checkpoint D)

Independent package examples/direct_consumer depends only on remvibe_archive via Cargo path. Run `cargo run --locked --release --manifest-path examples/direct_consumer/Cargo.toml -- native`, `-- produce <archive>`, `-- consume <archive> <other-os>` and `-- bench [existing-work-dir]`. The portable archive must actually be exchanged across OSs. Benchmark uses 1,000/10,000 files of 4 KiB each, half repeated and half deterministic pseudorandom bytes, Zlib/None, default metadata; measures writer including publication and reader open/extraction including metadata and publication, excludes fixture creation and external byte comparisons. Results are local machine measurements, not a speed guarantee. See continuity for acceptance details.
