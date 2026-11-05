# UC3-0 + UC3-1 checkpoint

## Scope

This checkpoint replaces the incomplete legacy/Delphi archive implementation
with NTA V2. It owns archive creation, archive validation, and extraction only.
Application update orchestration, service lifecycle, rollback, health checks,
publishing, installers, delta updates, and digital signatures remain outside
the library.

## Implemented

- versioned NTA V2 envelope and documented manifest;
- streaming zlib/none payloads and per-file SHA-256;
- optional scrypt-derived AES-256-GCM authenticated encryption with random salt
  and nonce; no default key;
- regular files, directories, empty entries, symbolic links, modification time,
  POSIX modes, extensible platform metadata, and critical-metadata semantics;
- portable path validation, duplicate/case collision detection, safe symlink
  targets, bounded entry/expanded sizes, and contiguous payload validation;
- sibling staging extraction with cleanup and final rename to an absent
  destination;
- Windows, Ubuntu, and macOS CI jobs for analyzer and tests.

## Local evidence (Windows x64, 2026-11-05)

- `dart analyze`: clean, including the Flutter example on the installed local
  Flutter SDK.
- `dart test`: all applicable tests pass. The real symbolic-link and POSIX mode
  tests are platform-gated and therefore await Linux/macOS CI evidence.
- Real unencrypted and encrypted create/open/extract round trips were exercised
  by tests, including a payload larger than the internal 1 MiB I/O chunk.
- Negative tests cover traversal/absolute/drive/UNC paths, case collisions,
  duplicate entries, unexpected types, unsafe symlinks, corrupt/truncated
  headers, authenticated-encryption tampering, SHA-256 mismatch, entry/size
  limits, compressed over-expansion, unsupported critical metadata, existing
  destinations, I/O failure, and staging cleanup after partial extraction.

## Deferred and not yet claimed

- Linux/macOS CI results are not recorded until the Draft PR jobs run.
- Windows symbolic-link creation is not claimed because it depends on host
  privilege/developer-mode policy.
- ACLs, ownership, xattrs, macOS resource forks, Windows alternate data streams
  and special file types remain unsupported. Critical future metadata fails
  explicitly.
- NTA V2 encryption and SHA-256 are not publisher authenticity and do not
  replace the later release-signing design.
