import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';

import 'archive_crypto.dart';
import 'archive_exception.dart';
import 'archive_format.dart';
import 'archive_model.dart';

const int _ioChunkSize = 1024 * 1024;
const Set<String> _supportedCriticalMetadata = {
  'modifiedTimeUtc',
  'posixMode',
  'symbolicLink',
};

class RemvibeArchive {
  RemvibeArchive._create({
    required this.path,
    required ArchiveEncryption encryption,
    required ArchiveCompression compression,
    required String? passphrase,
  })  : _encryption = encryption,
        _compression = compression,
        _passphrase = passphrase,
        _isBuilder = true,
        _containerHeader = null;

  RemvibeArchive._open({
    required this.path,
    required ArchiveEncryption encryption,
    required String? passphrase,
    required _ContainerHeader containerHeader,
    required List<StoredEntry> storedEntries,
  })  : _encryption = encryption,
        _compression = ArchiveCompression.zlib,
        _passphrase = passphrase,
        _isBuilder = false,
        _containerHeader = containerHeader,
        _storedEntries = storedEntries;

  factory RemvibeArchive.create({
    required String output,
    ArchiveEncryption encryption = ArchiveEncryption.none,
    ArchiveCompression compression = ArchiveCompression.zlib,
    String? passphrase,
  }) {
    if (output.trim().isEmpty) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArgument,
        'The output path cannot be empty.',
      );
    }
    if (encryption == ArchiveEncryption.aes256Gcm &&
        (passphrase == null || passphrase.isEmpty)) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArgument,
        'AES-256-GCM archives require a non-empty passphrase.',
      );
    }
    return RemvibeArchive._create(
      path: output,
      encryption: encryption,
      compression: compression,
      passphrase: passphrase,
    );
  }

  static Future<RemvibeArchive> open(
    String archivePath, {
    String? passphrase,
  }) async {
    _ContainerHeader? header;
    Directory? temporaryDirectory;
    try {
      header = await _readContainerHeader(archivePath);
      if (header.encryption == ArchiveEncryption.aes256Gcm &&
          (passphrase == null || passphrase.isEmpty)) {
        throw const ArchiveException(
          ArchiveErrorCode.authenticationFailed,
          'This archive is encrypted and requires a passphrase.',
        );
      }
      temporaryDirectory = await Directory.systemTemp.createTemp('nta-open-');
      final bodyFile = File(p.join(temporaryDirectory.path, 'body.bin'));
      await _materializeBody(
        archivePath: archivePath,
        header: header,
        passphrase: passphrase,
        output: bodyFile,
      );
      final parsed = await _readManifest(bodyFile);
      return RemvibeArchive._open(
        path: archivePath,
        encryption: header.encryption,
        passphrase: passphrase,
        containerHeader: header,
        storedEntries: parsed.entries,
      );
    } on ArchiveException {
      rethrow;
    } on Object catch (error) {
      throw ArchiveException(
        ArchiveErrorCode.ioFailure,
        'Could not open archive $archivePath.',
        error,
      );
    } finally {
      if (temporaryDirectory != null && await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    }
  }

  final String path;
  final ArchiveEncryption _encryption;
  final ArchiveCompression _compression;
  final String? _passphrase;
  final bool _isBuilder;
  final _ContainerHeader? _containerHeader;
  final List<_SourceSpec> _sources = [];
  List<StoredEntry> _storedEntries = [];

  ArchiveEncryption get encryption => _encryption;

  List<ArchiveEntry> get entries =>
      List.unmodifiable(_storedEntries.map((stored) => stored.entry));

  Future<void> addDirectory(
    String sourcePath, {
    String? archivePath,
  }) async {
    _requireBuilder();
    final directory = Directory(sourcePath);
    if (await FileSystemEntity.type(sourcePath, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw ArchiveException(
        ArchiveErrorCode.invalidArgument,
        'Source directory does not exist: $sourcePath',
      );
    }
    final target = archivePath ?? p.basename(p.normalize(directory.absolute.path));
    if (target.isNotEmpty) _validateArchivePath(target);
    _sources.add(_SourceSpec(directory.path, target, true));
  }

  Future<void> addFile(
    String sourcePath, {
    String? archivePath,
  }) async {
    _requireBuilder();
    final file = File(sourcePath);
    if (await FileSystemEntity.type(sourcePath, followLinks: false) !=
        FileSystemEntityType.file) {
      throw ArchiveException(
        ArchiveErrorCode.invalidArgument,
        'Source file does not exist: $sourcePath',
      );
    }
    final target = archivePath ?? p.basename(file.path);
    _validateArchivePath(target);
    _sources.add(_SourceSpec(file.path, target, false));
  }

  Future<void> save() async {
    _requireBuilder();
    if (_sources.isEmpty) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArgument,
        'At least one file or directory must be added before save().',
      );
    }

    final output = File(p.absolute(path));
    final parent = output.parent;
    if (!await parent.exists()) {
      throw ArchiveException(
        ArchiveErrorCode.ioFailure,
        'The output parent directory does not exist: ${parent.path}',
      );
    }
    if (await FileSystemEntity.type(output.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw ArchiveException(
        ArchiveErrorCode.destinationExists,
        'Refusing to overwrite existing archive: ${output.path}',
      );
    }

    Directory? workDirectory;
    File? temporaryOutput;
    try {
      workDirectory = await parent.createTemp('.nta-build-');
      final pendingEntries = await _scanSources();
      _validatePendingEntries(pendingEntries);

      final payload = File(p.join(workDirectory.path, 'payload.bin'));
      final storedEntries = await _writePayload(payload, pendingEntries);
      final manifestBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(_manifestJson(storedEntries))),
      );
      if (manifestBytes.length > maxManifestLength) {
        throw const ArchiveException(
          ArchiveErrorCode.resourceLimitExceeded,
          'The archive manifest exceeds the NTA V2 limit.',
        );
      }

      final encrypted = _encryption == ArchiveEncryption.aes256Gcm;
      final salt = encrypted ? secureRandomBytes(16) : null;
      final nonce = encrypted ? secureRandomBytes(gcmNonceLength) : null;
      final publicHeaderBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(_publicHeaderJson(salt: salt, nonce: nonce))),
      );
      final payloadLength = await payload.length();
      final plainBodyLength = 8 + manifestBytes.length + payloadLength;
      final bodyLength = plainBodyLength + (encrypted ? gcmTagLength : 0);
      final preamble = buildPreamble(
        encrypted: encrypted,
        publicHeaderLength: publicHeaderBytes.length,
        bodyLength: bodyLength,
      );

      temporaryOutput = File(
        p.join(parent.path, '.${p.basename(output.path)}.tmp-${_randomSuffix()}'),
      );
      await _writeContainer(
        output: temporaryOutput,
        preamble: preamble,
        publicHeader: publicHeaderBytes,
        manifest: manifestBytes,
        payload: payload,
        salt: salt,
        nonce: nonce,
      );

      if (await FileSystemEntity.type(output.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw ArchiveException(
          ArchiveErrorCode.destinationExists,
          'The output path appeared while the archive was being built.',
        );
      }
      await temporaryOutput.rename(output.path);
      temporaryOutput = null;
      _storedEntries = storedEntries;
    } on ArchiveException {
      rethrow;
    } on Object catch (error) {
      throw ArchiveException(
        ArchiveErrorCode.ioFailure,
        'Could not save archive ${output.path}.',
        error,
      );
    } finally {
      if (temporaryOutput != null && await temporaryOutput.exists()) {
        await temporaryOutput.delete();
      }
      if (workDirectory != null && await workDirectory.exists()) {
        await workDirectory.delete(recursive: true);
      }
    }
  }

  Future<ArchiveExtractionResult> extract({
    required String destination,
    ArchiveExtractionPolicy policy = ArchiveExtractionPolicy.strict,
  }) async {
    if (_isBuilder || _containerHeader == null) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArgument,
        'Save and reopen an archive before extracting it.',
      );
    }
    _validatePolicy(policy);

    final destinationDirectory = Directory(p.absolute(destination));
    final parent = destinationDirectory.parent;
    if (!await parent.exists()) {
      throw ArchiveException(
        ArchiveErrorCode.ioFailure,
        'The destination parent directory does not exist: ${parent.path}',
      );
    }
    if (await FileSystemEntity.type(
          destinationDirectory.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound) {
      throw ArchiveException(
        ArchiveErrorCode.destinationExists,
        'Extraction requires a destination that does not exist.',
      );
    }

    final staging = Directory(
      p.join(parent.path, '.${p.basename(destinationDirectory.path)}.nta-staging-${_randomSuffix()}'),
    );
    final body = File(
      p.join(parent.path, '.${p.basename(destinationDirectory.path)}.nta-body-${_randomSuffix()}'),
    );
    final warnings = <String>[];
    var committed = false;
    try {
      await staging.create();
      await _materializeBody(
        archivePath: path,
        header: _containerHeader,
        passphrase: _passphrase,
        output: body,
      );
      final parsed = await _readManifest(body);
      _validateExtractionLimits(parsed.entries, policy);
      _validateCriticalMetadata(parsed.entries);

      final directories = parsed.entries
          .where((stored) => stored.entry.type == ArchiveEntryType.directory)
          .toList()
        ..sort((left, right) => _pathDepth(left.entry.path)
            .compareTo(_pathDepth(right.entry.path)));
      for (final stored in directories) {
        await Directory(_targetPath(staging.path, stored.entry.path)).create();
      }

      final bodyHandle = await body.open();
      try {
        for (final stored in parsed.entries.where(
          (stored) => stored.entry.type == ArchiveEntryType.file,
        )) {
          await _extractFile(
            bodyHandle: bodyHandle,
            payloadStart: parsed.payloadStart,
            stored: stored,
            stagingPath: staging.path,
            policy: policy,
          );
          await _applyMetadata(
            stored.entry,
            _targetPath(staging.path, stored.entry.path),
            policy,
            warnings,
          );
        }
      } finally {
        await bodyHandle.close();
      }

      for (final stored in parsed.entries.where(
        (stored) => stored.entry.type == ArchiveEntryType.symbolicLink,
      )) {
        final targetPath = _targetPath(staging.path, stored.entry.path);
        await _ensureSafeParentChain(staging.path, stored.entry.path);
        try {
          await Link(targetPath).create(stored.entry.linkTarget!);
        } on Object catch (error) {
          throw ArchiveException(
            ArchiveErrorCode.unsupportedMetadata,
            'Could not create symbolic link ${stored.entry.path}.',
            error,
          );
        }
      }

      for (final stored in directories.reversed) {
        await _applyMetadata(
          stored.entry,
          _targetPath(staging.path, stored.entry.path),
          policy,
          warnings,
        );
      }

      if (await FileSystemEntity.type(
            destinationDirectory.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw ArchiveException(
          ArchiveErrorCode.destinationExists,
          'The destination appeared during extraction.',
        );
      }
      await staging.rename(destinationDirectory.path);
      committed = true;
      return ArchiveExtractionResult(
        destination: destinationDirectory.path,
        entriesExtracted: parsed.entries.length,
        warnings: List.unmodifiable(warnings),
      );
    } on ArchiveException {
      rethrow;
    } on Object catch (error) {
      throw ArchiveException(
        ArchiveErrorCode.ioFailure,
        'Could not extract archive to ${destinationDirectory.path}.',
        error,
      );
    } finally {
      if (!committed && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      if (await body.exists()) await body.delete();
    }
  }

  void _requireBuilder() {
    if (!_isBuilder) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArgument,
        'Files can only be added to an archive created with create().',
      );
    }
  }

  Future<List<_PendingEntry>> _scanSources() async {
    final result = <_PendingEntry>[];
    for (final source in _sources) {
      if (source.isDirectory) {
        if (source.archivePath.isNotEmpty) {
          await _scanEntity(source.sourcePath, source.archivePath, result);
        } else {
          final children = await Directory(source.sourcePath)
              .list(followLinks: false)
              .toList();
          children.sort((left, right) => left.path.compareTo(right.path));
          for (final child in children) {
            await _scanEntity(child.path, p.basename(child.path), result);
          }
        }
      } else {
        await _scanEntity(source.sourcePath, source.archivePath, result);
      }
    }
    result.sort((left, right) => left.archivePath.compareTo(right.archivePath));
    return result;
  }

  Future<void> _scanEntity(
    String sourcePath,
    String archivePath,
    List<_PendingEntry> result,
  ) async {
    _validateArchivePath(archivePath);
    final type = await FileSystemEntity.type(sourcePath, followLinks: false);
    switch (type) {
      case FileSystemEntityType.file:
        final stat = await File(sourcePath).stat();
        result.add(_pendingFromStat(sourcePath, archivePath, stat, ArchiveEntryType.file));
        break;
      case FileSystemEntityType.directory:
        final directory = Directory(sourcePath);
        final stat = await directory.stat();
        result.add(
          _pendingFromStat(sourcePath, archivePath, stat, ArchiveEntryType.directory),
        );
        final children = await directory.list(followLinks: false).toList();
        children.sort((left, right) => left.path.compareTo(right.path));
        for (final child in children) {
          await _scanEntity(
            child.path,
            '$archivePath/${p.basename(child.path)}',
            result,
          );
        }
        break;
      case FileSystemEntityType.link:
        final link = Link(sourcePath);
        final target = await link.target();
        _validateLinkTarget(archivePath, target);
        DateTime modified;
        try {
          modified = (await link.stat()).modified.toUtc();
        } on Object {
          modified = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        }
        result.add(
          _PendingEntry(
            sourcePath: sourcePath,
            archivePath: archivePath,
            type: ArchiveEntryType.symbolicLink,
            size: 0,
            modifiedTimeUtc: modified,
            posixMode: null,
            linkTarget: target,
            criticalMetadata: const {'symbolicLink'},
          ),
        );
        break;
      default:
        throw ArchiveException(
          ArchiveErrorCode.invalidArgument,
          'Unsupported filesystem entry type at $sourcePath.',
        );
    }
  }

  _PendingEntry _pendingFromStat(
    String sourcePath,
    String archivePath,
    FileStat stat,
    ArchiveEntryType type,
  ) {
    final mode = Platform.isWindows ? null : stat.mode & 0xfff;
    final critical = <String>{};
    if (type == ArchiveEntryType.file && mode != null && mode & 0x49 != 0) {
      critical.add('posixMode');
    }
    return _PendingEntry(
      sourcePath: sourcePath,
      archivePath: archivePath,
      type: type,
      size: type == ArchiveEntryType.file ? stat.size : 0,
      modifiedTimeUtc: stat.modified.toUtc(),
      posixMode: mode,
      linkTarget: null,
      criticalMetadata: critical,
    );
  }

  void _validatePendingEntries(List<_PendingEntry> entries) {
    final paths = <String, _PendingEntry>{};
    final foldedPaths = <String, String>{};
    for (final entry in entries) {
      final existing = paths[entry.archivePath];
      if (existing != null) {
        throw ArchiveException(
          ArchiveErrorCode.duplicateEntry,
          'Duplicate archive path: ${entry.archivePath}',
        );
      }
      final folded = entry.archivePath.toLowerCase();
      final caseCollision = foldedPaths[folded];
      if (caseCollision != null) {
        throw ArchiveException(
          ArchiveErrorCode.duplicateEntry,
          'Case-insensitive path collision: $caseCollision and ${entry.archivePath}',
        );
      }
      paths[entry.archivePath] = entry;
      foldedPaths[folded] = entry.archivePath;
    }
    _validateParentEntries(
      paths.map((key, value) => MapEntry(key, value.type)),
    );
  }

  Future<List<StoredEntry>> _writePayload(
    File payload,
    List<_PendingEntry> entries,
  ) async {
    final output = payload.openWrite();
    var payloadOffset = 0;
    final storedEntries = <StoredEntry>[];
    try {
      for (final pending in entries) {
        if (pending.type != ArchiveEntryType.file) {
          storedEntries.add(StoredEntry(entry: pending.toArchiveEntry(), dataOffset: null, storedSize: null));
          continue;
        }
        final before = await File(pending.sourcePath).stat();
        final digest = SHA256Digest();
        final counter = _CountingSink(output);
        final Sink<List<int>> dataSink;
        final compression = _compression;
        if (compression == ArchiveCompression.zlib) {
          dataSink = ZLibEncoder().startChunkedConversion(counter);
        } else {
          dataSink = counter;
        }
        final input = await File(pending.sourcePath).open();
        var bytesRead = 0;
        try {
          while (true) {
            final chunk = await input.read(_ioChunkSize);
            if (chunk.isEmpty) break;
            final bytes = Uint8List.fromList(chunk);
            bytesRead += bytes.length;
            digest.update(bytes, 0, bytes.length);
            dataSink.add(bytes);
          }
          dataSink.close();
        } finally {
          await input.close();
        }
        final after = await File(pending.sourcePath).stat();
        if (before.size != after.size ||
            before.modified != after.modified ||
            bytesRead != before.size) {
          throw ArchiveException(
            ArchiveErrorCode.sourceChanged,
            'Source changed while archiving: ${pending.sourcePath}',
          );
        }
        final hash = Uint8List(digest.digestSize);
        digest.doFinal(hash, 0);
        final entry = pending.toArchiveEntry(
          size: bytesRead,
          sha256: hexEncode(hash),
          compression: compression,
        );
        storedEntries.add(
          StoredEntry(
            entry: entry,
            dataOffset: payloadOffset,
            storedSize: counter.bytesWritten,
          ),
        );
        payloadOffset += counter.bytesWritten;
      }
    } finally {
      await output.close();
    }
    return storedEntries;
  }

  Map<String, Object?> _manifestJson(List<StoredEntry> entries) => {
        'format': 'NTA',
        'version': ntaVersion,
        'sourcePlatform': Platform.operatingSystem,
        'entries': entries.map(_storedEntryJson).toList(),
        'extensions': <String, Object?>{},
      };

  Map<String, Object?> _storedEntryJson(StoredEntry stored) {
    final entry = stored.entry;
    return {
      'path': entry.path,
      'type': _entryTypeName(entry.type),
      'size': entry.size,
      'sha256': entry.sha256,
      'modifiedTimeUtc': entry.modifiedTimeUtc.toIso8601String(),
      'posixMode': entry.posixMode,
      'linkTarget': entry.linkTarget,
      'compression': entry.compression?.name,
      'dataOffset': stored.dataOffset,
      'storedSize': stored.storedSize,
      'platformMetadata': entry.platformMetadata,
      'criticalMetadata': entry.criticalMetadata.toList()..sort(),
    };
  }

  Map<String, Object?> _publicHeaderJson({
    Uint8List? salt,
    Uint8List? nonce,
  }) {
    if (_encryption == ArchiveEncryption.none) {
      return {
        'format': 'NTA',
        'version': ntaVersion,
        'encryption': {'algorithm': 'none'},
      };
    }
    return {
      'format': 'NTA',
      'version': ntaVersion,
      'encryption': {
        'algorithm': 'aes-256-gcm',
        'nonce': base64Encode(nonce!),
        'kdf': {
          'algorithm': 'scrypt',
          'salt': base64Encode(salt!),
          'n': scryptCost,
          'r': scryptBlockSize,
          'p': scryptParallelization,
        },
      },
    };
  }

  Future<void> _writeContainer({
    required File output,
    required Uint8List preamble,
    required Uint8List publicHeader,
    required Uint8List manifest,
    required File payload,
    required Uint8List? salt,
    required Uint8List? nonce,
  }) async {
    final handle = await output.open(mode: FileMode.write);
    Uint8List? key;
    try {
      await handle.writeFrom(preamble);
      await handle.writeFrom(publicHeader);
      final aad = Uint8List.fromList([...preamble, ...publicHeader]);
      GCMBlockCipher? cipher;
      var pendingCipherInput = <int>[];
      if (_encryption == ArchiveEncryption.aes256Gcm) {
        key = deriveArchiveKey(_passphrase!, salt!);
        cipher = createGcmCipher(
          forEncryption: true,
          key: key,
          nonce: nonce!,
          associatedData: aad,
        );
      }

      Future<void> writeBodyChunk(Uint8List chunk) async {
        if (cipher == null) {
          await handle.writeFrom(chunk);
          return;
        }
        pendingCipherInput.addAll(chunk);
        final processLength =
            pendingCipherInput.length - (pendingCipherInput.length % 16);
        if (processLength == 0) return;
        final input = Uint8List.fromList(
          pendingCipherInput.sublist(0, processLength),
        );
        pendingCipherInput = pendingCipherInput.sublist(processLength);
        final encrypted = Uint8List(input.length + 32);
        final count = cipher.processBytes(input, 0, input.length, encrypted, 0);
        if (count > 0) await handle.writeFrom(encrypted, 0, count);
      }

      await writeBodyChunk(uint64Bytes(manifest.length));
      await writeBodyChunk(manifest);
      final payloadHandle = await payload.open();
      try {
        while (true) {
          final chunk = await payloadHandle.read(_ioChunkSize);
          if (chunk.isEmpty) break;
          await writeBodyChunk(Uint8List.fromList(chunk));
        }
      } finally {
        await payloadHandle.close();
      }
      if (cipher != null) {
        if (pendingCipherInput.isNotEmpty) {
          final input = Uint8List.fromList(pendingCipherInput);
          final encrypted = Uint8List(input.length + 32);
          final count = cipher.processBytes(
            input,
            0,
            input.length,
            encrypted,
            0,
          );
          if (count > 0) await handle.writeFrom(encrypted, 0, count);
        }
        final finalBytes = Uint8List(32);
        final count = cipher.doFinal(finalBytes, 0);
        if (count > 0) await handle.writeFrom(finalBytes, 0, count);
      }
      await handle.flush();
    } finally {
      if (key != null) key.fillRange(0, key.length, 0);
      await handle.close();
    }
  }
}

