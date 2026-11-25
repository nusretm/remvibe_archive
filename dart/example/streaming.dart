import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:remvibe_archive_dart/remvibe_archive_dart.dart';

const chunkLimit = 256 * 1024;
void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}
String join(String parent, String child) => '$parent${Platform.pathSeparator}$child';
ArchiveNativePath native(String value) => ArchiveNativePath.fromString(value);
bool equalBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
ArchiveEntry named(ArchiveManifest manifest, String name) =>
    manifest.entries.singleWhere((entry) => entry.path.components.length == 1 &&
        entry.path.components.single.encoding == ArchivePathEncoding.utf8 &&
        entry.path.components.single.value == name);

Future<ArchiveException> expectArchive(ArchiveErrorKind kind, Future<void> Function() action) async {
  try {
    await action();
    throw StateError('Expected ${kind.name}');
  } on ArchiveException catch (error) {
    require(error.kind == kind, 'Expected ${kind.name}, got $error');
    return error;
  }
}
void checkChunk(Uint8List chunk) {
  require(chunk.isNotEmpty && chunk.length <= chunkLimit, 'Invalid binary chunk size: ${chunk.length}');
}

/// Only the small fixture entries are collected; the large fixture is checked
/// incrementally against the source file, never materialized in Dart.
Future<void> readSmall(ArchiveReader reader, ArchiveEntry entry, List<int> expected) async {
  final op = reader.readEntry(entry.index);
  final bytes = BytesBuilder(copy: false);
  final events = <ArchiveProgress>[];
  final progressDone = Completer<void>();
  final sub = op.progress.listen(events.add, onDone: progressDone.complete);
  try {
    await for (final chunk in op.stream) {
      checkChunk(chunk);
      bytes.add(chunk);
    }
    final result = await op.result;
    await progressDone.future;
    require(equalBytes(bytes.takeBytes(), expected), 'Selected entry bytes mismatch');
    require(result.entryCount == BigInt.one && result.outputBytes == BigInt.from(expected.length),
        'Selected entry terminal counters');
    require(!op.isRunning && events.isNotEmpty && events.last.phase == ArchiveProgressPhase.completed,
        'Missing completed progress');
    var previous = BigInt.zero;
    for (final e in events) {
      require(e.isReader && e.totalEntries == BigInt.one && e.totalBytes == BigInt.from(expected.length),
          'Selected entry progress totals');
      require(e.processedBytes >= previous && e.processedBytes <= BigInt.from(expected.length),
          'Selected entry byte counters');
      previous = e.processedBytes;
    }
    require(previous == result.outputBytes && events.last.entriesCompleted == BigInt.one, 'Final progress mismatch');
    if (expected.isNotEmpty) {
      require(events.any((e) => e.phase == ArchiveProgressPhase.reading), 'Missing real reading progress');
    }
  } finally {
    if (op.isRunning) {
      await op.cancel();
      try { await op.result; } on ArchiveException catch (_) {}
    }
    await sub.cancel();
  }
}

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    throw ArgumentError('Usage: streaming.dart <absolute-reader-probe-work-directory> [absolute-native-library]');
  }
  final root = args.first;
  require(Directory(root).isAbsolute && Directory(root).existsSync(), 'Absolute fixture directory required');
  final service = args.length == 1 ? ArchiveService.instance : ArchiveService.withLibrary(args[1]);
  ArchiveNativePath at(String name) => native(join(root, name));
  final payload = File(join(root, 'source/payload.bin')).readAsBytesSync();
  final regionLength = BigInt.from(File(join(root, 'single.rva')).lengthSync());
  final raw = Platform.isWindows
      ? ArchivePathComponent.windowsUtf16([...('raw-'.codeUnits), 0xD800, ...('.bin'.codeUnits)])
      : ArchivePathComponent.unixBytes([...('raw-'.codeUnits), 255, ...('.bin'.codeUnits)]);
  final rawBytes = 'raw-name'.codeUnits;

  Future<void> examine(String name, ArchiveSource source) async {
    final reader = await service.openReader(at(name), source: source).result;
    try {
      final manifest = await reader.manifest().result;
      final none = named(manifest, 'none.bin');
      final zlib = named(manifest, 'zlib.bin');
      final empty = named(manifest, 'empty.bin');
      final rawEntry = manifest.entries.singleWhere((e) => e.path.components.length == 1 &&
          e.path.components.single.encoding == raw.encoding && e.path.components.single.value == raw.value);
      require(none.payload?.compression == ArchiveCompression.none &&
          zlib.payload?.compression == ArchiveCompression.zlib &&
          rawEntry.payload?.compression == ArchiveCompression.zstd, 'Unexpected fixture codecs');
      await readSmall(reader, none, payload);
      await readSmall(reader, zlib, payload);
      await readSmall(reader, rawEntry, rawBytes);
      await readSmall(reader, empty, []);
      for (final (index, kind) in [
        (named(manifest, 'tree').index, ArchiveErrorKind.notFile),
        (BigInt.from(999), ArchiveErrorKind.entryNotFound),
      ]) {
        final op = reader.readEntry(index);
        var count = 0;
        await for (final chunk in op.stream) { count += chunk.length; }
        final error = await expectArchive(kind, () async { await op.result; });
        require(count == 0 && error.index == index && !op.isRunning, 'Invalid entry stream result');
      }
      await reader.verify().result;
      print('DART_STREAM_${source.kind.name.toUpperCase()}_CODECS_RAW_EMPTY_ERRORS_PASS');
    } finally {
      await reader.close();
    }
  }
  await examine('single.rva', const ArchiveSource.single());
  await examine('split.rva.parts', const ArchiveSource.split());
  await examine('embedded.bin', ArchiveSource.embedded(offset: BigInt.from(37), length: regionLength));

  // All bytes delivered, but last chunk still unacknowledged: the worker
  // cannot finish even if this tiny entry would otherwise complete instantly.
  final lastReader = await service.openReader(at('single.rva')).result;
  try {
    final index = named(await lastReader.manifest().result, 'none.bin').index;
    final op = lastReader.readEntry(index);
    final iterator = StreamIterator(op.stream);
    try {
      require(await iterator.moveNext(), 'Expected one payload chunk');
      require(equalBytes(iterator.current, payload), 'Expected entire small None chunk');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      require(op.isRunning, 'Terminal completed before last chunk acknowledgement');
      require(!await iterator.moveNext(), 'Unexpected extra small chunk');
      final result = await op.result;
      require(result.outputBytes == BigInt.from(payload.length) && !op.isRunning, 'Last chunk terminal');
      print('DART_STREAM_LAST_CHUNK_ACK_PASS');
    } finally {
      await iterator.cancel();
    }
  } finally {
    await lastReader.close();
  }

  // A paused large reader does not prevent a second independent reader from
  // streaming. Check all 128 MiB incrementally against the original file.
  final large = await service.openReader(at('large.rva')).result;
  final other = await service.openReader(at('split.rva.parts')).result;
  final file = File(join(root, 'source/large.bin')).openSync();
  try {
    final op = large.readEntry(BigInt.zero);
    final iterator = StreamIterator(op.stream);
    var count = 0;
    var chunks = 0;
    var maxChunk = 0;
    void compareChunk(Uint8List chunk) {
      checkChunk(chunk);
      require(equalBytes(chunk, file.readSync(chunk.length)), 'Large stream bytes mismatch at $count');
      count += chunk.length;
      chunks++;
      if (chunk.length > maxChunk) maxChunk = chunk.length;
    }
    final progress = <ArchiveProgress>[];
    final progressSub = op.progress.listen(progress.add);
    try {
      require(await iterator.moveNext(), 'Large stream missing first chunk');
      compareChunk(iterator.current);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      require(op.isRunning, 'Paused large stream finished prematurely');
      require(progress.every((p) => p.processedBytes == BigInt.zero), 'Core advanced unacknowledged write');
      try {
        large.verify();
        throw StateError('Busy reader accepted another operation');
      } on ArchiveBridgeException catch (error) {
        require(error.kind == ArchiveBridgeErrorKind.busy, 'Unexpected busy error');
      }
      final otherEntry = named(await other.manifest().result, 'zlib.bin');
      await readSmall(other, otherEntry, payload);
      require(op.isRunning, 'Paused reader was not independent');
      while (await iterator.moveNext()) { compareChunk(iterator.current); }
      final result = await op.result;
      require(file.readSync(1).isEmpty && count == 128 * 1024 * 1024 &&
          chunks > 1 && result.outputBytes == BigInt.from(count) &&
          result.entryCount == BigInt.one && !op.isRunning, 'Large stream terminal');
      print('DART_STREAM_PAUSE_RESUME_INDEPENDENT_PASS bytes=$count chunks=$chunks maxChunk=$maxChunk');
    } finally {
      await iterator.cancel();
      await progressSub.cancel();
    }
  } finally {
    file.closeSync();
    await large.close();
    await other.close();
  }

  // A corrupt uncompressed payload can produce provisional bytes; only the
  // terminal verification result grants validity. No false success.
  final corrupt = await service.openReader(at('bad-payload.rva')).result;
  try {
    final entry = named(await corrupt.manifest().result, 'none.bin');
    final op = corrupt.readEntry(entry.index);
    var provisional = 0;
    await for (final chunk in op.stream) {
      checkChunk(chunk);
      provisional += chunk.length;
    }
    final error = await expectArchive(ArchiveErrorKind.integrity, () async { await op.result; });
    require(provisional == payload.length && error.index == entry.index &&
        !op.isRunning, 'Corruption did not invalidate provisional data');
    final valid = named(await corrupt.manifest().result, 'zlib.bin');
    await readSmall(corrupt, valid, payload);
    print('DART_STREAM_PROVISIONAL_INTEGRITY_PASS bytes=$provisional');
  } finally {
    await corrupt.close();
  }

  // All cancellation paths must drain terminal and release the native handle
  // even when no data subscriber can accept another chunk.
  Future<void> cancelScenario(String mode) async {
    final reader = await service.openReader(at('large.rva')).result;
    final op = reader.readEntry(BigInt.zero);
    StreamIterator<Uint8List>? iterator;
    try {
      if (mode != 'NO_LISTENER') {
        iterator = StreamIterator(op.stream);
        require(await iterator.moveNext(), 'No real payload before $mode');
        checkChunk(iterator.current);
        require(op.isRunning, 'Operation already finished before $mode');
      }
      switch (mode) {
        case 'NO_LISTENER':
          // Allow an initial pull to reach native code without a subscriber.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          require(op.isRunning, 'Unlistened large stream finished prematurely');
          await op.cancel();
          break;
        case 'PAUSED_CANCEL':
          await op.cancel();
          break;
        case 'SUBSCRIPTION_CANCEL':
          await iterator!.cancel();
          break;
        case 'PAUSED_CLOSE':
          await reader.close();
          require(!op.isRunning, 'Reader close returned before stream cleanup');
          break;
        default:
          throw StateError('Unknown cancellation mode');
      }
      await expectArchive(ArchiveErrorKind.cancelled, () async { await op.result; });
      require(!op.isRunning, 'Cancelled native operation still running');
      await expectArchive(ArchiveErrorKind.closed, () async { await reader.verify().result; });
      print('DART_STREAM_${mode}_PASS');
    } finally {
      await iterator?.cancel();
      await reader.close();
      await reader.close();
    }
  }
  for (final mode in ['NO_LISTENER', 'PAUSED_CANCEL', 'SUBSCRIPTION_CANCEL', 'PAUSED_CLOSE']) {
    await cancelScenario(mode);
  }

  // Cancel even after the final bytes were delivered but not acknowledged.
  final finalReader = await service.openReader(at('single.rva')).result;
  try {
    final index = named(await finalReader.manifest().result, 'none.bin').index;
    final op = finalReader.readEntry(index);
    final iterator = StreamIterator(op.stream);
    try {
      require(await iterator.moveNext() && equalBytes(iterator.current, payload), 'Last chunk fixture');
      await op.cancel();
      await expectArchive(ArchiveErrorKind.cancelled, () async { await op.result; });
      require(!op.isRunning, 'Last chunk cancellation cleanup');
      print('DART_STREAM_LAST_CHUNK_CANCEL_PASS');
    } finally {
      await iterator.cancel();
    }
  } finally {
    await finalReader.close();
  }

  final reopened = await service.openReader(at('large.rva')).result;
  try {
    final result = await reopened.verify().result;
    require(result.entryCount == BigInt.one && result.outputBytes == BigInt.from(128 * 1024 * 1024),
        'Reopen verify failed');
  } finally {
    await reopened.close();
  }
  print('DART_STREAM_REOPEN_PASS');
  print('ARCHIVE_FFI_D_STREAMING_COMPLETED mode=${args.length == 1 ? "nativeAssets" : "explicit"} os=${Platform.operatingSystem}');
}
