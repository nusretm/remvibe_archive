import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:remvibe_archive_dart/remvibe_archive_dart.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}
String join(String parent, String child) => '$parent${Platform.pathSeparator}$child';
ArchiveNativePath native(String path) => ArchiveNativePath.fromString(path);
ArchivePath relative(String path) => ArchivePath.fromString(path);
Future<T> observe<T>(ArchiveOperation<T> operation, List<ArchiveProgress> events) async {
  final done = Completer<void>();
  final sub = operation.progress.listen(events.add, onDone: () => done.complete());
  try {
    final value = await operation.result;
    await done.future;
    return value;
  } finally {
    await sub.cancel();
  }
}
Future<void> expectArchive(ArchiveErrorKind kind, Future<void> Function() action) async {
  try {
    await action();
    throw StateError('Expected ${kind.name}');
  } on ArchiveException catch (error) {
    require(error.kind == kind, 'Expected ${kind.name}, got $error');
  }
}
bool absent(String path) => FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound;
void noStages(String root) {
  require(!Directory(root).listSync().any((e) =>
      e.path.split(Platform.pathSeparator).last.startsWith('.remvibe-rva-')),
      'Orphan staging under $root');
}
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    throw ArgumentError('Usage: writer.dart <absolute-prepared-work-directory> [absolute-native-library]');
  }
  final root = args.first;
  require(Directory(root).isAbsolute && Directory(root).existsSync(), 'Absolute prepared directory required');
  final service = args.length == 1 ? ArchiveService.instance : ArchiveService.withLibrary(args[1]);
  final source = join(root, 'source');
  require(Directory(source).existsSync(), 'Run Rust writer_verify prepare first');
  final payload = Uint8List(48 * 1024);
  final random = Random(1007);
  for (var i = 0; i < payload.length; i++) {
    payload[i] = random.nextInt(256);
  }
  File(join(source, 'payload.bin')).writeAsBytesSync(payload);
  File(join(source, 'empty.bin')).createSync();
  final tree = join(source, 'tree');
  Directory(join(tree, 'nested')).createSync(recursive: true);
  Directory(join(tree, 'empty')).createSync();
  File(join(tree, 'root.txt')).writeAsStringSync('root content');
  File(join(join(tree, 'nested'), 'İstanbul.txt')).writeAsStringSync('nested content');
  final rawUnits = <int>[...('raw-'.codeUnits), Platform.isWindows ? 0xD800 : 255, ...('.bin'.codeUnits)];
  final rawPrefix = native('$source${Platform.pathSeparator}');
  final rawSource = ArchiveNativePath(rawPrefix.encoding, [...rawPrefix.units, ...rawUnits]);
  final rawPath = ArchivePath([Platform.isWindows
      ? ArchivePathComponent.windowsUtf16(rawUnits)
      : ArchivePathComponent.unixBytes(rawUnits)]);

  Future<void> produce(String name, ArchiveWriterOptions options, bool split) async {
    final destination = join(root, name);
    final writer = await service.createWriter(native(destination), options: options).result;
    final events = <ArchiveProgress>[];
    try {
      require(absent(destination), 'Destination published during create');
      await observe(writer.addFile(source: native(join(source,'payload.bin')),
          path: relative('none.bin'), compression: ArchiveCompression.none), events);
      await observe(writer.addFile(source: native(join(source,'payload.bin')),
          path: relative('zlib.bin'), compression: ArchiveCompression.zlib), events);
      await observe(writer.addFile(source: native(join(source,'empty.bin')),
          path: relative('empty.bin')), events);
      await observe(writer.addFile(source: rawSource, path: rawPath), events);
      await observe(writer.addDirectory(source: native(tree), path: relative('tree')), events);
      await observe(writer.addDirectory(source: native(tree), path: relative('shallow'), recursive: false), events);
      require(absent(destination), 'Destination published before finish');
      final result = await observe(writer.finish(), events);
      require(result.entryCount == BigInt.from(10), 'Wrong entry count: ${result.entryCount}');
      require(result.sourceBytes == BigInt.from(payload.length * 2 + 8 + 12 + 14), 'Wrong source byte count');
      require(result.archiveBytes > BigInt.zero, 'Invalid logical size');
      if (split) {
        final parts = Directory(destination).listSync().whereType<File>().toList();
        final total = parts.fold<int>(0, (sum, file) => sum + file.lengthSync());
        require(parts.length > 1 && parts.every((file) => file.lengthSync() <= 4096), 'Wrong split parts');
        require(result.partCount == BigInt.from(parts.length) &&
            result.physicalBytes == BigInt.from(total) &&
            result.physicalBytes == result.archiveBytes + result.partCount * BigInt.from(72),
            'Wrong split byte accounting');
      } else {
        require(result.partCount == BigInt.one &&
            result.archiveBytes == result.physicalBytes &&
            result.physicalBytes == BigInt.from(File(destination).lengthSync()), 'Wrong Single accounting');
      }
      require(events.isNotEmpty && events.last.phase == ArchiveProgressPhase.completed, 'Missing completed phase');
      for (final phase in [ArchiveProgressPhase.preparing, ArchiveProgressPhase.writing,
          ArchiveProgressPhase.entryCompleted, ArchiveProgressPhase.finalizing, ArchiveProgressPhase.completed]) {
        require(events.any((event) => event.phase == phase), 'Missing phase ${phase.name}');
      }
      require(events.where((e) => e.phase == ArchiveProgressPhase.entryCompleted).length == 10, 'Entry progress missing');
      var previous = BigInt.zero;
      for (final event in events) {
        require(event.sourceBytesRead >= previous, 'Source counters decreased');
        require(event.entryTotalBytes == null || event.entryBytesRead <= event.entryTotalBytes!, 'Entry progress out of range');
        previous = event.sourceBytesRead;
      }
      require(events.last.sourceBytesRead == result.sourceBytes &&
          events.last.entriesCompleted == result.entryCount, 'Final progress mismatch');
      print('DART_WRITER_${split ? "SPLIT" : "SINGLE"}_PROGRESS_PASS entries=${result.entryCount} parts=${result.partCount} logical=${result.archiveBytes} physical=${result.physicalBytes}');
    } finally {
      await writer.close();
      await writer.close();
    }
  }
  await produce('single.rva', const ArchiveWriterOptions(), false);
  await produce('split.rva.parts', ArchiveWriterOptions(
      layout: ArchiveLayout.split(BigInt.from(4096)),
      manifestCompression: ArchiveCompression.zlib,
      zlibLevel: 1, zstdLevel: 5, bufferSize: BigInt.from(4096),
      metadataCapture: ArchiveMetadataCapture.full,
  ), true);
  final empty = await service.createWriter(native(join(root,'empty-manifest.rva')),
      options: const ArchiveWriterOptions(compression: ArchiveCompression.none,
          manifestCompression: ArchiveCompression.none)).result;
  try {
    final result = await empty.finish().result;
    require(result.entryCount == BigInt.zero && result.sourceBytes == BigInt.zero, 'Empty archive mismatch');
  } finally {
    await empty.close();
  }

  final conflict = join(root, 'single.rva');
  final before = File(conflict).lengthSync();
  await expectArchive(ArchiveErrorKind.destinationExists, () async {
    final unexpected = await service.createWriter(native(conflict)).result;
    await unexpected.close();
  });
  require(File(conflict).lengthSync() == before, 'Existing archive replaced');
  await expectArchive(ArchiveErrorKind.invalid, () async {
    final unexpected = await service.createWriter(native(join(root,'invalid.rva')),
        options: const ArchiveWriterOptions(zstdLevel: 0)).result;
    await unexpected.close();
  });

  final aborted = join(root,'aborted.rva');
  final abortWriter = await service.createWriter(native(aborted)).result;
  try {
    await abortWriter.addFile(source: native(join(source,'payload.bin')), path: relative('a')).result;
    await abortWriter.abort().result;
  } finally {
    await abortWriter.close();
  }
  require(absent(aborted), 'Abort published destination');

  final duplicate = join(root,'duplicate.rva');
  final duplicateWriter = await service.createWriter(native(duplicate)).result;
  try {
    await duplicateWriter.addFile(source: native(join(source,'payload.bin')), path: relative('dup')).result;
    await expectArchive(ArchiveErrorKind.invalid, () async {
      await duplicateWriter.addFile(source: native(join(source,'payload.bin')), path: relative('dup')).result;
    });
    await expectArchive(ArchiveErrorKind.closed, () async { await duplicateWriter.finish().result; });
  } finally {
    await duplicateWriter.close();
  }
  require(absent(duplicate), 'Failed add published destination');
  final limit = join(root,'limited.rva');
  final limitWriter = await service.createWriter(native(limit), options: ArchiveWriterOptions(
      limits: ArchiveManifestLimits(maxFileBytes: BigInt.one))).result;
  try {
    await expectArchive(ArchiveErrorKind.invalid, () async {
      await limitWriter.addFile(source: native(join(source,'payload.bin')), path: relative('payload')).result;
    });
  } finally {
    await limitWriter.close();
  }
  require(absent(limit), 'Limit failure published destination');

  final missing = join(root,'missing.rva');
  final missingWriter = await service.createWriter(native(missing)).result;
  try {
    try {
      await missingWriter.addFile(source: native(join(source,'not-found.bin')), path: relative('missing')).result;
      throw StateError('Missing source accepted');
    } on ArchiveException catch (error) {
      require(error.kind == ArchiveErrorKind.fileSystem &&
          error.fileSystem?.kind == ArchiveFileSystemErrorKind.notFound &&
          error.fileSystem?.path != null, 'Missing nested FS error: $error');
    }
  } finally {
    await missingWriter.close();
  }
  require(absent(missing), 'Missing source published destination');
  noStages(root);
  print('DART_WRITER_ABORT_ERRORS_LIMITS_CLEANUP_PASS');

  // Real cancellation on an active Core write, not a synthetic operation.
  final large = join(source,'large.bin');
  final chunk = Uint8List(1024 * 1024);
  for (var i = 0; i < chunk.length; i++) {
    chunk[i] = random.nextInt(256);
  }
  final largeFile = File(large).openSync(mode: FileMode.write);
  try {
    for (var i = 0; i < 64; i++) {
      largeFile.writeFromSync(chunk);
    }
  } finally {
    largeFile.closeSync();
  }
  final cancelled = join(root,'cancelled.rva.parts');
  final cancelWriter = await service.createWriter(native(cancelled), options: ArchiveWriterOptions(
      layout: ArchiveLayout.split(BigInt.from(1024 * 1024)),
      zstdLevel: 19, bufferSize: BigInt.from(64 * 1024))).result;
  try {
    final operation = cancelWriter.addFile(source: native(large), path: relative('large.bin'));
    var heartbeats = 0;
    final heartbeat = Timer.periodic(const Duration(milliseconds: 2), (_) {
      if (operation.isRunning) heartbeats++;
    });
    Future<void>? request;
    var observedWriting = false;
    final sub = operation.progress.listen((p) {
      if (p.phase == ArchiveProgressPhase.writing && request == null) {
        observedWriting = true;
        request = operation.cancel();
      }
    });
    try {
      try {
        cancelWriter.addDirectory(source: native(tree), path: relative('busy'));
        throw StateError('Concurrent writer command accepted');
      } on ArchiveBridgeException catch (error) {
        require(error.kind == ArchiveBridgeErrorKind.busy, 'Unexpected busy error');
      }
      await expectArchive(ArchiveErrorKind.cancelled, () async { await operation.result; });
      final cancellation = request;
      require(cancellation != null, 'Cancellation request not issued');
      await cancellation!;
      require(observedWriting && heartbeats > 0, 'Real progress/heartbeat not observed');
      print('DART_WRITER_ACTIVE_CANCEL_HEARTBEAT_PASS ticks=$heartbeats');
    } finally {
      heartbeat.cancel();
      await sub.cancel();
    }
  } finally {
    await cancelWriter.close();
  }
  require(absent(cancelled), 'Cancelled split set was published');
  noStages(root);

  final closed = join(root,'closed.rva');
  final closeWriter = await service.createWriter(native(closed)).result;
  await closeWriter.addFile(source: native(join(source,'payload.bin')), path: relative('a')).result;
  await closeWriter.close();
  await closeWriter.close();
  require(absent(closed), 'Close published staging');
  noStages(root);
  // Active close must await cancellation and the Core's staging cleanup.
  final activeClose = join(root, 'active-close.rva');
  final activeWriter = await service.createWriter(native(activeClose),
      options: ArchiveWriterOptions(zstdLevel: 19, bufferSize: BigInt.from(64 * 1024))).result;
  try {
    final op = activeWriter.addFile(source: native(large), path: relative('large.bin'));
    final writing = Completer<bool>();
    final terminal = op.result.then<bool>((_) => false, onError: (Object error, StackTrace stack) {
      if (error is ArchiveException && error.kind == ArchiveErrorKind.cancelled) return true;
      Error.throwWithStackTrace(error, stack);
    });
    final subscription = op.progress.listen((event) {
      if (event.phase == ArchiveProgressPhase.writing && !writing.isCompleted) writing.complete(true);
    });
    try {
      final started = await Future.any<bool>([writing.future, terminal.then((_) => false)]);
      require(started, 'Active close did not observe a Core write');
      await activeWriter.close();
      require(await terminal && !op.isRunning, 'Close did not await cancellation');
    } finally {
      await subscription.cancel();
    }
  } finally {
    await activeWriter.close();
  }
  require(absent(activeClose), 'Active close published staging');
  noStages(root);
  print('DART_WRITER_EXPLICIT_CLOSE_PASS');
  print('ARCHIVE_FFI_B_WRITER_COMPLETED mode=${args.length == 1 ? "nativeAssets" : "explicit"} os=${Platform.operatingSystem}');
}