Future<_ContainerHeader> _readContainerHeader(String archivePath) async {
  final file = File(archivePath);
  if (!await file.exists()) {
    throw ArchiveException(
      ArchiveErrorCode.ioFailure,
      'Archive does not exist: $archivePath',
    );
  }
  final handle = await file.open();
  try {
    final fileLength = await handle.length();
    if (fileLength < preambleLength) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArchive,
        'The archive is truncated before the NTA V2 preamble.',
      );
    }
    final preambleBytes = await _readExact(handle, preambleLength);
    final preamble = parsePreamble(preambleBytes);
    final expectedLength =
        preambleLength + preamble.publicHeaderLength + preamble.bodyLength;
    if (fileLength != expectedLength) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArchive,
        'The archive length does not match its header.',
      );
    }
    final publicHeaderBytes =
        await _readExact(handle, preamble.publicHeaderLength);
    final publicHeader = decodeJsonObject(publicHeaderBytes, 'public header');
    if (publicHeader['format'] != 'NTA' || publicHeader['version'] != ntaVersion) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArchive,
        'The public header identity is invalid.',
      );
    }
    final encryption = publicHeader['encryption'];
    if (encryption is! Map<String, Object?>) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArchive,
        'The encryption descriptor is missing.',
      );
    }
    final algorithm = encryption['algorithm'];
    if (algorithm == 'none') {
      if (preamble.encrypted) {
        throw const ArchiveException(
          ArchiveErrorCode.invalidArchive,
          'Encryption flags and metadata disagree.',
        );
      }
      return _ContainerHeader(
        preambleBytes: preambleBytes,
        publicHeaderBytes: publicHeaderBytes,
        bodyOffset: preambleLength + preamble.publicHeaderLength,
        bodyLength: preamble.bodyLength,
        encryption: ArchiveEncryption.none,
        salt: null,
        nonce: null,
      );
    }
    if (algorithm != 'aes-256-gcm') {
      throw ArchiveException(
        ArchiveErrorCode.unsupportedAlgorithm,
        'Unsupported encryption algorithm: $algorithm',
      );
    }
    if (!preamble.encrypted || preamble.bodyLength < gcmTagLength) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArchive,
        'Encrypted archive flags or length are invalid.',
      );
    }
    final kdf = encryption['kdf'];
    if (kdf is! Map<String, Object?> ||
        kdf['algorithm'] != 'scrypt' ||
        kdf['n'] != scryptCost ||
        kdf['r'] != scryptBlockSize ||
        kdf['p'] != scryptParallelization) {
      throw const ArchiveException(
        ArchiveErrorCode.unsupportedAlgorithm,
        'Unsupported or unsafe NTA V2 key derivation parameters.',
      );
    }
    final salt = _decodeBase64Field(kdf['salt'], 'scrypt salt');
    final nonce = _decodeBase64Field(encryption['nonce'], 'GCM nonce');
    if (salt.length != 16 || nonce.length != gcmNonceLength) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArchive,
        'Encryption salt or nonce length is invalid.',
      );
    }
    return _ContainerHeader(
      preambleBytes: preambleBytes,
      publicHeaderBytes: publicHeaderBytes,
      bodyOffset: preambleLength + preamble.publicHeaderLength,
      bodyLength: preamble.bodyLength,
      encryption: ArchiveEncryption.aes256Gcm,
      salt: salt,
      nonce: nonce,
    );
  } finally {
    await handle.close();
  }
}

