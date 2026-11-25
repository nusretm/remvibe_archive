# RVA V3 format — checkpoint E working specification

New .rva container, no NTA compatibility. All binary integers are unsigned big endian. Layout: fixed 16-byte header, contiguous per-file payloads, optionally compressed UTF-8 JSON manifest, fixed 72-byte footer. Offsets are relative to start of the RVA region (not physical host file). No external bytes in region. Reader must support standalone or bounded embedded region, seek to its region end for footer. All arithmetic checked.

## Header (16 bytes)

| Offset | Length | Value |
|---|---|---|
| 0 | 8 | RVA3 followed by CR LF 0x1a LF |
| 8 | 2 | version = 3 |
| 10 | 2 | flags = 0 in first profile |
| 12 | 4 | reserved = 0 |

## Footer (72 bytes)

| Offset | Length | Value |
|---|---|---|
| 0 | 8 | RVA3CMP followed by LF |
| 8 | 8 | manifest offset (region-relative) |
| 16 | 8 | stored manifest byte length (nonzero) |
| 24 | 8 | original JSON manifest byte length (nonzero) |
| 32 | 1 | codec: 0 None, 1 Zlib, 2 Zstd |
| 33 | 7 | reserved = 0 |
| 40 | 32 | SHA-256 of exact original UTF-8 JSON bytes |

Header and footer magic/version/flags checked; region at least 89 bytes; manifest offset >= 16, nonzero length, offset + length == region length - 72. Region start + length must fit physical source. Reject unknown flags/reserved values. ManifestLimits::manifest_range checks configured byte limit and native usize representability before allocation. New footer magic distinguishes the unreleased E revision from A–D.

## Manifest / payload

UTF-8 JSON object {"entries":[...]} (no unknown fields). Entry order determines file payload order; directory entries consume no bytes. Each entry has path, metadata and entry. The entry object is {"kind":"directory"} or {"kind":"file","payload":{"offset":16,"storedSize":3,"originalSize":3,"compression":"none","sha256":"<64 lowercase hex digits>"}}. Compression is "none", "zlib" or "zstd". Digests cover original uncompressed bytes; payload verification requires exact stream consumption for Zlib and Zstd. Empty files are explicit, empty compressed streams still have a nonzero stored length; no unexplained payload gaps, overlap or trailing payload bytes. Checked u64 totals; none requires equal stored/original size. Optional metadata.size must equal file originalSize. Manifest hash is over the exact JSON bytes, not reserialized data. Hashes are integrity, not publisher authentication.

Path is a nonempty ordered array of {"encoding":"utf8","value":"name"}, {"encoding":"unixBytes","value":"<standard padded base64>"} or {"encoding":"windowsUtf16","value":"<standard padded base64 of little-endian u16 units>"}. UTF-8 is mandatory when the name is valid Unicode; raw forms only for non-Unicode names. Reject empty, dot/dotdot, NUL, slash, invalid raw encoding, duplicate paths and file ancestors. Raw Windows components also reject backslash and colon. UTF-8 names can contain Unix-valid backslashes and colons; target conversion rejects Windows separators/prefixes and forbidden characters, and extraction rejects device aliases, trailing dot/space and actual target collisions before writing payloads. Foreign raw encodings cannot be restored on an incompatible target. Native source paths are relative normal components; Rust Path component iteration normalizes redundant separators/interior dot components, never parent traversal. No lossy conversion. Ancestors may be implicit if not present as directory entries; explicit directory entries preserve their own metadata.

Metadata object uses optional/null size, createdAt, modifiedAt, accessedAt, readonly, windowsAttributes, permissions. Timestamp fields are {"beforeEpoch":false,"seconds":0,"nanos":0}: magnitude from Unix epoch with explicit sign; nanos < 1e9, no negative zero; conversion to native SystemTime is checked. Permissions tagged by platform: {"platform":"unix","mode":493,"uid":1000,"gid":1000} (07777 mask), or {"platform":"windows","ownerSid":null,"groupSid":null,"inheritanceEnabled":true,"dacl":{...}}. DACL kind absent/null/entries, entries carry revision and ordered entries array. ACE kind access (sid, accessMask, allow, flags) or opaque (bytes array of u8, original native ACE bytes). Distinguish unavailable, null DACL, empty DACL and ordered ACEs. Capture and restoration separate, no implicit foreign ownership/ACL or privileged mode restoration; shared FileSystem metadata policy and results govern application. This wire layer converts metadata, not OS operations; target capability and ACL validity evaluated by FileSystem during application.

Resource defaults chosen for initial implementation (configurable policy, not format maxima): manifest 64 MiB, 1,000,000 entries, 256 path components, individual and total original bytes u64::MAX (overflow rejected). Callers may set stricter byte limits; C must enforce actual output and available resource policy, not just declarations. Current decoder bounds manifest bytes before allocation; entry count and depth checked after JSON parse. No encryption, symbolic links/junctions or special objects; unsupported objects fail explicitly. Hardlink identity not retained. These profile and limit decisions are reviewable before A closure.

