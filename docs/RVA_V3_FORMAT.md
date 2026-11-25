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

Header and footer magic/version/flags checked; region at least 73 bytes; manifest offset >= 16, nonzero length, offset + length == region length - 56. Region start + length must fit physical source. Reject unknown flags/reserved values. Manifest size limit must be checked before allocation (remaining A work). Footer magic is a new implementation decision, review in A.

## Manifest / payload (working design — schema and codec pending A)

JSON manifest contains entry list with lossless relative path components and type file/directory, metadata, file offset, stored size, original size, compression (zlib or none), SHA-256 of original bytes. Directories have no payload fields. Zero-length files represented explicitly, no implicit directory omission; independent zlib streams, exact consumption, verify decompressed size and SHA-256. No payload holes, overlaps or unexplained bytes; files ordered by offset including zero-length entries. Reject invalid path components, absolute or traversal paths, duplicates, file/ancestor collisions; target actual filesystem aliases separately checked at extraction. Bounds for manifest, entries and byte totals to be defined in remaining A. No encryption, symlinks/junctions or special objects in first profile; error explicitly. Hardlink identity not retained. Format hashes do not authenticate publishers.

Native names: components encoded as UTF-8 when lossless, otherwise Unix bytes or Windows UTF-16 little-endian code units (base64). No lossy conversion; reject unrepresentable target names, do not impose all Windows filename rules on Unix. Exact serialization fields and canonical validation pending A. Metadata captures FileSystemMetadata / permissions with explicit timestamps, Unix mode/UID/GID and Windows attributes/SID/DACL/ACE representations; preserve unavailable distinction and caller-selected apply policy. No Rust memory layout serialization; precise wire model and timestamps pending A. Metadata capture and application separate; no automatic foreign ownership, ACL or privileged mode.

Writer uses one temporary sibling file, finalizes manifest/footer, publishes without replacing existing destination; source size/time checks and real progress/cancellation. Reader uses same open source, checks bounds before payload access, supports individual streaming and region-based reading; extraction to absent destination via sibling staging, validate size/hash, apply directories last, report errors/cleanup. These are later implementation stages. Append/edit/compact not in this profile. SFX packaging and platform code signing outside Archive.
