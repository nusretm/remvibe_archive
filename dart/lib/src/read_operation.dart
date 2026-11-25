import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'models.dart';
import 'native/bindings.dart';
import 'operation.dart';

/// Receiver requests one native frame per Dart credit. No payload queue or
/// long-lived native pointer. TransferableTypedData owns the copy in transit.
Future<void> _streamReceiver((String?, String, SendPort) args) async {
  final (library, handle, output) = args;
  final requests = ReceivePort();
  output.send(requests.sendPort);
  try {
    final bindings = ArchiveNativeBindings.load(library);
    await for (final request in requests) {
      if (request != true) break;
      final frame = bindings.streamReceive(handle);
      if (frame is Uint8List) {
        output.send(TransferableTypedData.fromList([frame]));
      } else {
        final event = jsonObject(frame);
        output.send(event);
        if (event['kind'] == 'terminal') break;
      }
    }
  } catch (error) {
    output.send(['nativeError', error]);
  } finally {
    requests.close();
  }
}

/// Single-subscription, bounded, provisional binary entry stream.
/// Listen to stream (or cancel); awaiting result alone does not consume it.
/// Every chunk is provisional until result succeeds. On error/cancel the
/// stream closes; result carries the authoritative typed error. Always await
/// result, including after early subscription cancellation. Pause/resume
/// applies backpressure; cancelling the subscription requests native cancel.
/// Consumer-retained chunks and a paused progress subscriber are caller-owned.
class ArchiveReadOperation implements ArchiveActiveOperation {
  final String? _library;
  final Future<String> _handle;
  final _progress = StreamController<ArchiveProgress>.broadcast();
  late final StreamController<Uint8List> _data;
  @override
  late final Future<ArchiveReadResult> result;
  bool _listening = false;
  bool _paused = false;
  bool _stopping = false;
  bool _done = false;
  Completer<void>? _wake;
  Future<void>? _cancelFuture;

  ArchiveReadOperation._(this._library, this._handle) {
    _data = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        _listening = true;
        _signal();
      },
      onPause: () { _paused = true; },
      onResume: () {
        _paused = false;
        _signal();
      },
      onCancel: () {
        _listening = false;
        return cancel();
      },
    );
    result = _receive();
    // A consumer often awaits result after the data stream closes. Keep
    // the original error future observable without an early unhandled error.
    unawaited(result.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  Stream<Uint8List> get stream => _data.stream;
  Stream<ArchiveProgress> get progress => _progress.stream;
  @override
  bool get isRunning => !_done;

  void _signal() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<void> _waitForConsumer() async {
    while (!_stopping && (!_listening || _paused)) {
      final wake = _wake ??= Completer<void>();
      await wake.future;
    }
    if (_stopping) await _cancelFuture!;
  }

  @override
  Future<void> cancel() {
    if (_done) return Future<void>.value();
    if (_cancelFuture != null) return _cancelFuture!;
    _stopping = true;
    final request = _requestCancel();
    _cancelFuture = request;
    _signal();
    return request;
  }

  Future<void> _requestCancel() async {
    final handle = await _handle;
    if (!_done) {
      await callArchiveNative(_library, 'operation_cancel', {'handle': handle});
    }
  }

  Future<ArchiveReadResult> _receive() async {
    const operation = 'reader_read_entry';
    String? handle;
    ReceivePort? port;
    SendPort? requests;
    try {
      handle = await _handle;
      final receiver = ReceivePort();
      port = receiver;
      await Isolate.spawn(_streamReceiver, (_library, handle, receiver.sendPort),
          onError: receiver.sendPort, onExit: receiver.sendPort);
      await for (final message in receiver) {
        if (message is SendPort) {
          requests = message;
          if (_stopping) await _cancelFuture!;
          // At most one frame may arrive before a listener attaches.
          requests.send(true);
          continue;
        }
        if (message is TransferableTypedData) {
          // Do not send the next request (which acknowledges this chunk)
          // until an active subscriber has synchronously received it and
          // has not paused. Cancellation bypasses the gate after the native
          // request is sent, discarding any undelivered frame.
          await _waitForConsumer();
          if (!_stopping) {
            final chunk = message.materialize().asUint8List();
            _data.add(chunk);
          }
          await _waitForConsumer();
          requests!.send(true);
          continue;
        }
        if (message is List && message.length == 2 && message.first == 'nativeError') {
          throw message[1] as Object;
        }
        if (message is! Map<String, dynamic>) {
          throw ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation,
              'Native stream receiver exited without terminal result: $message');
        }
        try {
          switch (message['kind']) {
            case 'progress':
              _progress.add(ArchiveProgress.fromJson(message['value']));
              if (_stopping) await _cancelFuture!;
              requests!.send(true);
              break;
            case 'terminal':
              final value = ArchiveNativeBindings.unwrap(operation, message['result']);
              return ArchiveReadResult.fromJson(value);
            default:
              throw const FormatException('Unknown native stream event');
          }
        } on ArchiveException {
          rethrow;
        } on ArchiveBridgeException {
          rethrow;
        } catch (error) {
          throw ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation, error.toString());
        }
      }
      throw const ArchiveBridgeException(ArchiveBridgeErrorKind.invalidResponse, operation, 'Missing terminal event');
    } finally {
      requests?.send(false);
      port?.close();
      try {
        if (handle != null) {
          await callArchiveNative(_library, 'operation_close', {'handle': handle});
        }
      } finally {
        _done = true;
        _signal();
        // A paused/absent subscriber must not hold the native operation open.
        unawaited(_data.close());
        unawaited(_progress.close());
      }
    }
  }
}

Future<String> _startRead(String? library, String reader, BigInt index) async =>
    archiveHandle(await callArchiveNative(library, 'reader_read_entry',
        {'handle': reader, 'index': index.toString()}), 'reader_read_entry');

ArchiveReadOperation startArchiveRead(String? library, String reader, BigInt index) =>
    ArchiveReadOperation._(library, _startRead(library, reader, index));