Writer uses one temporary sibling file, finalizes manifest/footer, publishes without replacing existing destination; source size/time checks and real progress/cancellation. Reader uses same open source, checks bounds before payload access, supports individual streaming and region-based reading; extraction to absent destination via sibling staging, validate size/hash, apply directories last, report errors/cleanup. Writer implemented and accepted in B on Windows and Ubuntu (2026-11-25); Reader and extraction implemented and accepted in C on Windows and Ubuntu (2026-11-25). Append/edit/compact not in this profile. SFX packaging and platform code signing outside Archive.

Writer defaults: Zstd level 3 (1–19 configurable), Zlib level 6 (0–9 configurable) as alternative, 1 MiB read buffer, basic FileSystem stat metadata; per-file compression override, full metadata opt-in. Source size/mtime and read count checked before/after; no filesystem snapshot guarantee. No output until successful no-replace sibling publication; failure or cancellation closes writer, cleanup failure includes staging path. Progress counts bytes read/processed from source; archive total unknown until finish. 

Reader uses a bounded owned source, validates manifest on open, verifies each payload on demand. Zlib and Zstd must reach the end of a single complete stream, consume exactly storedSize and produce exactly originalSize; no trailing compressed bytes. SHA-256 checked before success. Entry streaming to external sinks is provisional until success; staged extraction publishes only after verification and requested metadata success. Target aliases checked with exclusive native creation, Windows device names and trailing space/dot rejected. Metadata reports are at application time; caller may defer metadata entirely. 

## E revision (unreleased, incompatible with A–D artifacts)

Header stays 16 bytes/version 3; new distinct footer magic rejects older unpublished footer. Manifest remains last, stored as None/Zlib/Zstd, defaults Zstd. Both stored and original lengths independently bounded by max_manifest_bytes before allocation; exact original JSON digest and length validated after decode. None requires equal lengths. Exactly one full compression stream, no trailing or concatenated frames, no external dictionaries or skippable Zstd frames. Zstd decoder window capped at 128 MiB; supported writer levels 1–19. File payloads stay independent and bounded. No solid compression, encryption, multithreading or split format changes in E. Buffered extraction is the operator-approved default; PerFile remains explicitly selectable. Integrity/publication distinct from power-loss durability. Do not use pre-E generated RVA files with E; regenerate cross-OS fixtures. E accepted and closed on 2026-11-25: Windows/Ubuntu runtime probes, benchmarks, actual bidirectional E-format exchange and focused Buffered-default acceptance PASS. F remains separate.

## F physical split envelope (accepted)

The inner logical RVA byte stream is exactly the E layout above. No changes to its header, payload offsets, manifest or footer. The split set is an absent destination directory (recommended suffix .rva.parts), containing exactly part.000001 through part.NNNNNN. Directory may be renamed as a unit. Each physical file begins with this fixed 72-byte envelope, all integers big endian:

| Offset | Length | Value |
|---|---|---|
| 0 | 8 | RVASPL3 followed by LF |
| 8 | 32 | SHA-256 of complete logical RVA bytes, shared set identity |
| 40 | 8 | one-based part index |
| 48 | 8 | total part count |
| 56 | 8 | total logical RVA length |
| 64 | 8 | logical payload capacity per part (max physical size minus 72) |

max_part_size must exceed 72. Capacity and total nonzero; count = 1 + (total - 1) / capacity, at most 999999 (six-digit names). Each nonfinal part has exactly capacity bytes after the envelope; last has the positive remainder, possibly full capacity. Physical bytes = logical length + count * 72, checked u64 arithmetic. No extra empty last part. Explicit Split can have one part. Header/manifest/footer and any compressed file may cross boundaries. Every part must match the first part's identity/total/count/capacity and its expected index and physical length; all expected names must exist and extra entries are rejected. The shared digest is computed during writer streaming and used as set identity, not an independent full-stream read on open; existing logical manifest and payload SHA-256 verify content on demand. Not publisher authentication. Caller keeps set immutable. Parts opened sequentially for header validation, one cached read handle during seek/read, no concatenation file or open-all handle requirement.

Writer writes envelopes as placeholders in a private sibling staging directory, streams payload bytes directly into bounded parts, finalizes headers after inner footer, syncs each part, closes handles, then uses one shared FileSystem no-replace directory rename. On normal failure/cancel cleans staging; cleanup errors reported. No crash-recovery promise, no independent publication of individual sibling files. Publication directory choice is an F implementation decision to preserve set-level atomic visibility. Physical split files can be transferred independently but must be reunited in one directory before opening. No split-resume editing/repair, no independent per-part extraction, no changes to FileTransfer batching or SFX.

F accepted and closed 2026-11-25 at source HEAD 1a07cc6d5f993ca18314fd78c10449c89ec63ca0: Windows/Ubuntu locked builds, local split probes, single/embedded regression probes, native consumer and actual bidirectional 25-part exchange PASS. No format revision after E for the inner stream.
