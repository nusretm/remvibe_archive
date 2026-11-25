# ARCHIVE-FFI-01 — next checkpoint, planning only

Status: READY after ARCHIVE-RUST-01 merge; no implementation authorized yet.

## Goal
Expose the accepted RVA V3 Rust core to Dart via remvibe_archive_dart at dart/, with a private cdylib crate remvibe_archive_ffi at dart/native/. Keep Rust direct Cargo consumers independent of Dart/FFI. Bind the existing core rather than duplicate archive or FileSystem algorithms.

## Preparation and scope review
- Read AGENTS.md, WORKING_RULES.md, README.md, docs/RVA_V3_FORMAT.md, docs/continuity/ARCHIVE_RUST_01.md and current Rust public API; verify current main and dependencies. Review accepted FileSystem Dart FFI and native asset distribution patterns before choosing the binding contract.
- Plan handle ownership/lifetime, errors and memory ownership, progress/cancellation, native path and metadata representation, selected-entry streaming and asynchronous Dart integration as needed for a responsive consumer. Preserve Single/Split/Embedded capabilities, Zstd/Zlib/None, default Zstd level 3 payload/manifest and Buffered extraction, explicit PerFile, strict verification and staging semantics. Exact C ABI, Dart API and checkpoint sequence require review and operator approval before implementation.
- Windows First; actual Windows/Linux acceptance, macOS design only. Focused functional acceptance, no UI automation or unrelated CI/hardening. Verify target native loading and packaging within approved FFI scope. No separate Zstd runtime library intended; static codec linkage has not yet been independently inspected.
- No changes to accepted RVA logical or split wire format without explicit approval. No migration of existing NTA V2 consumers, Installer/Updater/SFX work, FileTransfer/networking implementation, or legacy changes. No new repo/worktree/copy. Preserve pinned legacy consumers; migration later.

## Baseline
Accepted source HEAD 1a07cc6d5f993ca18314fd78c10449c89ec63ca0, accepted source tree 0072d4061a9c1f0e04805c5c3c1d8979e16ee3d9. A–F acceptance evidence in ARCHIVE_RUST_01.md. Root lock 357348eb8dd94d2ad0b3c1bb6bac5af03f3a20c1, independent consumer lock 45d20088bc6d4cdb310e93a33010f20f27379d47. Recheck actual main HEAD after closure. Do not begin implementation from this planning note alone.
