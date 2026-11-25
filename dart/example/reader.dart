import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:remvibe_archive_dart/remvibe_archive_dart.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}
String join(String parent, String child) => '$parent${Platform.pathSeparator}$child';
ArchiveNativePath native(String value) => ArchiveNativePath.fromString(value);
bool absent(String path) => FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound;
Future<ArchiveException> expectArchive(ArchiveErrorKind kind, Future<void> Function() action) async {
  try {
    await action();
    throw StateError('Expected ${kind.name}');
  } on ArchiveException catch (error) {
    require(error.kind == kind, 'Expected ${kind.name}, got $error');
    return error;
  }
}
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
void checkProgress(List<ArchiveProgress> events, BigInt entries, BigInt bytes,
    ArchiveProgressPhase payloadPhase, {bool metadata = false}) {
  require(events.isNotEmpty && events.last.phase == ArchiveProgressPhase.completed, 'Missing completed phase');
  require(events.any((e) => e.phase == payloadPhase), 'Missing payload phase');
  if (metadata) {
    for (final phase in [ArchiveProgressPhase.preparing, ArchiveProgressPhase.applyingMetadata, ArchiveProgressPhase.finalizing]) {
      require(events.any((e) => e.phase == phase), 'Missing ${phase.name}');
    }
  }
  var last = BigInt.zero;
  var count = BigInt.zero;
  for (final e in events) {
    require(e.isReader && e.outputBytes != null && e.totalEntries == entries && e.totalBytes == bytes,
        'Reader totals missing');
    require(e.processedBytes >= last && e.processedBytes <= bytes, 'Reader bytes invalid');
    require(e.entriesCompleted >= count && e.entriesCompleted <= entries, 'Entry count invalid');
    require(e.entryTotalBytes == null || e.entryBytesRead <= e.entryTotalBytes!, 'Entry bytes invalid');
    last = e.processedBytes;
    count = e.entriesCompleted;
  }
  require(last == bytes && count == entries, 'Final counters mismatch');
}

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    throw ArgumentError('Usage: reader.dart <absolute-prepared-work-directory> [absolute-native-library]');
  }
  final root = args.first;
  require(Directory(root).isAbsolute && Directory(root).existsSync(), 'Absolute prepared directory required');
  final service = args.length == 1 ? ArchiveService.instance : ArchiveService.withLibrary(args[1]);
  ArchiveNativePath at(String name) => native(join(root,name));
  final length = BigInt.from(File(join(root,'single.rva')).lengthSync());
  final total = BigInt.from(48 * 1024 * 2 + 8 + 12 + 14);
  final entryCount = BigInt.from(10);
  final raw = Platform.isWindows
      ? ArchivePathComponent.windowsUtf16([...('raw-'.codeUnits),0xD800,...('.bin'.codeUnits)])
      : ArchivePathComponent.unixBytes([...('raw-'.codeUnits),255,...('.bin'.codeUnits)]);
  BigInt? selectedIndex;
  BigInt? directoryIndex;

  Future<void> examine(String name, ArchiveSource source, String output) async {
    final reader = await service.openReader(at(name), source: source).result;
    try {
      require(reader.entryCount == entryCount, 'Unexpected entry count');
      require(reader.region.offset == (source.kind == ArchiveSourceKind.embedded ? BigInt.from(37) : BigInt.zero), 'Region offset mismatch');
      if (source.kind != ArchiveSourceKind.split) require(reader.region.length == length,'Region length mismatch');
      final manifest = await reader.manifest().result;
      require(manifest.entries.length == 10 && manifest.totalBytes == total, 'Manifest totals');
      ArchiveEntry entry(String path) => manifest.entries.singleWhere((e) =>
          jsonEncode(e.path.toJson()) == jsonEncode(ArchivePath.fromString(path).toJson()));
      final none = entry('none.bin');
      final zlib = entry('zlib.bin');
      final empty = entry('empty.bin');
      final dir = entry('tree');
      require(none.kind == ArchiveEntryKind.file && none.payload?.compression == ArchiveCompression.none &&
          zlib.payload?.compression == ArchiveCompression.zlib && empty.payload?.compression == ArchiveCompression.zstd &&
          empty.payload?.originalSize == BigInt.zero && dir.kind == ArchiveEntryKind.directory && dir.payload == null,'Manifest codec/kind');
      require(none.payload!.offset == BigInt.from(16) &&
          none.payload!.storedSize == BigInt.from(48 * 1024) &&
          none.payload!.originalSize == none.metadata.size &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(none.payload!.sha256),'Payload fields');
      final rawEntry = manifest.entries.singleWhere((e) => e.path.components.length == 1 &&
          e.path.components.single.encoding == raw.encoding && e.path.components.single.value == raw.value);
      require(rawEntry.payload?.originalSize == BigInt.from(8),'Raw native name not preserved');
      final timestamp = none.metadata.modifiedAt!;
      require(timestamp.seconds == BigInt.from(-3) && timestamp.nanoseconds == 500000000, 'Signed floor timestamp conversion');
      final permissions = none.metadata.permissions;
      require(Platform.isWindows ? permissions is ArchiveWindowsPermissions : permissions is ArchiveUnixPermissions,
          'Full permissions absent or wrong type');
      if (permissions is ArchiveWindowsPermissions) {
        require(permissions.dacl.kind == ArchiveWindowsDaclKind.entries &&
            permissions.dacl.entries.isNotEmpty,'Expected real DACL');
        require(permissions.dacl.entries.any((e) => e is ArchiveWindowsAccessAce),'Expected access ACE');
      }
      // Manifest wire metadata is interoperable with FS without loading a second library.
      require(jsonEncode(ArchiveMetadata.fromJson(none.metadata.toJson()).toJson()) ==
          jsonEncode(none.metadata.toJson()), 'Metadata roundtrip');
      final verifyEvents = <ArchiveProgress>[];
      final verified = await observe(reader.verify(),verifyEvents);
      require(verified.entryCount == entryCount && verified.outputBytes == total,'Verify result');
      checkProgress(verifyEvents,entryCount,total,ArchiveProgressPhase.verifying);
      await reader.verify().result; // Previous operation close must not poison the token.
      final extractEvents = <ArchiveProgress>[];
      final result = await observe(reader.extractTo(at(output), options: ArchiveExtractOptions(
        sync: source.kind == ArchiveSourceKind.embedded ? ExtractionSync.perFile : ExtractionSync.buffered,
      )),extractEvents);
      require(result.entryCount == entryCount && result.outputBytes == total && result.metadata.length == 10,'Extract result');
      require(result.metadata.every((m) => m.result.isSuccess &&
          m.result.fields.any((f) => f.field == ArchiveMetadataField.modifiedTime && f.status == ArchiveMetadataApplyStatus.applied)),
          'Default modified time policy result');
      checkProgress(extractEvents,entryCount,total,ArchiveProgressPhase.extracting,metadata:true);
      if (source.kind == ArchiveSourceKind.single) {
        selectedIndex = zlib.index;
        directoryIndex = dir.index;
      }
      print('DART_READER_${source.kind.name.toUpperCase()}_MANIFEST_VERIFY_EXTRACT_PASS entries=${result.entryCount} bytes=${result.outputBytes}');
    } finally {
      await reader.close();
      await reader.close();
    }
  }
  await examine('single.rva',const ArchiveSource.single(),'single-out');
  await examine('split.rva.parts',const ArchiveSource.split(),'split-out');
  await examine('embedded.bin',ArchiveSource.embedded(offset:BigInt.from(37),length:length),'embedded-out');

  final reader = await service.openReader(at('single.rva')).result;
  try {
    final index = selectedIndex!;
    final selectedEvents = <ArchiveProgress>[];
    final selected = await observe(reader.extractEntryTo(index,at('selected.bin'),
        options: const ArchiveExtractOptions(sync:ExtractionSync.perFile)),selectedEvents);
    require(selected.entryCount == BigInt.one && selected.outputBytes == BigInt.from(48*1024) &&
        selected.metadata.length == 1 && selected.metadata.single.result.isSuccess,'Selected extract');
    checkProgress(selectedEvents,BigInt.one,BigInt.from(48*1024),ArchiveProgressPhase.extracting,metadata:true);
    final deferred = await reader.extractEntryTo(index,at('deferred.bin'),
        options: const ArchiveExtractOptions(metadataPolicy:null)).result;
    require(deferred.metadata.isEmpty,'Deferred metadata applied');
    File(join(root,'existing.bin')).writeAsStringSync('keep');
    await expectArchive(ArchiveErrorKind.destinationExists,() async {await reader.extractEntryTo(index,at('existing.bin')).result;});
    final directoryError = await expectArchive(ArchiveErrorKind.notFile,() async {
      await reader.extractEntryTo(directoryIndex!,at('not-file.bin')).result;
    });
    require(directoryError.index == directoryIndex,'Wrong directory index');
    final missingError = await expectArchive(ArchiveErrorKind.entryNotFound,() async {
      await reader.extractEntryTo(BigInt.from(999),at('missing-entry.bin')).result;
    });
    require(missingError.index == BigInt.from(999),'Wrong missing index');
    final policy = Platform.isWindows
        ? const ArchiveMetadataPolicy(posixMode:ArchiveMetadataRequirement.required)
        : const ArchiveMetadataPolicy(windowsAcl:ArchiveMetadataRequirement.required);
    final metadataError = await expectArchive(ArchiveErrorKind.metadata,() async {
      await reader.extractEntryTo(index,at('metadata-failed.bin'),options:ArchiveExtractOptions(metadataPolicy:policy)).result;
    });
    require(metadataError.archivePath != null && metadataError.metadataResult?.isSuccess == false &&
        metadataError.metadataResult!.fields.any((f) => f.fatal),'Required metadata error details');
    await reader.verify().result; // non-cancellation failures leave the reader usable.
  } finally {
    await reader.close();
  }
  await expectArchive(ArchiveErrorKind.closed,() async {await reader.verify().result;});
  print('DART_READER_SELECTED_METADATA_POLICIES_ERRORS_PASS');

  final empty = await service.openReader(at('empty.rva')).result;
  try {
    require((await empty.manifest().result).entries.isEmpty,'Empty manifest');
    require((await empty.verify().result).entryCount == BigInt.zero,'Empty verification');
    final result = await empty.extractTo(at('empty-out')).result;
    require(result.entryCount == BigInt.zero && result.outputBytes == BigInt.zero,'Empty extraction');
  } finally {await empty.close();}
  Future<void> rejectOpen(String name, ArchiveErrorKind kind, {ArchiveSource source = const ArchiveSource.single(),
      ArchiveReaderOptions options = const ArchiveReaderOptions()}) async {
    await expectArchive(kind,() async {
      final unexpected = await service.openReader(at(name),source:source,options:options).result;
      await unexpected.close();
    });
  }
  await rejectOpen('bad-header.rva',ArchiveErrorKind.format);
  await rejectOpen('bad-manifest.rva',ArchiveErrorKind.manifest);
  await rejectOpen('embedded.bin',ArchiveErrorKind.format,
      source:ArchiveSource.embedded(offset:BigInt.from(37),length:BigInt.one));
  await rejectOpen('missing-parts',ArchiveErrorKind.io,source:const ArchiveSource.split());
  await rejectOpen('single.rva',ArchiveErrorKind.manifest,
      options:ArchiveReaderOptions(limits:ArchiveManifestLimits(maxManifestBytes:BigInt.one)));
  final corrupt = await service.openReader(at('bad-payload.rva')).result;
  try {
    require((await corrupt.manifest().result).entries.length == 10,'Manifest must open before payload verification');
    final bad = await expectArchive(ArchiveErrorKind.integrity,() async {await corrupt.verify().result;});
    require(bad.index == BigInt.zero && bad.reason != null,'Integrity details');
    await expectArchive(ArchiveErrorKind.integrity,() async {await corrupt.extractTo(at('bad-payload-out')).result;});
    require(absent(join(root,'bad-payload-out')),'Corrupt payload published');
  } finally {await corrupt.close();}
  print('DART_READER_FORMAT_LIMITS_INTEGRITY_CLEANUP_PASS');

  Future<void> cancelExtract(String name, {required bool close}) async {
    final large = await service.openReader(at('large.rva'),
        options:ArchiveReaderOptions(bufferSize:BigInt.from(4096))).result;
    final operation = large.extractTo(at(name),options:const ArchiveExtractOptions(metadataPolicy:null));
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds:2),(_) {
      if (operation.isRunning) ticks++;
    });
    final started = Completer<bool>();
    final terminal = operation.result.then<bool>((_) => false,onError:(Object error,StackTrace stack) {
      if (error is ArchiveException && error.kind == ArchiveErrorKind.cancelled) return true;
      Error.throwWithStackTrace(error,stack);
    });
    final subscription = operation.progress.listen((p) {
      if (p.phase == ArchiveProgressPhase.extracting && !started.isCompleted) started.complete(true);
    });
    try {
      try {
        large.manifest();
        throw StateError('Concurrent reader command accepted');
      } on ArchiveBridgeException catch(e) {
        require(e.kind == ArchiveBridgeErrorKind.busy,'Expected busy');
      }
      require(await Future.any<bool>([started.future,terminal.then((_) => false)]),'No real extraction progress');
      if (close) { await large.close(); } else { await operation.cancel(); }
      require(await terminal && !operation.isRunning && ticks > 0,'Active cancellation/heartbeat failed');
      require(absent(join(root,name)),'Cancelled destination published');
      await expectArchive(ArchiveErrorKind.closed,() async {await large.verify().result;});
      print('DART_READER_${close ? "ACTIVE_CLOSE" : "ACTIVE_CANCEL"}_PASS ticks=$ticks');
    } finally {
      timer.cancel();
      await subscription.cancel();
      await large.close();
    }
  }
  await cancelExtract('cancelled-out',close:false);
  await cancelExtract('active-close-out',close:true);
  final reopened = await service.openReader(at('large.rva')).result;
  try {
    final result = await reopened.verify().result;
    require(result.entryCount == BigInt.one && result.outputBytes == BigInt.from(128*1024*1024),'Reopen verification');
  } finally {await reopened.close();}
  require(!Directory(root).listSync().any((e) =>
      e.path.split(Platform.pathSeparator).last.startsWith('.remvibe-rva-')),'Orphan staging');
  print('DART_READER_CANCEL_REOPEN_CLEANUP_PASS');
  print('ARCHIVE_FFI_C_READER_COMPLETED mode=${args.length == 1 ? "nativeAssets" : "explicit"} os=${Platform.operatingSystem}');
}
