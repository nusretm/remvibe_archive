import 'dart:io';

import 'models.dart';
import 'operation.dart';
import 'read_operation.dart';

/// One native library configuration per process. Native Assets is default.
/// An explicit path is useful for diagnostic runs in a separate process.
class ArchiveService {
  static final ArchiveService instance = ArchiveService._(null);
  final String? _libraryPath;
  ArchiveService._(this._libraryPath);

  factory ArchiveService.withLibrary(String path) {
    if (path.isEmpty || !File(path).isAbsolute) {
      throw ArgumentError.value(path, 'path', 'Expected absolute native library path');
    }
    return ArchiveService._(path);
  }

  /// Inspect the actual root Core defaults via the native operation substrate.
  ArchiveOperation<ArchiveCoreInfo> coreInfo() =>
      startArchiveOperation(_libraryPath, 'core_info', null, ArchiveCoreInfo.fromJson);

  /// Creates unpublished sibling staging using the Rust Core. Always close
  /// the returned writer (including after finish/abort).
  ArchiveOperation<ArchiveWriter> createWriter(
    ArchiveNativePath destination, {
    ArchiveWriterOptions options = const ArchiveWriterOptions(),
  }) => startArchiveOperation(
    _libraryPath, 'writer_create',
    {'destination': destination.toJson(), 'options': options.toJson()},
    (value) => ArchiveWriter._(_libraryPath, archiveHandle(value, 'writer_create')),
  );

  /// Open and validate the manifest. Payload integrity requires verify or read.
  /// The caller must keep the source immutable for the lifetime of the Reader.
  ArchiveOperation<ArchiveReader> openReader(
    ArchiveNativePath path, {
    ArchiveSource source = const ArchiveSource.single(),
    ArchiveReaderOptions options = const ArchiveReaderOptions(),
  }) => startArchiveOperation(
    _libraryPath, 'reader_open',
    {'path': path.toJson(), 'source': source.toJson(), 'options': options.toJson()},
    (value) => ArchiveReader._(_libraryPath, archiveHandle(value, 'reader_open'),
        ArchiveRegion.fromJson(jsonObject(value)['region']),
        BigInt.parse(jsonObject(value)['entryCount'] as String)),
  );
}

/// One Core writer, one active command. Independent writers may run together.
/// A failed/cancelled Core add invalidates the unpublished archive. finish and
/// abort consume it; close always releases the native handle.
class ArchiveWriter {
  final String? _library;
  final String _handle;
  ArchiveOperation<dynamic>? _active;
  bool _sealed = false;
  bool _closing = false;
  Future<void>? _closeFuture;
  ArchiveWriter._(this._library, this._handle);

  ArchiveOperation<T> _start<T>(
      String operation, Map<String, Object?> fields, T Function(Object?) decode) {
    if (_closing || _sealed) {
      throw ArchiveException.fromJson({
        'kind': 'closed', 'operation': operation, 'message': 'Archive writer is closed',
      });
    }
    if (_active?.isRunning == true) {
      throw const ArchiveBridgeException(ArchiveBridgeErrorKind.busy, 'writer', 'Writer already has an active operation');
    }
    final active = startArchiveOperation<T>(
        _library, operation, {'handle': _handle, ...fields}, decode);
    _active = active;
    return active;
  }

  ArchiveOperation<void> addFile({
    required ArchiveNativePath source,
    required ArchivePath path,
    ArchiveCompression? compression,
  }) => _start<void>('writer_add_file', {
    'source': source.toJson(), 'path': path.toJson(),
    if (compression != null) 'compression': compression.name,
  }, (_) {});

  ArchiveOperation<void> addDirectory({
    required ArchiveNativePath source,
    required ArchivePath path,
    bool recursive = true,
  }) => _start<void>('writer_add_directory', {
    'source': source.toJson(), 'path': path.toJson(), 'recursive': recursive,
  }, (_) {});

  ArchiveOperation<ArchiveWriterResult> finish() {
    final operation = _start('writer_finish', {}, ArchiveWriterResult.fromJson);
    _sealed = true;
    return operation;
  }

  ArchiveOperation<void> abort() {
    final operation = _start<void>('writer_abort', {}, (_) {});
    _sealed = true;
    return operation;
  }

