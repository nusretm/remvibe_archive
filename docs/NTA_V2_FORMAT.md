# NTA V2 format

## Status and scope

NTA V2 is the first supported version of the new RemVibe archive container. It
has no Delphi/legacy compatibility requirement. Multi-volume archives, delta
updates, digital signatures, ACLs, extended attributes, sparse files, hard
links, device nodes, and alternate data streams are deferred.

NTA V2 is a general archive format. Applying an application update, stopping a
service, rollback, and health verification are deliberately outside this
library.

## Binary envelope

All integers are unsigned big-endian.

| Offset | Size | Meaning |
| ---: | ---: | --- |
| 0 | 8 | `NTA2\r\n\x1a\n` magic |
| 8 | 2 | version (`2`) |
| 10 | 2 | flags; bit 0 means encrypted, all other bits must be zero |
| 12 | 4 | UTF-8 public-header JSON length |
| 16 | 8 | stored body length |
| 24 | variable | public-header JSON |
| next | variable | body, plaintext or AES-256-GCM ciphertext plus 16-byte tag |

The preamble and exact public-header bytes are AES-GCM associated data. The
public header identifies the format/version and encryption algorithm. Encrypted
archives record a random 16-byte salt, random 12-byte nonce, and fixed supported
scrypt parameters (`N=16384`, `r=8`, `p=1`). Unsupported algorithms or KDF
parameters fail explicitly.

The plaintext body is:

1. 8-byte manifest length;
2. UTF-8 JSON manifest;
3. concatenated file payloads.

Each regular-file manifest entry records its payload offset/length, uncompressed
size, SHA-256, and compression algorithm (`zlib` or `none`). Payload ranges must
be contiguous, non-overlapping, and account for the complete body. Paths use
`/` regardless of the source platform.

## Entry and metadata model

Supported entry types are `file`, `directory`, and `symbolicLink`. Every entry
has a UTC modification time and an extensible `platformMetadata` object plus a
`criticalMetadata` list. POSIX mode bits are captured on Linux/macOS. Executable
bits are critical because silently dropping them can make an application
unusable. Windows does not require an executable bit; Windows ACLs, hidden/
system attributes, macOS extended attributes, and ownership are deferred.

Critical metadata must be understood and applicable on the extraction target.
Unknown or inapplicable critical metadata aborts extraction. A non-critical
metadata failure is returned as a warning by the strict policy; callers may set
`failOnNonCriticalMetadataError` to turn those warnings into failures.

## Extraction policy and threat model

Before writing entries, the reader validates the complete envelope and
manifest. It rejects:

- malformed/truncated headers, trailing data, unsupported versions/algorithms;
- absolute, drive, UNC, backslash, traversal, reserved-Windows, or ambiguous
  paths;
- duplicate paths, case-fold collisions, missing/non-directory parents;
- unsupported entry types, unsafe symlink targets, overlapping payloads;
- configured entry-count, per-file, and total expanded-size limits.

Extraction occurs in a random sibling staging directory. Regular files are
streamed through decompression and SHA-256 verification. Symlinks are created
last, their targets must resolve lexically inside the archive root, and every
output parent is rechecked as a real directory. The completed staging directory
is renamed to the previously absent destination. Any failure removes staging
and leaves the destination absent.

This design protects against malicious archive contents and ordinary I/O
failure. It does not promise race-free extraction when another hostile process
can mutate the staging directory concurrently; callers must protect the parent
directory with normal OS permissions.

## Authenticity

AES-GCM authenticates an encrypted container to a holder of its passphrase.
Per-file SHA-256 detects corruption. Neither proves who published an archive,
and unencrypted update packages therefore require signed trusted release
metadata or a separate digital-signature system.