Future<void> _materializeBody({
  required String archivePath,
  required _ContainerHeader header,
  required String? passphrase,
  required File output,
}) async {
  final currentHeader = await _readContainerHeader(archivePath);
  if (!listEquals(currentHeader.preambleBytes, header.preambleBytes) ||
      !listEquals(currentHeader.publicHeaderBytes, header.publicHeaderBytes)) {
    throw const ArchiveException(
      ArchiveErrorCode.invalidArchive,
      'The archive changed after it was opened.',
    );
  }
  final input = await File(archivePath).open();
  final bodyOutput = await output.open(mode: FileMode.write);
  Uint8List? key;
  try {
    await input.setPosition(header.bodyOffset);
    GCMBlockCipher? cipher;
    if (header.encryption == ArchiveEncryption.aes256Gcm) {
      key = deriveArchiveKey(passphrase!, header.salt!);
      cipher = createGcmCipher(
        forEncryption: false,
        key: key,
        nonce: header.nonce!,
        associatedData: Uint8List.fromList([
          ...header.preambleBytes,
          ...header.publicHeaderBytes,
        ]),
      );
    }
    var remaining = header.bodyLength;
    while (remaining > 0) {
      final chunk = await input.read(remaining < _ioChunkSize ? remaining : _ioChunkSize);
      if (chunk.isEmpty) {
        throw const ArchiveException(
          ArchiveErrorCode.invalidArchive,
          'The archive body is truncated.',
        );
      }
      remaining -= chunk.length;
      final bytes = Uint8List.fromList(chunk);
      if (cipher == null) {
        await bodyOutput.writeFrom(bytes);
      } else {
        final plain = Uint8List(bytes.length + 32);
        final count = cipher.processBytes(bytes, 0, bytes.length, plain, 0);
        if (count > 0) await bodyOutput.writeFrom(plain, 0, count);
      }
    }
    if (cipher != null) {
      try {
        final finalBytes = Uint8List(32);
        final count = cipher.doFinal(finalBytes, 0);
        if (count > 0) await bodyOutput.writeFrom(finalBytes, 0, count);
      } on InvalidCipherTextException catch (error) {
        throw ArchiveException(
          ArchiveErrorCode.authenticationFailed,
          'Archive authentication failed; the passphrase or data is invalid.',
          error,
        );
      }
    }
    await bodyOutput.flush();
  } finally {
    if (key != null) key.fillRange(0, key.length, 0);
    await input.close();
    await bodyOutput.close();
  }
}

