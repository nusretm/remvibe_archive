# ARCHIVE-RUST-01 — RVA V3

2026-11-25. Revised direction supersedes NTA V2/V3 planning. Repository baseline cb444eb41fdac0cbb77502e42d51dc26eb21d495; FileSystem accepted baseline 3942a39bbdecf84144709e899b986fe19c6b8c06. User approved manifest-last, no legacy compatibility, legacy isolation, standalone root Rust package remvibe_archive and future dart/ package remvibe_archive_dart with native/ FFI. Embedded region reader and entry streaming support future deployment/SFX without coupling to them. Initial no-encryption/no-link profile follows the proposed bounded checkpoint; future support separately reviewed.

## Checkpoints

A — Repository and format foundation: exact legacy preservation, root Rust package, format definition, fixed envelope and manifest models/validation, native path and metadata serialization using FileSystem models, focused Windows/Linux compilation and examples. Layout, envelope/bounds, manifest, native path and metadata codec sources committed. Expanded probe, dependency lock and platform acceptance remain open.

B — Writer: selected regular files and recursive/nonrecursive directories, empty entries, streaming zlib/none and SHA-256, one sibling temp archive and manifest-last publication, source-change checks, cancellation and progress. No extra payload spool or transfer grouping.

C — Reader: bounded Read+Seek (path, memory, file region), manifest integrity and bounds, list and stream selected entries, full extraction with per-entry size/hash verification, target collisions and sibling staging, metadata via shared FileSystem policy (dirs last), cleanup/reporting. No overwrite/merge/source deletion. Do not trust embedded metadata as publisher authorization.

D — Real Windows/Linux round trip, portable-name cross-platform archives, native names and metadata, direct Cargo consumer, many small files measurements; focused negative cases. macOS design only. Update continuity, obtain explicit merge/cleanup approval.

## Consumer inspection before legacy relocation

Known remvibe_update_center main dependencies verified from source:
- root pubspec.yaml and ci/draft_packager/pubspec.yaml pin c380c637f5db4d64ec1da41ee5c34615963ef412 (old package root); matching lockfiles, fleet_console transitive lock also pinned.
- installer/CMakeLists.txt FetchContent pins e38c10792d71299601b147a39700ed0e9ab2d51a, SOURCE_SUBDIR native, checks resolved revision. Optional REMVIBE_ARCHIVE_NATIVE_SOURCE_DIR local override must point to old checkout native/ or new _legacy/native/ after relocation. Actual local overrides/other unindexed consumers not verified; confirm before main migration/merge. No changes to these consumers in this checkpoint.
- Old CI workflow moved with legacy tree, not active in new root; no replacement CI added. Historical acceptance retained in _legacy/docs/UC3_CHECKPOINT.md.
- Archive draft docs PR #4 was older NTA V3 working-name revision; this feature's active documentation supersedes it, do not merge old text unchanged.

## Design boundaries

Reuse remvibe_filesystem_core as direct pinned Cargo library; no FileSystem FFI. Serialization belongs to Archive; OS operations/metadata application belong to FileSystem. If existing public API is insufficient, report precise dependency gap and obtain approval for a bounded shared fix. No product-specific settings, UI, networking, deployment or SFX implementation here. FFI and Dart package developed together in ARCHIVE-FFI-01. No separate FFI product. Existing Dart/C++ maintained only via legacy revisions until coordinated migration. Deployment plans: https://github.com/nusretm/remvibe_deployment.

Actual validation: operator reported Windows and Ubuntu cargo check and foundation_probe PASS at exact HEAD fe2ce8e349249b4f6aa2169d75497bac7ba8a293. Expanded foundation adds pinned remvibe_filesystem_core, base64, serde, serde_json and sha2; no compression dependency until B. Expanded build and manifest_probe not yet run. Cargo.lock must be resolved in authorized environment, recorded and committed before A closure. No full A acceptance or merge claimed.
