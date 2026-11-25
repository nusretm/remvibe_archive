# ARCHIVE-FFI-01 — Dart FFI bindings

Status: A AUTHORIZED on 2026-11-25; B–E gated. Main verified f81c41091e6e39d8a4e504bb81df568ddb9ae434.

## Goal
Expose the accepted RVA V3 Rust core to Dart via remvibe_archive_dart at dart/, with a private cdylib crate remvibe_archive_ffi at dart/native/. Keep Rust direct Cargo consumers independent of Dart/FFI. Bind the existing core rather than duplicate archive or FileSystem algorithms.

## Preparation and scope review
- Read AGENTS.md, WORKING_RULES.md, README.md, docs/RVA_V3_FORMAT.md, docs/continuity/ARCHIVE_RUST_01.md and current Rust public API; verify current main and dependencies. Review accepted FileSystem Dart FFI and native asset distribution patterns before choosing the binding contract.
- Plan handle ownership/lifetime, errors and memory ownership, progress/cancellation, native path and metadata representation, selected-entry streaming and asynchronous Dart integration as needed for a responsive consumer. Preserve Single/Split/Embedded capabilities, Zstd/Zlib/None, default Zstd level 3 payload/manifest and Buffered extraction, explicit PerFile, strict verification and staging semantics. Architecture and checkpoint sequence approved; A defines initial ABI; subsequent functional symbols added only in their approved checkpoint.
- Windows First; actual Windows/Linux acceptance, macOS design only. Focused functional acceptance, no UI automation or unrelated CI/hardening. Verify target native loading and packaging within approved FFI scope. No separate Zstd runtime library intended; static codec linkage has not yet been independently inspected.
- No changes to accepted RVA logical or split wire format without explicit approval. No migration of existing NTA V2 consumers, Installer/Updater/SFX work, FileTransfer/networking implementation, or legacy changes. No new repo/worktree/copy. Preserve pinned legacy consumers; migration later.

## Baseline
Accepted source HEAD 1a07cc6d5f993ca18314fd78c10449c89ec63ca0, accepted source tree 0072d4061a9c1f0e04805c5c3c1d8979e16ee3d9. A–F acceptance evidence in ARCHIVE_RUST_01.md. Root lock 357348eb8dd94d2ad0b3c1bb6bac5af03f3a20c1, independent consumer lock 45d20088bc6d4cdb310e93a33010f20f27379d47. Main and accepted source/root lock/legacy tree verified. FileSystem dependency and its accepted main both 3942a39bbdecf84144709e899b986fe19c6b8c06.

## Approved architecture (2026-11-25)
- Root rlib and its lock unchanged; independent private cdylib at dart/native with its own Cargo.lock; Dart package dart/ with its own generated pubspec.lock. No root workspace conversion. Use FS-FFI-01 conventions (ABI version check, operation-specific symbols, borrowed UTF-8 JSON, Rust-owned opaque result buffers, explicit free, structured errors, decimal strings for u64, BigInt, native path units and native asset/absolute-path modes). Archive Dart value models compatible with FS contracts without importing its native hook or DLL; ArchivePath remains the RVA tagged component contract.
- Stateful Writer/Reader handles, one active operation per handle, independent handles can run concurrently. Native operation worker and independent Dart receiver/control; native CancellationToken, no isolate kill; cancel requests only, terminal result after cleanup. Cancelled Reader must close/reopen (one-way token); Writer failed add/finish aborts; explicit close idempotent and awaits native completion. No global registry lock during work/wait. No Core reset or format change.
- Real progress snapshots coalesced about 100 ms, phase/terminal state retained, unknown totals remain unknown. Opening/manifest work may have no numeric progress. Cancellation cooperative at existing core boundaries; successful publication wins late cancel. Binary selected-entry streaming with bounded credit/backpressure and provisional chunks until SHA-256 verification succeeds. No JSON/base64 payloads.
- Proposed public ArchiveService, ArchiveWriter, ArchiveReader, ArchiveOperation<T>, ArchiveReadOperation and typed options/results. Exact functional signatures introduced in B–D. Single default; Split directory, Embedded bounded read only; selected single file extraction, no arbitrary list/subtree, overwrite or merge.
- Native Assets target mappings Windows x64, Linux x64/arm64, macOS x64/arm64 (design only); explicit absolute library override in separate process. Zstd bundled/static intent to be inspected in E. Preserve direct Rust consumer.
## Checkpoints
- A (authorized): private FFI crate and Dart package, ABI v1/header/buffer, native path codec, errors, loading, generic handle/operation substrate, focused foundation probe on Windows/Ubuntu with locked build/analyze and default/explicit native loading. No writer/reader functions.
- B (pending): Writer Single/Split, recursive/nonrecursive and per-file codec, options, progress/cancel, finish/abort/cleanup, real Dart creation and Rust interoperability; heartbeat during work.
- C (pending): Reader Single/Split/Embedded, manifest, verify, full/selected extraction, Buffered/PerFile, metadata, integrity/error/progress/cancel.
- D (pending): selected-entry binary streaming, bounded delivery, pause/resume/cancel, lifecycle and concurrent independent operations.
- E (pending): integrated locked Windows/Linux runtime, both library modes, bidirectional actual Dart Single/Split exchange, CLI package runtime and native linkage inspection, direct Rust consumer regression. Separate merge/cleanup approval.
Each checkpoint requires continuity evidence, actual Windows/Linux acceptance and explicit authorization before next. No UI automation, speculative tests or CI.
