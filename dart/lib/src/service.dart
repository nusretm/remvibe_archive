import 'dart:io';

import 'models.dart';
import 'operation.dart';

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
    if (_closing || _sealed) throw StateError('Archive writer is closed');
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
      if (active?.isRunning == true) {
        try {
          await active!.cancel();
        } finally {
          try {
            await active!.result;
          } on ArchiveException catch (error) {
            // The original command owns its other errors; cleanup is also
            // relevant to the caller awaiting close.
            if (error.kind == ArchiveErrorKind.cleanup) rethrow;
          }
        }
      }
    } finally {
      await callArchiveNative(_library, 'writer_close', {'handle': _handle});
    }
  }
}
