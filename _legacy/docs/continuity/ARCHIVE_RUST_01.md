# ARCHIVE-RUST-01 — approved planning scope

Updated: 2026-11-24. Planned only. Source baseline inspected: main e38c10792d71299601b147a39700ed0e9ab2d51a. Recheck HEAD at implementation start.

## Goal

Provide an independent Rust core reader/writer for the existing NTA V2 unencrypted profile, statically consumable by Rust applications and usable by higher-level transfer libraries. Preserve the existing Dart reader/writer and C++ reader. No NTA V3 or format change.

## Scope

- Existing NTA V2 envelope/manifest, big-endian integers, relative POSIX archive paths, contiguous payload ranges, zlib and none, per-file SHA-256, streaming read/write.
- Regular files, directories, empty files/directories, UTC modification times and supported POSIX permissions; honor the established critical metadata rules, including explicit errors for unsupported critical metadata and setuid/setgid rejection.
- Selected source files with explicit archive-relative paths; nonrecursive directory entry support so callers can exclude large files while retaining correct parents and empty directories. Archive batching/classification belongs to the caller, not this library.
- Real preparation/compression/extraction progress events and lifecycle/cleanup suitable for cancellation; exact Rust API and dependency choices reviewed at implementation.
- Preserve existing path, collision, size-limit, integrity and staging extraction contracts in docs/NTA_V2_FORMAT.md. Extract to an absent destination via sibling staging; do not introduce merge/overwrite or transfer finalization logic.
- No encrypted NTA support in this initial Rust profile. Symbolic link support/policy remains an explicit checkpoint decision; do not silently omit entries. Unsupported entries/metadata fail explicitly. Existing deferred NTA features remain deferred.

## Acceptance

- Rust-to-Rust round trip; Dart-to-Rust and Rust-to-Dart round trips for the common supported profile; Rust-to-C++ extraction for its existing supported profile (including its metadata/platform restrictions).
- Both zlib and none, empty entries, selected-file packaging, nonrecursive directories, streaming larger-than-buffer content, supported metadata and real progress.
- Preserve format validation, corruption/limit/path rejection and staging cleanup on errors. Focused checks only; no unrelated test or CI expansion.
- Real Windows/Linux acceptance with actual evidence; macOS design compatibility only. Existing Dart/C++ behavior unchanged. Do not claim unexecuted tests or builds.

## Non-goals

No replacement of existing implementations, new archive format, encrypted Rust profile, installer/updater work, network transport, filesystem manager, file transfer orchestration, UI, FFI framework or unrelated CI/security work. A subsequent caller may consume the Rust crate directly; no standalone archive DLL is required by this checkpoint.
