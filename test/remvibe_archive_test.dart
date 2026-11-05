import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:remvibe_archive/remvibe_archive.dart';
import 'package:remvibe_archive/src/archive_crypto.dart';
import 'package:remvibe_archive/src/archive_format.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp('nta-test-');
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  group('round trip', () {
    test('preserves nested, empty, binary, and metadata content', () async {
      final source = Directory(p.join(temporaryDirectory.path, 'Release'));
      final nested = Directory(p.join(source.path, 'data', 'empty'));
      await nested.create(recursive: true);
      final empty = File(p.join(source.path, 'empty.txt'));
      await empty.writeAsBytes(const []);
      final binary = File(p.join(source.path, 'program.bin'));
      final binaryBytes = Uint8List.fromList(
        List<int>.generate(8192, (index) => index % 256),
      );
      await binary.writeAsBytes(binaryBytes);
      final modified = DateTime.utc(2025, 6, 1, 12, 30);
      await binary.setLastModified(modified);

      final archiveFile = p.join(temporaryDirectory.path, 'update.nta');
      final creator = RemvibeArchive.create(output: archiveFile);
      await creator.addDirectory(source.path);
      await creator.save();

      final archive = await RemvibeArchive.open(archiveFile);
      expect(archive.encryption, ArchiveEncryption.none);
      expect(archive.entries.map((entry) => entry.path), containsAll([
        'Release',
        'Release/data',
        'Release/data/empty',
        'Release/empty.txt',
        'Release/program.bin',
      ]));

      final destination = p.join(temporaryDirectory.path, 'extracted');
      final result = await archive.extract(destination: destination);
      expect(result.warnings, isEmpty);
      expect(
        await File(p.join(destination, 'Release', 'program.bin')).readAsBytes(),
        binaryBytes,
      );
      expect(
        await File(p.join(destination, 'Release', 'empty.txt')).length(),
        0,
      );
      expect(
        await Directory(p.join(destination, 'Release', 'data', 'empty')).exists(),
        isTrue,
      );
      final extractedModified =
          await File(p.join(destination, 'Release', 'program.bin')).lastModified();
      expect(extractedModified.toUtc(), modified);
    });

    test('creates and opens authenticated encrypted archives', () async {
      final source = File(p.join(temporaryDirectory.path, 'secret.bin'));
      await source.writeAsBytes(
        List<int>.generate(1024 * 1024 + 37, (index) => index % 251),
      );
      final archiveFile = p.join(temporaryDirectory.path, 'private.nta');
      final creator = RemvibeArchive.create(
        output: archiveFile,
        encryption: ArchiveEncryption.aes256Gcm,
        compression: ArchiveCompression.none,
        passphrase: 'correct horse battery staple',
      );
      await creator.addFile(source.path);
      await creator.save();

      await expectLater(
        RemvibeArchive.open(archiveFile, passphrase: 'wrong'),
        throwsA(_archiveError(ArchiveErrorCode.authenticationFailed)),
      );
      final archive = await RemvibeArchive.open(
        archiveFile,
        passphrase: 'correct horse battery staple',
      );
      final destination = p.join(temporaryDirectory.path, 'private-output');
      await archive.extract(destination: destination);
      expect(
        await File(p.join(destination, 'secret.bin')).readAsBytes(),
        await source.readAsBytes(),
      );
    });

    test(
      'preserves a safe symbolic link',
      () async {
        final source = Directory(p.join(temporaryDirectory.path, 'tree'));
        await source.create();
        await File(p.join(source.path, 'target.txt')).writeAsString('target');
        await Link(p.join(source.path, 'link.txt')).create('target.txt');
        final archiveFile = p.join(temporaryDirectory.path, 'links.nta');
        final creator = RemvibeArchive.create(output: archiveFile);
        await creator.addDirectory(source.path);
        await creator.save();
        final archive = await RemvibeArchive.open(archiveFile);
        final destination = p.join(temporaryDirectory.path, 'links-output');
        await archive.extract(destination: destination);
        expect(
          await Link(p.join(destination, 'tree', 'link.txt')).target(),
          'target.txt',
        );
      },
      skip: Platform.isWindows
          ? 'Windows symbolic-link creation depends on host privileges.'
          : false,
    );
  });

  group('container validation', () {
    test('rejects corrupt and truncated headers', () async {
      final corrupt = File(p.join(temporaryDirectory.path, 'corrupt.nta'));
      await corrupt.writeAsBytes(utf8.encode('not an archive'));
      await expectLater(
        RemvibeArchive.open(corrupt.path),
        throwsA(_archiveError(ArchiveErrorCode.invalidArchive)),
      );

      final valid = File(p.join(temporaryDirectory.path, 'valid.nta'));
      await _writeRawArchive(valid, [_directoryEntry('folder')]);
      final bytes = await valid.readAsBytes();
      await valid.writeAsBytes(bytes.sublist(0, bytes.length - 1));
      await expectLater(
        RemvibeArchive.open(valid.path),
        throwsA(_archiveError(ArchiveErrorCode.invalidArchive)),
      );
    });

    for (final unsafe in [
      '../escape',
      '/absolute',
      r'C:\drive',
      r'\\server\share',
      'bad?.txt',
    ]) {
      test('rejects unsafe path $unsafe', () async {
        final file = File(p.join(temporaryDirectory.path, 'unsafe.nta'));
        await _writeRawArchive(file, [_directoryEntry(unsafe)]);
        await expectLater(
          RemvibeArchive.open(file.path),
          throwsA(_archiveError(ArchiveErrorCode.unsafePath)),
        );
      });
    }

    test('rejects duplicate and case-insensitive collisions', () async {
      final duplicate = File(p.join(temporaryDirectory.path, 'duplicate.nta'));
      await _writeRawArchive(
        duplicate,
        [_directoryEntry('same'), _directoryEntry('same')],
      );
      await expectLater(
        RemvibeArchive.open(duplicate.path),
        throwsA(_archiveError(ArchiveErrorCode.duplicateEntry)),
      );

      final collision = File(p.join(temporaryDirectory.path, 'collision.nta'));
      await _writeRawArchive(
        collision,
        [_directoryEntry('Readme'), _directoryEntry('README')],
      );
      await expectLater(
        RemvibeArchive.open(collision.path),
        throwsA(_archiveError(ArchiveErrorCode.duplicateEntry)),
      );
    });

    test('rejects unexpected entry types and unsafe symlinks', () async {
      final unexpected = File(p.join(temporaryDirectory.path, 'type.nta'));
      await _writeRawArchive(unexpected, [
        {..._directoryEntry('device'), 'type': 'device'},
      ]);
      await expectLater(
        RemvibeArchive.open(unexpected.path),
        throwsA(_archiveError(ArchiveErrorCode.invalidArchive)),
      );

      final link = File(p.join(temporaryDirectory.path, 'link.nta'));
      await _writeRawArchive(link, [_linkEntry('link', '../outside')]);
      await expectLater(
        RemvibeArchive.open(link.path),
        throwsA(_archiveError(ArchiveErrorCode.unsafePath)),
      );
    });

    test('detects encrypted archive tampering', () async {
      final source = File(p.join(temporaryDirectory.path, 'source.txt'));
      await source.writeAsString('authenticated');
      final file = File(p.join(temporaryDirectory.path, 'encrypted.nta'));
      final creator = RemvibeArchive.create(
        output: file.path,
        encryption: ArchiveEncryption.aes256Gcm,
        passphrase: 'passphrase',
      );
      await creator.addFile(source.path);
      await creator.save();
      final bytes = await file.readAsBytes();
      bytes[bytes.length - 1] ^= 1;
      await file.writeAsBytes(bytes);
      await expectLater(
        RemvibeArchive.open(file.path, passphrase: 'passphrase'),
        throwsA(_archiveError(ArchiveErrorCode.authenticationFailed)),
      );
    });
  });

  group('safe extraction', () {
    test('verifies SHA-256 and removes partial staging output', () async {
      final file = File(p.join(temporaryDirectory.path, 'bad-sha.nta'));
      final first = utf8.encode('first');
      final second = utf8.encode('second');
      await _writeRawArchive(
        file,
        [
          _fileEntry('first.txt', first, dataOffset: 0),
          _fileEntry(
            'second.txt',
            second,
            dataOffset: first.length,
            sha256: List.filled(64, '0').join(),
          ),
        ],
        payload: [...first, ...second],
      );
      final archive = await RemvibeArchive.open(file.path);
      final destination = p.join(temporaryDirectory.path, 'bad-output');
      await expectLater(
        archive.extract(destination: destination),
        throwsA(_archiveError(ArchiveErrorCode.integrityMismatch)),
      );
      expect(await Directory(destination).exists(), isFalse);
      expect(
        await temporaryDirectory
            .list()
            .where((entry) => p.basename(entry.path).contains('.bad-output.nta-staging-'))
            .isEmpty,
        isTrue,
      );
    });

    test('enforces entry and expanded-size limits before writes', () async {
      final data = utf8.encode('small');
      final file = File(p.join(temporaryDirectory.path, 'limits.nta'));
      await _writeRawArchive(
        file,
        [_fileEntry('large.txt', data, declaredSize: 100)],
        payload: data,
      );
      final archive = await RemvibeArchive.open(file.path);
      final destination = p.join(temporaryDirectory.path, 'limit-output');
      await expectLater(
        archive.extract(
          destination: destination,
          policy: const ArchiveExtractionPolicy(
            maxEntryUncompressedBytes: 10,
            maxTotalUncompressedBytes: 10,
          ),
        ),
        throwsA(_archiveError(ArchiveErrorCode.resourceLimitExceeded)),
      );
      expect(await Directory(destination).exists(), isFalse);

      final countFile = File(p.join(temporaryDirectory.path, 'count.nta'));
      await _writeRawArchive(
        countFile,
        [_directoryEntry('one'), _directoryEntry('two')],
      );
      final countArchive = await RemvibeArchive.open(countFile.path);
      await expectLater(
        countArchive.extract(
          destination: p.join(temporaryDirectory.path, 'count-output'),
          policy: const ArchiveExtractionPolicy(maxEntries: 1),
        ),
        throwsA(_archiveError(ArchiveErrorCode.resourceLimitExceeded)),
      );
    });

    test('stops compressed content that expands beyond its declaration', () async {
      final expanded = List<int>.filled(1024 * 1024, 65);
      final compressed = ZLibCodec().encode(expanded);
      final file = File(p.join(temporaryDirectory.path, 'bomb.nta'));
      await _writeRawArchive(
        file,
        [
          {
            ..._fileEntry('bomb.bin', expanded, declaredSize: 1),
            'compression': 'zlib',
            'storedSize': compressed.length,
          },
        ],
        payload: compressed,
      );
      final archive = await RemvibeArchive.open(file.path);
      final destination = p.join(temporaryDirectory.path, 'bomb-output');
      await expectLater(
        archive.extract(destination: destination),
        throwsA(_archiveError(ArchiveErrorCode.resourceLimitExceeded)),
      );
      expect(await Directory(destination).exists(), isFalse);
    });

    test('rejects unsupported critical metadata', () async {
      final file = File(p.join(temporaryDirectory.path, 'metadata.nta'));
      await _writeRawArchive(file, [
        {
          ..._directoryEntry('folder'),
          'criticalMetadata': ['future.acl'],
        },
      ]);
      final archive = await RemvibeArchive.open(file.path);
      await expectLater(
        archive.extract(destination: p.join(temporaryDirectory.path, 'metadata-output')),
        throwsA(_archiveError(ArchiveErrorCode.unsupportedMetadata)),
      );
    });

    test(
      'rejects critical POSIX metadata on Windows',
      () async {
        final data = utf8.encode('executable');
        final file = File(p.join(temporaryDirectory.path, 'posix.nta'));
        await _writeRawArchive(
          file,
          [
            {
              ..._fileEntry('program', data),
              'posixMode': 0x1ed,
              'criticalMetadata': ['posixMode'],
            },
          ],
          payload: data,
        );
        final archive = await RemvibeArchive.open(file.path);
        await expectLater(
          archive.extract(destination: p.join(temporaryDirectory.path, 'posix-output')),
          throwsA(_archiveError(ArchiveErrorCode.unsupportedMetadata)),
        );
      },
      skip: Platform.isWindows ? false : 'Windows-specific policy behavior.',
    );

    test(
      'preserves executable POSIX permission bits',
      () async {
        final source = File(p.join(temporaryDirectory.path, 'program'));
        await source.writeAsString('binary');
        final chmod = await Process.run('chmod', ['0755', source.path]);
        expect(chmod.exitCode, 0);
        final archiveFile = p.join(temporaryDirectory.path, 'mode.nta');
        final creator = RemvibeArchive.create(output: archiveFile);
        await creator.addFile(source.path);
        await creator.save();
        final archive = await RemvibeArchive.open(archiveFile);
        final destination = p.join(temporaryDirectory.path, 'mode-output');
        await archive.extract(destination: destination);
        final mode = (await File(p.join(destination, 'program')).stat()).mode;
        expect(mode & 0x1ff, 0x1ed);
      },
      skip: Platform.isWindows ? 'POSIX-only permission behavior.' : false,
    );

    test('refuses an existing destination', () async {
      final file = File(p.join(temporaryDirectory.path, 'simple.nta'));
      await _writeRawArchive(file, [_directoryEntry('folder')]);
      final archive = await RemvibeArchive.open(file.path);
      final destination = Directory(p.join(temporaryDirectory.path, 'existing'));
      await destination.create();
      await expectLater(
        archive.extract(destination: destination.path),
        throwsA(_archiveError(ArchiveErrorCode.destinationExists)),
      );
    });

    test('reports an invalid destination parent as an I/O failure', () async {
      final file = File(p.join(temporaryDirectory.path, 'io.nta'));
      await _writeRawArchive(file, [_directoryEntry('folder')]);
      final archive = await RemvibeArchive.open(file.path);
      final parentFile = File(p.join(temporaryDirectory.path, 'not-a-directory'));
      await parentFile.writeAsString('x');
      await expectLater(
        archive.extract(destination: p.join(parentFile.path, 'child')),
        throwsA(_archiveError(ArchiveErrorCode.ioFailure)),
      );
    });
  });
}

