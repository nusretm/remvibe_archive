import 'dart:async';
import 'dart:isolate';

import 'models.dart';
import 'native/bindings.dart';

Future<Object?> _call(String? library, String operation, Map<String, Object?>? input) =>
    Isolate.run(() => ArchiveNativeBindings.load(library).call(operation, input));

Future<String> _start(String? library, String operation, Map<String, Object?>? input) async {
  final value = await _call(library, operation, input);
  try {
    final handle = jsonObject(value)['handle'] as String;
    final id = BigInt.parse(handle);
    if (id <= BigInt.zero || id.toString() != handle) throw const FormatException('Invalid operation handle');
    return handle;
  } catch (error) {
    throw ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation, error.toString());
  }
}

/// Owns one native operation. Await result even after a cancellation request.
/// A establishes terminal result delivery; B/C introduce actual Core progress.
class ArchiveOperation<T> {
  final String? _library;
  final Future<String> _handle;
  final _progress = StreamController<ArchiveProgress>.broadcast();
  late final Future<T> result;
  bool _done = false;

  ArchiveOperation._(this._library, this._handle, String operation, T Function(Object?) decode) {
    result = _receive(operation, decode);
  }

  Stream<ArchiveProgress> get progress => _progress.stream;
  bool get isRunning => !_done;

  Future<void> cancel() async {
    if (_done) return;
    final handle = await _handle;
    if (_done) return;
    await _call(_library, 'operation_cancel', {'handle': handle});
  }

  Future<T> _receive(String operation, T Function(Object?) decode) async {
    String? handle;
    try {
      handle = await _handle;
      // The blocking receive and independent cancel/close never run on UI.
      final value = await _call(_library, 'operation_recv', {'handle': handle});
      final event = jsonObject(value);
      if (event['kind'] != 'terminal') {
        throw ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation, 'Expected terminal event');
      }
      final terminal = ArchiveNativeBindings.unwrap(operation, event['result']);
      try {
        return decode(terminal);
      } catch (error) {
        throw ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation, error.toString());
      }
    } finally {
      try {
        if (handle != null) await _call(_library, 'operation_close', {'handle': handle});
      } finally {
        _done = true;
        // A paused or absent progress listener must not keep native resources alive.
        unawaited(_progress.close());
      }
    }
  }
}

ArchiveOperation<T> startArchiveOperation<T>(
    String? library, String operation, Map<String, Object?>? input, T Function(Object?) decode) =>
    ArchiveOperation._(library, _start(library, operation, input), operation, decode);