Future<_ParsedBody> _readManifest(File body) async {
  final handle = await body.open();
  try {
    final bodyLength = await handle.length();
    if (bodyLength < 8) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArchive,
        'The archive body does not contain a manifest length.',
      );
    }
    final manifestLength = readUint64(await _readExact(handle, 8));
    if (manifestLength == 0 || manifestLength > maxManifestLength ||
        manifestLength > bodyLength - 8) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArchive,
        'The manifest length is invalid.',
      );
    }
    final manifestBytes = await _readExact(handle, manifestLength);
    final manifest = decodeJsonObject(manifestBytes, 'manifest');
    if (manifest['format'] != 'NTA' || manifest['version'] != ntaVersion) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArchive,
        'The manifest identity is invalid.',
      );
    }
    final rawEntries = manifest['entries'];
    if (rawEntries is! List || rawEntries.length > absoluteMaxEntries) {
      throw const ArchiveException(
        ArchiveErrorCode.resourceLimitExceeded,
        'The manifest entry count is invalid or excessive.',
      );
    }
    final entries = <StoredEntry>[];
    final typesByPath = <String, ArchiveEntryType>{};
    final foldedPaths = <String, String>{};
    for (final rawEntry in rawEntries) {
      if (rawEntry is! Map<String, Object?>) {
        throw const ArchiveException(
          ArchiveErrorCode.invalidArchive,
          'A manifest entry is not an object.',
        );
      }
      final stored = _parseStoredEntry(rawEntry);
      _validateArchivePath(stored.entry.path);
      if (typesByPath.containsKey(stored.entry.path)) {
        throw ArchiveException(
          ArchiveErrorCode.duplicateEntry,
          'Duplicate archive path: ${stored.entry.path}',
        );
      }
      final folded = stored.entry.path.toLowerCase();
      final collision = foldedPaths[folded];
      if (collision != null) {
        throw ArchiveException(
          ArchiveErrorCode.duplicateEntry,
          'Case-insensitive path collision: $collision and ${stored.entry.path}',
        );
      }
      if (stored.entry.type == ArchiveEntryType.symbolicLink) {
        _validateLinkTarget(stored.entry.path, stored.entry.linkTarget!);
      }
      entries.add(stored);
      typesByPath[stored.entry.path] = stored.entry.type;
      foldedPaths[folded] = stored.entry.path;
    }
    _validateParentEntries(typesByPath);
    final payloadStart = 8 + manifestLength;
    final payloadLength = bodyLength - payloadStart;
    final files = entries
        .where((entry) => entry.entry.type == ArchiveEntryType.file)
        .toList()
      ..sort((left, right) => left.dataOffset!.compareTo(right.dataOffset!));
    var expectedOffset = 0;
    for (final file in files) {
      if (file.dataOffset != expectedOffset || file.storedSize! < 0) {
        throw const ArchiveException(
          ArchiveErrorCode.invalidArchive,
          'File payload ranges overlap or contain gaps.',
        );
      }
      expectedOffset += file.storedSize!;
    }
    if (expectedOffset != payloadLength) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArchive,
        'The payload length does not match the manifest.',
      );
    }
    return _ParsedBody(entries: entries, payloadStart: payloadStart);
  } finally {
    await handle.close();
  }
}