Matcher _archiveError(ArchiveErrorCode code) =>
    isA<ArchiveException>().having((error) => error.code, 'code', code);

Map<String, Object?> _baseEntry(String path, String type) => {
      'path': path,
      'type': type,
      'size': 0,
      'sha256': null,
      'modifiedTimeUtc': DateTime.utc(2025).toIso8601String(),
      'posixMode': null,
      'linkTarget': null,
      'compression': null,
      'dataOffset': null,
      'storedSize': null,
      'platformMetadata': <String, Object?>{},
      'criticalMetadata': <String>[],
    };

Map<String, Object?> _directoryEntry(String path) =>
    _baseEntry(path, 'directory');

Map<String, Object?> _linkEntry(String path, String target) => {
      ..._baseEntry(path, 'symbolicLink'),
      'linkTarget': target,
      'criticalMetadata': ['symbolicLink'],
    };

Map<String, Object?> _fileEntry(
  String path,
  List<int> bytes, {
  int dataOffset = 0,
  int? declaredSize,
  String? sha256,
}) =>
    {
      ..._baseEntry(path, 'file'),
      'size': declaredSize ?? bytes.length,
      'sha256': sha256 ?? sha256Hex(bytes),
      'compression': 'none',
      'dataOffset': dataOffset,
      'storedSize': bytes.length,
    };

Future<void> _writeRawArchive(
  File file,
  List<Map<String, Object?>> entries, {
  List<int> payload = const [],
}) async {
  final manifest = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': 'NTA',
        'version': ntaVersion,
        'sourcePlatform': Platform.operatingSystem,
        'entries': entries,
        'extensions': <String, Object?>{},
      }),
    ),
  );
  final header = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': 'NTA',
        'version': ntaVersion,
        'encryption': {'algorithm': 'none'},
      }),
    ),
  );
  final body = <int>[...uint64Bytes(manifest.length), ...manifest, ...payload];
  final preamble = buildPreamble(
    encrypted: false,
    publicHeaderLength: header.length,
    bodyLength: body.length,
  );
  await file.writeAsBytes([...preamble, ...header, ...body], flush: true);
}