  /// Cancels and awaits any active command before explicitly discarding
  /// staging. A cleanup failure is never treated as a successful close.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    final active = _active;
    try {
      if (active != null && active.isRunning) {
        // Attach the terminal result listener immediately, before the
        // cancellation request can complete or fail.
        final wait = active.result.then<void>((_) {}, onError: (Object error, StackTrace stack) {
          if (error is ArchiveException && error.kind != ArchiveErrorKind.cleanup) return;
          Error.throwWithStackTrace(error, stack);
        });
        await Future.wait<void>([wait, active.cancel()]);
      }
    } finally {
      await callArchiveNative(_library, 'writer_close', {'handle': _handle});
    }
  }
}


/// Owns one validated Core reader. Commands are serialized per handle;
/// cancellation is one-way: close and reopen before further work.
class ArchiveReader {
  final String? _library;
  final String _handle;
  final ArchiveRegion region;
  final BigInt entryCount;
  ArchiveActiveOperation? _active;
  bool _closing = false;
  Future<void>? _closeFuture;
  ArchiveReader._(this._library, this._handle, this.region, this.entryCount);

  ArchiveOperation<T> _start<T>(String operation, Map<String, Object?> fields,
      T Function(Object?) decode, {bool decodeInReceiver = false}) {
    if (_closing) {
      throw ArchiveException.fromJson({
        'kind': 'closed', 'operation': operation, 'message': 'Archive reader is closed',
      });
    }
    if (_active?.isRunning == true) {
      throw const ArchiveBridgeException(ArchiveBridgeErrorKind.busy, 'reader', 'Reader already has an active operation');
    }
    final active = startArchiveOperation<T>(_library, operation, {'handle': _handle, ...fields}, decode,
        decodeInReceiver: decodeInReceiver);
    _active = active;
    return active;
  }

  /// Typed, immutable snapshot of the validated manifest. No payload reads.
  ArchiveOperation<ArchiveManifest> manifest() =>
      _start('reader_manifest', {}, ArchiveManifest.fromJson, decodeInReceiver: true);

  /// Verify all payload lengths and SHA-256 without writing output.
  ArchiveOperation<ArchiveReadResult> verify() =>
      _start('reader_verify', {}, ArchiveReadResult.fromJson);

  /// Extract into an absent directory, without merge/overwrite.
  ArchiveOperation<ArchiveExtractResult> extractTo(ArchiveNativePath destination, {
    ArchiveExtractOptions options = const ArchiveExtractOptions(),
  }) => _start('reader_extract', {'destination': destination.toJson(), 'options': options.toJson()},
      ArchiveExtractResult.fromJson, decodeInReceiver: true);

  /// Extract one regular file to an explicit absent filename.
  ArchiveOperation<ArchiveExtractResult> extractEntryTo(BigInt index, ArchiveNativePath destination, {
    ArchiveExtractOptions options = const ArchiveExtractOptions(),
  }) => _start('reader_extract', {'index': index.toString(),
      'destination': destination.toJson(), 'options': options.toJson()},
      ArchiveExtractResult.fromJson, decodeInReceiver: true);

  /// Read one regular file without extracting it. Single-subscription
  /// binary chunks remain provisional until result verifies the SHA-256.
  ArchiveReadOperation readEntry(BigInt index) {
    if (_closing) {
      throw ArchiveException.fromJson({
        'kind': 'closed', 'operation': 'reader_read_entry', 'message': 'Archive reader is closed',
      });
    }
    if (_active?.isRunning == true) {
      throw const ArchiveBridgeException(ArchiveBridgeErrorKind.busy, 'reader', 'Reader already has an active operation');
    }
    final active = startArchiveRead(_library, _handle, index);
    _active = active;
    return active;
  }

  /// Cancel/await active work, then release the source and native handle.
  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closing = true;
    final active = _active;
    try {
      if (active != null && active.isRunning) {
        final wait = active.result.then<void>((_) {}, onError: (Object error, StackTrace stack) {
          if (error is ArchiveException && error.kind != ArchiveErrorKind.cleanup) return;
          Error.throwWithStackTrace(error, stack);
        });
        await Future.wait<void>([wait, active.cancel()]);
      }
    } finally {
      await callArchiveNative(_library, 'reader_close', {'handle': _handle});
    }
  }
}
