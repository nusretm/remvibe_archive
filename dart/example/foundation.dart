import 'dart:io';
import 'dart:isolate';

import 'package:remvibe_archive_dart/remvibe_archive_dart.dart';
import 'package:remvibe_archive_dart/src/native/bindings.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<Object?> nativeCall(String? library, String operation, Map<String, Object?>? input) =>
    Isolate.run(() => ArchiveNativeBindings.load(library).call(operation, input));

Future<void> main(List<String> args) async {
  if (args.length > 1) throw ArgumentError('Usage: foundation.dart [absolute-native-library]');
  final library = args.isEmpty ? null : args.single;
  final service = library == null ? ArchiveService.instance : ArchiveService.withLibrary(library);
  final operation = service.coreInfo();
  final info = await operation.result;
  require(!operation.isRunning, 'Operation was not released');
  require(info.formatVersion == 3 && info.layout == 'single', 'Unexpected RVA format/layout');
  require(info.compression == ArchiveCompression.zstd &&
      info.manifestCompression == ArchiveCompression.zstd &&
      info.zstdLevel == 3 && info.zlibLevel == 6, 'Unexpected codec defaults');
  require(info.metadataCapture == ArchiveMetadataCapture.basic &&
      info.extractionSync == ExtractionSync.buffered, 'Unexpected metadata/extraction defaults');
  require(info.writerBufferSize == BigInt.from(1024 * 1024) &&
      info.readerBufferSize == BigInt.from(1024 * 1024) &&
      info.maxManifestBytes == BigInt.from(64 * 1024 * 1024) &&
      info.maxTotalBytes == BigInt.parse('18446744073709551615'), 'Unexpected Core limits');
  await operation.cancel(); // Completed cancel is a no-op, not a running cancellation test.
  print('ABI_CORE_DEFAULTS_PASS');

  final unicode = ArchiveNativePath.fromString(Platform.isWindows
      ? r'C:\RemVibe\İstanbul-東京' : '/tmp/İstanbul-東京');
  final raw = Platform.isWindows
      ? ArchiveNativePath(ArchiveNativeEncoding.windowsUtf16, [67, 58, 92, 0xD800, 65])
      : ArchiveNativePath(ArchiveNativeEncoding.unixBytes, [47, 116, 109, 112, 47, 255, 65]);
  for (final path in [unicode, raw]) {
    final returned = ArchiveNativePath.fromJson(await nativeCall(library, 'native_path_roundtrip', path.toJson()));
    require(returned.encoding == path.encoding &&
        returned.units.join(',') == path.units.join(','), 'Native units changed');
  }
  print('NATIVE_PATH_LEXICAL_ROUNDTRIP_PASS');

  final opposite = Platform.isWindows ? 'unixBytes' : 'windowsUtf16';
  try {
    await nativeCall(library, 'native_path_roundtrip', {'encoding': opposite, 'units': [65]});
    throw StateError('Wrong native encoding accepted');
  } on ArchiveBridgeException catch (e) {
    require(e.kind == ArchiveBridgeErrorKind.invalidInput, 'Wrong error kind: $e');
  }
  try {
    await nativeCall(library, 'operation_recv', {'handle': '0'});
    throw StateError('Invalid handle accepted');
  } on ArchiveBridgeException catch (e) {
    require(e.kind == ArchiveBridgeErrorKind.invalidInput, 'Wrong handle error: $e');
  }
  final started = await nativeCall(library, 'core_info', null) as Map;
  final handle = started['handle'] as String;
  final request = {'handle': handle};
  try {
    final event = await nativeCall(library, 'operation_recv', request) as Map;
    require(event['kind'] == 'terminal', 'Missing terminal event');
    ArchiveNativeBindings.unwrap('core_info', event['result']);
  } finally {
    await nativeCall(library, 'operation_close', request);
  }
  await nativeCall(library, 'operation_close', request);
  try {
    await nativeCall(library, 'operation_recv', request);
    throw StateError('Released handle accepted');
  } on ArchiveBridgeException catch (e) {
    require(e.kind == ArchiveBridgeErrorKind.invalidHandle, 'Wrong released handle error: $e');
  }
  print('OPERATION_LIFETIME_AND_TYPED_ERRORS_PASS');
  print('ARCHIVE_FFI_A_FOUNDATION_COMPLETED mode=${library == null ? "nativeAssets" : "explicit"} os=${Platform.operatingSystem}');
}
