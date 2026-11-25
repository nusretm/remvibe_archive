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
}