StoredEntry _parseStoredEntry(Map<String, Object?> json) {
  final path = json['path'];
  final typeName = json['type'];
  final size = json['size'];
  final modified = json['modifiedTimeUtc'];
  if (path is! String || typeName is! String || size is! int || size < 0 || modified is! String) {
    throw const ArchiveException(
      ArchiveErrorCode.invalidArchive,
      'A manifest entry has invalid required fields.',
    );
  }
  final type = switch (typeName) {
    'file' => ArchiveEntryType.file,
    'directory' => ArchiveEntryType.directory,
    'symbolicLink' => ArchiveEntryType.symbolicLink,
    _ => throw ArchiveException(
        ArchiveErrorCode.invalidArchive,
        'Unexpected archive entry type: $typeName',
      ),
  };
  DateTime modifiedTime;
  try {
    modifiedTime = DateTime.parse(modified).toUtc();
  } on FormatException catch (error) {
    throw ArchiveException(
      ArchiveErrorCode.invalidArchive,
      'Invalid modification time for $path.',
      error,
    );
  }
  final posixMode = json['posixMode'];
  if (posixMode != null && (posixMode is! int || posixMode < 0 || posixMode > 0xfff)) {
    throw ArchiveException(
      ArchiveErrorCode.invalidArchive,
      'Invalid POSIX mode for $path.',
    );
  }
  final rawCritical = json['criticalMetadata'];
  if (rawCritical is! List || rawCritical.any((value) => value is! String)) {
    throw ArchiveException(
      ArchiveErrorCode.invalidArchive,
      'Invalid critical metadata list for $path.',
    );
  }
  final rawPlatform = json['platformMetadata'];
  if (rawPlatform is! Map<String, Object?>) {
    throw ArchiveException(
      ArchiveErrorCode.invalidArchive,
      'Invalid platform metadata for $path.',
    );
  }

  int? dataOffset;
  int? storedSize;
  String? sha256;
  String? linkTarget;
  ArchiveCompression? compression;
  if (type == ArchiveEntryType.file) {
    final rawDataOffset = json['dataOffset'];
    final rawStoredSize = json['storedSize'];
    final rawSha256 = json['sha256'];
    dataOffset = rawDataOffset is int ? rawDataOffset : null;
    storedSize = rawStoredSize is int ? rawStoredSize : null;
    sha256 = rawSha256 is String ? rawSha256 : null;
    final compressionName = json['compression'];
    if (dataOffset == null || dataOffset < 0 || storedSize == null ||
        storedSize < 0 || sha256 == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw ArchiveException(
        ArchiveErrorCode.invalidArchive,
        'Invalid file payload metadata for $path.',
      );
    }
    compression = switch (compressionName) {
      'none' => ArchiveCompression.none,
      'zlib' => ArchiveCompression.zlib,
      _ => throw ArchiveException(
          ArchiveErrorCode.unsupportedAlgorithm,
          'Unsupported compression algorithm for $path: $compressionName',
        ),
    };
  } else if (type == ArchiveEntryType.symbolicLink) {
    final rawLinkTarget = json['linkTarget'];
    linkTarget = rawLinkTarget is String ? rawLinkTarget : null;
    if (linkTarget == null || linkTarget.isEmpty) {
      throw ArchiveException(
        ArchiveErrorCode.invalidArchive,
        'A symbolic link target is missing for $path.',
      );
    }
  }

  return StoredEntry(
    entry: ArchiveEntry(
      path: path,
      type: type,
      size: size,
      sha256: sha256,
      modifiedTimeUtc: modifiedTime,
      posixMode: posixMode as int?,
      linkTarget: linkTarget,
      compression: compression,
      platformMetadata: Map.unmodifiable(rawPlatform),
      criticalMetadata: Set.unmodifiable(rawCritical.cast<String>()),
    ),
    dataOffset: dataOffset,
    storedSize: storedSize,
  );
}

