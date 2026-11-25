import 'dart:async';
import 'dart:isolate';

import 'models.dart';
import 'native/bindings.dart';

Future<Object?> callArchiveNative(String? library, String operation, Map<String, Object?>? input) =>
    Isolate.run(() => ArchiveNativeBindings.load(library).call(operation, input));

String archiveHandle(Object? value, String operation) {
  try {
    final handle = jsonObject(value)['handle'] as String;
    final id = BigInt.parse(handle);
    if (id <= BigInt.zero || id.toString() != handle ||
        id > BigInt.parse('18446744073709551615')) {
      throw const FormatException('Invalid handle');
    }
    return handle;
  } catch (error) {
    throw ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation, error.toString());
  }
}

Future<String> _start(String? library, String operation, Map<String, Object?>? input) async =>
    archiveHandle(await callArchiveNative(library, operation, input), operation);

/// The receiver owns no native pointer across calls. One event in flight;
/// credit/stop messages keep the isolate mailbox bounded even during bursts.
Future<void> _nativeReceiver((String?, String, SendPort, String, Object? Function(Object?)?) args) async {
  final (library, handle, output, operation, terminalDecoder) = args;
  final credits = ReceivePort();
  final iterator = StreamIterator<dynamic>(credits);
  output.send(credits.sendPort);
  try {
    final bindings = ArchiveNativeBindings.load(library);
    while (true) {
      final event = jsonObject(bindings.call('operation_recv', {'handle': handle}));
      if (event['kind'] == 'terminal' && terminalDecoder != null) {
        final terminal = ArchiveNativeBindings.unwrap(operation, event['result']);
        late final Object? decoded;
        try {
          decoded = terminalDecoder(terminal);
        } catch (error) {
          throw ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation, error.toString());
        }
        // Transfer the typed large result from this exiting receiver isolate.
        Isolate.exit(output, ['decoded', decoded]);
      }
      output.send(event);
      if (event['kind'] == 'terminal') break;
      if (!await iterator.moveNext() || iterator.current != true) break;
    }
  } catch (error) {
    output.send(['nativeError', error]);
  } finally {
    await iterator.cancel();
    credits.close();
  }
}

abstract interface class ArchiveActiveOperation {
  Future<dynamic> get result;
  bool get isRunning;
  Future<void> cancel();
}

/// Owns one native operation. Await result even after requesting cancel.
/// Progress is a broadcast notification stream; subscribe promptly. Terminal
/// result is authoritative and resolves after the native worker was joined.
class ArchiveOperation<T> implements ArchiveActiveOperation {
  final String? _library;
  final Future<String> _handle;
  final _progress = StreamController<ArchiveProgress>.broadcast();
  @override
  late final Future<T> result;
  bool _done = false;

  ArchiveOperation._(this._library, this._handle, String operation, T Function(Object?) decode, bool decodeInReceiver) {
    result = _receive(operation, decode, decodeInReceiver);
  }

  Stream<ArchiveProgress> get progress => _progress.stream;
  @override
  bool get isRunning => !_done;

  @override
  Future<void> cancel() async {
    if (_done) return;
    final handle = await _handle;
    if (_done) return;
    await callArchiveNative(_library, 'operation_cancel', {'handle': handle});
  }

  Future<T> _receive(String operation, T Function(Object?) decode, bool decodeInReceiver) async {
    String? handle;
    ReceivePort? port;
    SendPort? credits;
    try {
      handle = await _handle;
      final receiver = ReceivePort();
      port = receiver;
      await Isolate.spawn(
        _nativeReceiver, (_library, handle, receiver.sendPort, operation,
          decodeInReceiver ? decode : null),
        onError: receiver.sendPort, onExit: receiver.sendPort,
      );
      await for (final message in receiver) {
        if (message is SendPort) {
          credits = message;
          continue;
        }
        if (message is List && message.length == 2 && message.first == 'decoded') {
          return message[1] as T;
        }
        if (message is List && message.length == 2 && message.first == 'nativeError') {
          throw message[1] as Object;
        }
        if (message is! Map<String, dynamic>) {
          throw ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation,
              'Native receiver exited without a terminal result: $message');
        }
        try {
          switch (message['kind']) {
            case 'progress':
              _progress.add(ArchiveProgress.fromJson(message['value']));
              credits?.send(true);
              break;
            case 'terminal':
              final terminal = ArchiveNativeBindings.unwrap(operation, message['result']);
              return decode(terminal);
            default:
              throw const FormatException('Unknown native operation event');
          }
        } on ArchiveException {
          rethrow;
        } on ArchiveBridgeException {
          rethrow;
        } catch (error) {
          throw ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation, error.toString());
        }
      }
      throw ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation, 'Missing terminal event');
    } finally {
      credits?.send(false);
      port?.close();
      try {
        if (handle != null) await callArchiveNative(_library, 'operation_close', {'handle': handle});
      } finally {
        _done = true;
        // Paused/absent subscribers must not keep native resources alive.
        unawaited(_progress.close());
      }
    }
  }
}

ArchiveOperation<T> startArchiveOperation<T>(
    String? library, String operation, Map<String, Object?>? input, T Function(Object?) decode,
    {bool decodeInReceiver = false}) =>
    ArchiveOperation._(library, _start(library, operation, input), operation, decode, decodeInReceiver);
