// E: portable archives produced and consumed through the public Dart FFI.
// No platform-native opaque names in exchange: those are covered in B-D.
import 'dart:io';
import 'dart:typed_data';

import 'package:remvibe_archive_dart/remvibe_archive_dart.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';
ArchiveNativePath native(String path) => ArchiveNativePath.fromString(path);
ArchivePath relative(String path) => ArchivePath.fromString(path);

Directory emptyDirectory(String path) {
  final dir = Directory(path);
  require(dir.isAbsolute && dir.existsSync() && dir.listSync().isEmpty,
      'Expected existing empty absolute directory: $path');
  return dir;
}

bool sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var i = 0; i < first.length; i++) {
    if (first[i] != second[i]) return false;
  }
  return true;
}

// Deterministic bytes, with the same 32-bit arithmetic on Windows/Linux.
// Incompressible enough to cross many 4096-byte split parts for each codec.
Uint8List fixturePayload() {
  var state = 1007;
  return Uint8List.fromList(List<int>.generate(48 * 1024, (_) {
    state = (state ^ (state << 13)) & 0xffffffff;
    state = (state ^ (state >> 17)) & 0xffffffff;
    state = (state ^ (state << 5)) & 0xffffffff;
    return state & 255;
  }));
}

const codecs = <String, ArchiveCompression>{
  'none.bin': ArchiveCompression.none,
  'zlib.bin': ArchiveCompression.zlib,
  'zstd.bin': ArchiveCompression.zstd,
};
const nestedText = 'RemVibe portable RVA V3\n';
const portableTimeMillis = 1700000000000;

Future<void> produce(ArchiveService service, String destination, String mode) async {
  final dir = emptyDirectory(destination);
  final origin = Platform.operatingSystem;
  final source = Directory.systemTemp.createTempSync('remvibe-archive-exchange-source-');
  try {
    final payload = fixturePayload();
    final payloadFile = File(join(source.path, 'payload.bin'))..writeAsBytesSync(payload);
    payloadFile.setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(portableTimeMillis, isUtc: true));
    final marker = File(join(source.path, 'origin.txt'))..writeAsStringSync(origin);
    final empty = File(join(source.path, 'empty.bin'))..createSync();
    final tree = Directory(join(source.path, 'tree'))..createSync();
    Directory(join(tree.path, 'empty')).createSync();
    File(join(tree.path, 'İstanbul.txt')).writeAsStringSync(nestedText);
    final expectedBytes = payload.length * 3 + origin.length + nestedText.length;

    Future<void> make(String name, bool split) async {
      final path = join(dir.path, name);
      final options = ArchiveWriterOptions(
        layout: split ? ArchiveLayout.split(BigInt.from(4096)) : const ArchiveLayout.single(),
        manifestCompression: split ? ArchiveCompression.zlib : ArchiveCompression.zstd,
      );
      final writer = await service.createWriter(native(path), options: options).result;
      try {
        for (final entry in codecs.entries) {
          await writer.addFile(source: native(payloadFile.path), path: relative(entry.key),
              compression: entry.value).result;
        }
        await writer.addFile(source: native(marker.path), path: relative('origin.txt')).result;
        await writer.addFile(source: native(empty.path), path: relative('empty.bin')).result;
        await writer.addDirectory(source: native(tree.path), path: relative('tree')).result;
        final result = await writer.finish().result;
        require(result.entryCount == BigInt.from(8) && result.sourceBytes == BigInt.from(expectedBytes),
            'Unexpected portable archive counters');
        if (split) {
          final parts = Directory(path).listSync().whereType<File>().toList();
          require(parts.length > 1 && parts.every((p) => p.lengthSync() <= 4096),
              'Invalid split physical part cap');
          require(result.partCount == BigInt.from(parts.length) &&
              result.physicalBytes == BigInt.from(parts.fold<int>(0, (sum, f) => sum + f.lengthSync())) &&
              result.physicalBytes == result.archiveBytes + result.partCount * BigInt.from(72),
              'Invalid split accounting');
        } else {
          require(result.partCount == BigInt.one &&
              result.archiveBytes == result.physicalBytes &&
              result.physicalBytes == BigInt.from(File(path).lengthSync()), 'Invalid Single accounting');
        }
        print('DART_EXCHANGE_PRODUCED layout=${split ? "split" : "single"} origin=$origin '
            'entries=${result.entryCount} bytes=${result.sourceBytes} parts=${result.partCount} '
            'logical=${result.archiveBytes} physical=${result.physicalBytes} mode=$mode');
      } finally {
        await writer.close();
      }
    }

    await make('single.rva', false);
    await make('split.rva.parts', true);
    print('ARCHIVE_FFI_E_EXCHANGE_PRODUCE_COMPLETED origin=$origin mode=$mode');
  } finally {
    source.deleteSync(recursive: true);
  }
}