void _validateArchivePath(String value) {
  if (value.isEmpty || value.length > 4096 || value.contains('\x00') ||
      value.startsWith('/') || value.startsWith('\\') || value.contains('\\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value) || value.startsWith('//')) {
    throw ArchiveException(
      ArchiveErrorCode.unsafePath,
      'Unsafe archive path: $value',
    );
  }
  final components = value.split('/');
  final reserved = RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$', caseSensitive: false);
  for (final component in components) {
    if (component.isEmpty || component == '.' || component == '..' ||
        component.endsWith(' ') || component.endsWith('.') ||
        _containsWindowsForbiddenCharacters(component) ||
        reserved.hasMatch(component)) {
      throw ArchiveException(
        ArchiveErrorCode.unsafePath,
        'Unsafe archive path component in $value.',
      );
    }
  }
}

void _validateLinkTarget(String linkPath, String target) {
  if (target.isEmpty || target.contains('\x00') || target.startsWith('/') ||
      target.startsWith('\\') || target.contains('\\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(target) || target.startsWith('//')) {
    throw ArchiveException(
      ArchiveErrorCode.unsafePath,
      'Unsafe symbolic link target for $linkPath: $target',
    );
  }
  final stack = <String>[...linkPath.split('/')..removeLast()];
  for (final component in target.split('/')) {
    if (component.isEmpty || component == '.') continue;
    if (component == '..') {
      if (stack.isEmpty) {
        throw ArchiveException(
          ArchiveErrorCode.unsafePath,
          'Symbolic link escapes the archive root: $linkPath -> $target',
        );
      }
      stack.removeLast();
    } else {
      final reserved = RegExp(
        r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
        caseSensitive: false,
      );
      if (component.endsWith(' ') ||
          component.endsWith('.') ||
          _containsWindowsForbiddenCharacters(component) ||
          reserved.hasMatch(component)) {
        throw ArchiveException(
          ArchiveErrorCode.unsafePath,
          'Unsafe symbolic link target for $linkPath: $target',
        );
      }
      stack.add(component);
    }
  }
}

bool _containsWindowsForbiddenCharacters(String component) {
  for (final codePoint in component.codeUnits) {
    if (codePoint < 32 || '<>:"|?*'.codeUnits.contains(codePoint)) return true;
  }
  return false;
}

void _validateParentEntries(Map<String, ArchiveEntryType> typesByPath) {
  for (final entry in typesByPath.entries) {
    final components = entry.key.split('/');
    for (var index = 1; index < components.length; index++) {
      final parent = components.sublist(0, index).join('/');
      if (typesByPath[parent] != ArchiveEntryType.directory) {
        throw ArchiveException(
          ArchiveErrorCode.invalidArchive,
          'Parent directory entry is missing or invalid for ${entry.key}.',
        );
      }
    }
  }
}

void _validatePolicy(ArchiveExtractionPolicy policy) {
  if (policy.maxEntries < 1 || policy.maxEntryUncompressedBytes < 0 ||
      policy.maxTotalUncompressedBytes < 0) {
    throw const ArchiveException(
      ArchiveErrorCode.invalidArgument,
      'Extraction limits must be positive.',
    );
  }
}

void _validateExtractionLimits(
  List<StoredEntry> entries,
  ArchiveExtractionPolicy policy,
) {
  if (entries.length > policy.maxEntries) {
    throw const ArchiveException(
      ArchiveErrorCode.resourceLimitExceeded,
      'The archive exceeds the configured entry limit.',
    );
  }
  var total = 0;
  for (final stored in entries) {
    if (stored.entry.type != ArchiveEntryType.file) continue;
    if (stored.entry.size > policy.maxEntryUncompressedBytes) {
      throw ArchiveException(
        ArchiveErrorCode.resourceLimitExceeded,
        'File exceeds the configured size limit: ${stored.entry.path}',
      );
    }
    total += stored.entry.size;
    if (total > policy.maxTotalUncompressedBytes) {
      throw const ArchiveException(
        ArchiveErrorCode.resourceLimitExceeded,
        'The archive exceeds the configured expanded-size limit.',
      );
    }
  }
}

void _validateCriticalMetadata(List<StoredEntry> entries) {
  for (final stored in entries) {
    for (final name in stored.entry.criticalMetadata) {
      if (!_supportedCriticalMetadata.contains(name)) {
        throw ArchiveException(
          ArchiveErrorCode.unsupportedMetadata,
          'Unsupported critical metadata "$name" on ${stored.entry.path}.',
        );
      }
      if (name == 'posixMode' && Platform.isWindows) {
        throw ArchiveException(
          ArchiveErrorCode.unsupportedMetadata,
          'Critical POSIX permissions cannot be applied on Windows: ${stored.entry.path}',
        );
      }
      if (name == 'posixMode' && stored.entry.posixMode == null) {
        throw ArchiveException(
          ArchiveErrorCode.unsupportedMetadata,
          'Critical POSIX permissions are missing: ${stored.entry.path}',
        );
      }
      if (name == 'symbolicLink' &&
          stored.entry.type != ArchiveEntryType.symbolicLink) {
        throw ArchiveException(
          ArchiveErrorCode.unsupportedMetadata,
          'Critical symbolic-link metadata is invalid: ${stored.entry.path}',
        );
      }
      if (name == 'modifiedTimeUtc' &&
          stored.entry.type == ArchiveEntryType.symbolicLink) {
        throw ArchiveException(
          ArchiveErrorCode.unsupportedMetadata,
          'Critical symbolic-link timestamps are not supported.',
        );
      }
    }
  }
}

Future<void> _extractFile({
  required RandomAccessFile bodyHandle,
  required int payloadStart,
  required StoredEntry stored,
  required String stagingPath,
  required ArchiveExtractionPolicy policy,
}) async {
  final entry = stored.entry;
  await _ensureSafeParentChain(stagingPath, entry.path);
  final target = File(_targetPath(stagingPath, entry.path));
  final output = target.openWrite();
  final digest = SHA256Digest();
  final extractionSink = _ExtractionSink(
    output,
    digest,
    entry.size,
    policy.maxEntryUncompressedBytes,
  );
  final Sink<List<int>> dataSink = entry.compression == ArchiveCompression.zlib
      ? ZLibDecoder().startChunkedConversion(extractionSink)
      : extractionSink;
  try {
    await bodyHandle.setPosition(payloadStart + stored.dataOffset!);
    var remaining = stored.storedSize!;
    while (remaining > 0) {
      final chunk = await bodyHandle.read(remaining < _ioChunkSize ? remaining : _ioChunkSize);
      if (chunk.isEmpty) {
        throw ArchiveException(
          ArchiveErrorCode.invalidArchive,
          'Payload is truncated for ${entry.path}.',
        );
      }
      remaining -= chunk.length;
      dataSink.add(chunk);
    }
    dataSink.close();
    await output.close();
  } on Object {
    await output.close();
    rethrow;
  }
  if (extractionSink.bytesWritten != entry.size) {
    throw ArchiveException(
      ArchiveErrorCode.integrityMismatch,
      'Expanded size mismatch for ${entry.path}.',
    );
  }
  final hash = Uint8List(digest.digestSize);
  digest.doFinal(hash, 0);
  if (hexEncode(hash) != entry.sha256) {
    throw ArchiveException(
      ArchiveErrorCode.integrityMismatch,
      'SHA-256 mismatch for ${entry.path}.',
    );
  }
}

Future<void> _applyMetadata(
  ArchiveEntry entry,
  String targetPath,
  ArchiveExtractionPolicy policy,
  List<String> warnings,
) async {
  if (entry.type == ArchiveEntryType.symbolicLink) return;
  try {
    if (Platform.isWindows && entry.type == ArchiveEntryType.directory) {
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'& { param($targetPath, $timestamp) [System.IO.Directory]::SetLastWriteTimeUtc($targetPath, [DateTime]::Parse($timestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)) }',
          targetPath,
          entry.modifiedTimeUtc.toIso8601String(),
        ],
      );
      if (result.exitCode != 0) {
        throw ProcessException(
          'powershell.exe',
          const [],
          '${result.stderr}',
          result.exitCode,
        );
      }
    } else {
      // File.setLastModified is a path operation and also works for directories
      // on POSIX hosts. Windows requires the directory-specific call above.
      await File(targetPath).setLastModified(entry.modifiedTimeUtc);
    }
  } on Object catch (error) {
    _metadataFailure(entry, 'modifiedTimeUtc', error, policy, warnings);
  }
  if (entry.posixMode != null) {
    if (Platform.isWindows) {
      _metadataFailure(
        entry,
        'posixMode',
        'POSIX permissions are unavailable on Windows.',
        policy,
        warnings,
      );
    } else {
      try {
        final result = await Process.run(
          'chmod',
          [entry.posixMode!.toRadixString(8).padLeft(4, '0'), targetPath],
        );
        if (result.exitCode != 0) {
          throw ProcessException('chmod', const [], '${result.stderr}', result.exitCode);
        }
      } on Object catch (error) {
        _metadataFailure(entry, 'posixMode', error, policy, warnings);
      }
    }
  }
}

