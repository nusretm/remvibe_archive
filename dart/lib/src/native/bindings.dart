import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../models.dart';

final class _Buffer extends Opaque {}
typedef _NoInputNative = Pointer<_Buffer> Function();
typedef _NoInputDart = Pointer<_Buffer> Function();
typedef _InputNative = Pointer<_Buffer> Function(Pointer<Uint8>, Size);
typedef _InputDart = Pointer<_Buffer> Function(Pointer<Uint8>, int);

class ArchiveNativeBindings {
  static const assetId = 'package:remvibe_archive_dart/src/native/bindings.dart';
  static const prefix = 'remvibe_archive_';
  static const expectedAbi = 1;
  final DynamicLibrary _library;
  ArchiveNativeBindings._(this._library);

  factory ArchiveNativeBindings.load(String? libraryPath) {
    late final DynamicLibrary library;
    try {
      library = libraryPath == null
          ? DynamicLibrary.codeAsset(assetId)
          : DynamicLibrary.open(libraryPath);
    } catch (error) {
      throw ArchiveBridgeException(ArchiveBridgeErrorKind.loadFailed, 'load', error.toString());
    }
    try {
      final version = library.lookupFunction<Uint32 Function(), int Function()>(
          '${prefix}abi_version')();
      if (version != expectedAbi) throw StateError('ABI $version does not match $expectedAbi');
      for (final symbol in ['core_info', 'native_path_roundtrip',
          'operation_recv', 'operation_cancel', 'operation_close',
          'buffer_data', 'buffer_len', 'buffer_free']) {
        if (!library.providesSymbol('$prefix$symbol')) {
          throw StateError('Missing native symbol $prefix$symbol');
        }
      }
    } catch (error) {
      throw ArchiveBridgeException(ArchiveBridgeErrorKind.incompatibleAbi, 'load', error.toString());
    }
    return ArchiveNativeBindings._(library);
  }

  Object? call(String operation, Map<String, Object?>? input) {
    final free = _library.lookupFunction<Void Function(Pointer<_Buffer>),
        void Function(Pointer<_Buffer>)>('${prefix}buffer_free');
    final length = _library.lookupFunction<Size Function(Pointer<_Buffer>),
        int Function(Pointer<_Buffer>)>('${prefix}buffer_len');
    final data = _library.lookupFunction<Pointer<Uint8> Function(Pointer<_Buffer>),
        Pointer<Uint8> Function(Pointer<_Buffer>)>('${prefix}buffer_data');
    late final Pointer<_Buffer> result;
    if (input == null) {
      result = _library.lookupFunction<_NoInputNative, _NoInputDart>('$prefix$operation')();
    } else {
      final bytes = utf8.encode(jsonEncode(input));
      final native = calloc<Uint8>(bytes.length);
      try {
        native.asTypedList(bytes.length).setAll(0, bytes);
        result = _library.lookupFunction<_InputNative, _InputDart>('$prefix$operation')(native, bytes.length);
      } finally {
        calloc.free(native);
      }
    }
    if (result == nullptr) {
      throw ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation, 'Native returned no result');
    }
    late final Uint8List copy;
    try {
      final count = length(result);
      final pointer = data(result);
      if (count <= 0 || pointer == nullptr) throw StateError('Invalid native result buffer');
      copy = Uint8List.fromList(pointer.asTypedList(count));
    } catch (error) {
      throw ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation, error.toString());
    } finally {
      free(result);
    }
    late final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(copy));
    } catch (error) {
      throw ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation, error.toString());
    }
    return unwrap(operation, decoded);
  }

  static Object? unwrap(String operation, Object? value) {
    try {
      final envelope = jsonObject(value);
      if (envelope['ok'] == true && envelope.containsKey('value')) return envelope['value'];
      if (envelope['ok'] != false) throw const FormatException('Invalid result envelope');
      final error = jsonObject(envelope['error']);
      switch (error['domain']) {
        case 'archive':
          throw ArchiveException.fromJson(error);
        case 'bridge':
          throw ArchiveBridgeException(
            ArchiveBridgeErrorKind.values.byName(error['kind'] as String),
            error['operation'] as String, error['message'] as String,
          );
        default:
          throw const FormatException('Unknown error domain');
      }
    } on ArchiveException {
      rethrow;
    } on ArchiveBridgeException {
      rethrow;
    } catch (error) {
      throw ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation, error.toString());
    }
  }
}
