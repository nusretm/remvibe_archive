# RVA V3 format — checkpoint A working specification

New .rva container, no NTA compatibility. All binary integers are unsigned big endian. Layout: fixed 16-byte header, contiguous per-file payloads, UTF-8 JSON manifest, fixed 56-byte footer. Offsets are relative to start of the RVA region (not physical host file). No external bytes in region. Reader must support standalone or bounded embedded region, seek to its region end for footer. All arithmetic checked.

## Header (16 bytes)

| Offset | Length | Value |
|---|---|---|
| 0 | 8 | RVA3 followed by CR LF 0x1a LF |
| 8 | 2 | version = 3 |
| 10 | 2 | flags = 0 in first profile |
| 12 | 4 | reserved = 0 |

## Footer (56 bytes)

| Offset | Length | Value |
|---|---|---|
| 0 | 8 | RVA3END followed by LF |
| 8 | 8 | manifest offset (region-relative) |
| 16 | 8 | manifest byte length (nonzero) |
| 24 | 32 | SHA-256 digest of exact manifest bytes |

Header and footer magic/version/flags checked; region at least 73 bytes; manifest offset >= 16, nonzero length, offset + length == region length - 56. Region start + length must fit physical source. Reject unknown flags/reserved values. ManifestLimits::manifest_range checks configured byte limit and native usize representability before allocation. Footer magic is a new implementation decision, review in A.

## Manifest / payload

UTF-8 JSON object {"entries":[...]} (no unknown fields). Entry order determines file payload order; directory entries consume no bytes. Each entry has path, metadata and entry. The entry object is {"kind":"directory"} or {"kind":"file","payload":{"offset":16,"storedSize":3,"originalSize":3,"compression":"none","sha256":"<64 lowercase hex digits>"}}. Compression is "none" or "zlib". Digests cover original uncompressed bytes; actual payload verification and strict zlib stream consumption belong to B/C. Empty files are explicit, empty zlib streams still have a nonzero stored length; no unexplained payload gaps, overlap or trailing payload bytes. Checked u64 totals; none requires equal stored/original size. Optional metadata.size must equal file originalSize. Manifest hash is over the exact JSON bytes, not reserialized data. Hashes are integrity, not publisher authentication.

Path is a nonempty ordered array of {"encoding":"utf8","value":"name"}, {"encoding":"unixBytes","value":"<standard padded base64>"} or {"encoding":"windowsUtf16","value":"<standard padded base64 of little-endian u16 units>"}. UTF-8 is mandatory when the name is valid Unicode; raw forms only for non-Unicode names. Reject empty, dot/dotdot, NUL, slash, invalid raw encoding, duplicate paths and file ancestors. Raw Windows components also reject backslash and colon. UTF-8 names can contain Unix-valid backslashes and colons; target conversion rejects Windows separators/prefixes and forbidden characters, and C must still verify device aliases, trailing dot/space and actual target collisions before opening files. Foreign raw encodings cannot be restored on an incompatible target. Native source paths are relative normal components; Rust Path component iteration normalizes redundant separators/interior dot components, never parent traversal. No lossy conversion. Ancestors may be implicit if not present as directory entries; explicit directory entries preserve their own metadata.

Metadata object uses optional/null size, createdAt, modifiedAt, accessedAt, readonly, windowsAttributes, permissions. Timestamp fields are {"beforeEpoch":false,"seconds":0,"nanos":0}: magnitude from Unix epoch with explicit sign; nanos < 1e9, no negative zero; conversion to native SystemTime is checked. Permissions tagged by platform: {"platform":"unix","mode":493,"uid":1000,"gid":1000} (07777 mask), or {"platform":"windows","ownerSid":null,"groupSid":null,"inheritanceEnabled":true,"dacl":{...}}. DACL kind absent/null/entries, entries carry revision and ordered entries array. ACE kind access (sid, accessMask, allow, flags) or opaque (bytes array of u8, original native ACE bytes). Distinguish unavailable, null DACL, empty DACL and ordered ACEs. Capture and restoration separate, no implicit foreign ownership/ACL or privileged mode restoration; shared FileSystem metadata policy and results govern application. This wire layer converts metadata, not OS operations; target capability and ACL validity evaluated by FileSystem during application.

Resource defaults chosen for initial implementation (configurable policy, not format maxima): manifest 64 MiB, 1,000,000 entries, 256 path components, individual and total original bytes u64::MAX (overflow rejected). Callers may set stricter byte limits; C must enforce actual output and available resource policy, not just declarations. Current decoder bounds manifest bytes before allocation; entry count and depth checked after JSON parse. No encryption, symbolic links/junctions or special objects; unsupported objects fail explicitly. Hardlink identity not retained. These profile and limit decisions are reviewable before A closure.

Writer uses one temporary sibling file, finalizes manifest/footer, publishes without replacing existing destination; source size/time checks and real progress/cancellation. Reader uses same open source, checks bounds before payload access, supports individual streaming and region-based reading; extraction to absent destination via sibling staging, validate size/hash, apply directories last, report errors/cleanup. These are later implementation stages. Append/edit/compact not in this profile. SFX packaging and platform code signing outside Archive.