void _metadataFailure(
  ArchiveEntry entry,
  String metadata,
  Object error,
  ArchiveExtractionPolicy policy,
  List<String> warnings,
) {
  if (entry.criticalMetadata.contains(metadata) ||
      policy.failOnNonCriticalMetadataError) {
    throw ArchiveException(
      ArchiveErrorCode.unsupportedMetadata,
      'Could not apply $metadata to ${entry.path}.',
      error,
    );
  }
  warnings.add('Did not apply $metadata to ${entry.path}: $error');
}

Future<void> _ensureSafeParentChain(String root, String archivePath) async {
  var current = root;
  final components = archivePath.split('/');
  for (final component in components.take(components.length - 1)) {
    current = p.join(current, component);
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw ArchiveException(
        ArchiveErrorCode.unsafePath,
        'Extraction parent is not a real directory: $archivePath',
      );
    }
  }
}

String _targetPath(String root, String archivePath) =>
    p.joinAll([root, ...archivePath.split('/')]);

int _pathDepth(String archivePath) => archivePath.split('/').length;

String _entryTypeName(ArchiveEntryType type) => switch (type) {
      ArchiveEntryType.file => 'file',
      ArchiveEntryType.directory => 'directory',
      ArchiveEntryType.symbolicLink => 'symbolicLink',
    };

