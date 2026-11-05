# RemVibe Archive

`remvibe_archive` creates and extracts cross-platform NTA V2 archives. NTA V2
preserves directory structure, SHA-256 digests, modification times, POSIX
permissions, empty files/directories, and safe symbolic links. File content is
streamed during compression, encryption, hashing, and extraction.

NTA V2 is intentionally incompatible with the old Delphi format.

## Create an unencrypted update package

```dart
final archive = RemvibeArchive.create(
  output: 'update.nta',
  encryption: ArchiveEncryption.none,
);

await archive.addDirectory('build/windows/Release');
await archive.save();
```

`addDirectory` includes the source directory itself by default. Pass
`archivePath: ''` to include only its children, or another relative POSIX path
to choose its archive location.

## Create an encrypted archive

```dart
final archive = RemvibeArchive.create(
  output: 'private.nta',
  encryption: ArchiveEncryption.aes256Gcm,
  passphrase: passphraseFromTheUser,
);

await archive.addFile('report.bin');
await archive.save();
```

Encrypted archives use AES-256-GCM and a random nonce. The key is derived with
scrypt and a random salt; there is no default key.

## Extract

```dart
final archive = await RemvibeArchive.open(
  'update.nta',
  // passphrase: required only for an encrypted archive
);

final result = await archive.extract(
  destination: 'staging',
  policy: ArchiveExtractionPolicy.strict,
);
```

Extraction requires a destination that does not already exist. Content is
validated in a sibling staging directory and renamed into place only after all
entries, SHA-256 digests, limits, and critical metadata succeed. Non-critical
metadata failures are returned in `result.warnings`.

## Security boundary

Encryption protects archive confidentiality and authenticates the encrypted
container. SHA-256 detects per-file corruption. Neither mechanism establishes
publisher identity: software updates still require separately signed trusted
release metadata or a digital signature.

See [docs/NTA_V2_FORMAT.md](docs/NTA_V2_FORMAT.md) for the format and threat
model.