Future<void> consume(ArchiveService service, String input, String origin,
    String destination, String mode) async {
  final target = Platform.operatingSystem;
  require((origin == 'windows' || origin == 'linux') && origin != target,
      'Expected actual other-platform archive origin (windows/linux)');
  final archives = Directory(input);
  require(archives.isAbsolute && archives.existsSync(), 'Absolute exchange directory required');
  final output = emptyDirectory(destination);
  final payload = fixturePayload();
  final expectedBytes = payload.length * 3 + origin.length + nestedText.length;

  Future<void> read(String name, bool split) async {
    final reader = await service.openReader(native(join(input, name)),
        source: split ? const ArchiveSource.split() : const ArchiveSource.single()).result;
    try {
      final manifest = await reader.manifest().result;
      require(reader.entryCount == BigInt.from(8) && manifest.entries.length == 8 &&
          manifest.totalBytes == BigInt.from(expectedBytes), 'Unexpected manifest counters');
      ArchiveEntry entry(String name) => manifest.entries.singleWhere((e) =>
          e.path.components.length == 1 &&
          e.path.components.single.encoding == ArchivePathEncoding.utf8 &&
          e.path.components.single.value == name);

      Future<void> streamBytes(ArchiveEntry selected, List<int> expected) async {
        final op = reader.readEntry(selected.index);
        var offset = 0;
        try {
          await for (final chunk in op.stream) {
            require(chunk.isNotEmpty && chunk.length <= 256 * 1024 &&
                offset + chunk.length <= expected.length, 'Invalid portable stream chunk');
            for (var i = 0; i < chunk.length; i++) {
              require(chunk[i] == expected[offset + i], 'Portable stream content mismatch');
            }
            offset += chunk.length;
          }
          final result = await op.result;
          require(offset == expected.length && result.outputBytes == BigInt.from(offset) &&
              result.entryCount == BigInt.one && !op.isRunning, 'Portable terminal mismatch');
        } finally {
          if (op.isRunning) {
            await op.cancel();
            try { await op.result; } on ArchiveException catch (_) {}
          }
        }
      }

      for (final codec in codecs.entries) {
        final selected = entry(codec.key);
        require(selected.payload?.compression == codec.value, 'Wrong portable codec');
        require(selected.metadata.modifiedAt?.utcDateTime?.millisecondsSinceEpoch == portableTimeMillis,
            'Portable manifest timestamp mismatch');
        await streamBytes(selected, payload);
      }
      await streamBytes(entry('origin.txt'), origin.codeUnits);
      await streamBytes(entry('empty.bin'), []);
      final verified = await reader.verify().result;
      require(verified.entryCount == BigInt.from(8) &&
          verified.outputBytes == BigInt.from(expectedBytes), 'Portable verify result');
      final extracted = join(output.path, split ? 'split-out' : 'single-out');
      final result = await reader.extractTo(native(extracted)).result;
      require(result.entryCount == verified.entryCount && result.outputBytes == verified.outputBytes &&
          result.metadata.length == 8 && result.metadata.every((m) => m.result.isSuccess),
          'Portable extraction counters/metadata');
      for (final name in codecs.keys) {
        final file = File(join(extracted, name));
        require(sameBytes(file.readAsBytesSync(), payload), 'Portable extracted bytes mismatch');
        require(file.lastModifiedSync().millisecondsSinceEpoch == portableTimeMillis,
            'Portable extracted timestamp mismatch');
      }
      require(File(join(extracted, 'origin.txt')).readAsStringSync() == origin, 'Wrong producer OS');
      require(File(join(extracted, 'empty.bin')).lengthSync() == 0, 'Nonempty empty file');
      final tree = join(extracted, 'tree');
      require(File(join(tree, 'İstanbul.txt')).readAsStringSync() == nestedText, 'Unicode file mismatch');
      require(Directory(join(tree, 'empty')).listSync().isEmpty, 'Nonempty empty directory');
      print('DART_EXCHANGE_CONSUMED layout=${split ? "split" : "single"} origin=$origin target=$target '
          'entries=${result.entryCount} bytes=${result.outputBytes} mode=$mode');
    } finally {
      await reader.close();
    }
  }

  await read('single.rva', false);
  await read('split.rva.parts', true);
  print('ARCHIVE_FFI_E_EXCHANGE_CONSUME_COMPLETED origin=$origin target=$target mode=$mode');
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) throw ArgumentError('Expected produce or consume');
  if (args.first == 'produce' && (args.length == 2 || args.length == 3)) {
    final service = args.length == 2 ? ArchiveService.instance : ArchiveService.withLibrary(args[2]);
    await produce(service, args[1], args.length == 2 ? 'nativeAssets' : 'explicit');
  } else if (args.first == 'consume' && (args.length == 4 || args.length == 5)) {
    final service = args.length == 4 ? ArchiveService.instance : ArchiveService.withLibrary(args[4]);
    await consume(service, args[1], args[2], args[3], args.length == 4 ? 'nativeAssets' : 'explicit');
  } else {
    throw ArgumentError('Usage: produce <empty-dir> [library] | consume <archive-dir> '
        '<origin-os> <empty-output-dir> [library]');
  }
}