Uint8List _decodeBase64Field(Object? value, String field) {
  if (value is! String) {
    throw ArchiveException(
      ArchiveErrorCode.invalidArchive,
      'The $field is missing.',
    );
  }
  try {
    return Uint8List.fromList(base64Decode(value));
  } on FormatException catch (error) {
    throw ArchiveException(
      ArchiveErrorCode.invalidArchive,
      'The $field is invalid.',
      error,
    );
  }
}

Future<Uint8List> _readExact(RandomAccessFile file, int length) async {
  final output = BytesBuilder(copy: false);
  var remaining = length;
  while (remaining > 0) {
    final chunk = await file.read(remaining);
    if (chunk.isEmpty) {
      throw const ArchiveException(
        ArchiveErrorCode.invalidArchive,
        'The archive is truncated.',
      );
    }
    output.add(chunk);
    remaining -= chunk.length;
  }
  return output.takeBytes();
}

String _randomSuffix() => base64Url
    .encode(secureRandomBytes(12))
    .replaceAll('=', '');

class _SourceSpec {
  const _SourceSpec(this.sourcePath, this.archivePath, this.isDirectory);

  final String sourcePath;
  final String archivePath;
  final bool isDirectory;
}

class _PendingEntry {
  const _PendingEntry({
    required this.sourcePath,
    required this.archivePath,
    required this.type,
    required this.size,
    required this.modifiedTimeUtc,
    required this.posixMode,
    required this.linkTarget,
    required this.criticalMetadata,
  });

  final String sourcePath;
  final String archivePath;
  final ArchiveEntryType type;
  final int size;
  final DateTime modifiedTimeUtc;
  final int? posixMode;
  final String? linkTarget;
  final Set<String> criticalMetadata;

  ArchiveEntry toArchiveEntry({
    int? size,
    String? sha256,
    ArchiveCompression? compression,
  }) =>
      ArchiveEntry(
        path: archivePath,
        type: type,
        size: size ?? this.size,
        sha256: sha256,
        modifiedTimeUtc: modifiedTimeUtc,
        posixMode: posixMode,
        linkTarget: linkTarget,
        compression: compression,
        platformMetadata: const {},
        criticalMetadata: Set.unmodifiable(criticalMetadata),
      );
}

class _ContainerHeader {
  const _ContainerHeader({
    required this.preambleBytes,
    required this.publicHeaderBytes,
    required this.bodyOffset,
    required this.bodyLength,
    required this.encryption,
    required this.salt,
    required this.nonce,
  });

  final Uint8List preambleBytes;
  final Uint8List publicHeaderBytes;
  final int bodyOffset;
  final int bodyLength;
  final ArchiveEncryption encryption;
  final Uint8List? salt;
  final Uint8List? nonce;
}

class _ParsedBody {
  const _ParsedBody({required this.entries, required this.payloadStart});

  final List<StoredEntry> entries;
  final int payloadStart;
}

class _CountingSink implements Sink<List<int>> {
  _CountingSink(this.output);

  final IOSink output;
  int bytesWritten = 0;

  @override
  void add(List<int> data) {
    bytesWritten += data.length;
    output.add(data);
  }

  @override
  void close() {}
}

class _ExtractionSink implements Sink<List<int>> {
  _ExtractionSink(this.output, this.digest, this.expectedSize, this.limit);

  final IOSink output;
  final SHA256Digest digest;
  final int expectedSize;
  final int limit;
  int bytesWritten = 0;

  @override
  void add(List<int> data) {
    bytesWritten += data.length;
    if (bytesWritten > expectedSize || bytesWritten > limit) {
      throw const ArchiveException(
        ArchiveErrorCode.resourceLimitExceeded,
        'Expanded file data exceeds its declared or configured limit.',
      );
    }
    final bytes = Uint8List.fromList(data);
    digest.update(bytes, 0, bytes.length);
    output.add(bytes);
  }

  @override
  void close() {}
}
