import 'dart:convert' as convert;
import 'dart:io';

enum ArchiveNativeEncoding { windowsUtf16, unixBytes }

Map<String, dynamic> jsonObject(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected JSON object');
  }
  return value;
}

class ArchiveNativePath {
  final ArchiveNativeEncoding encoding;
  final List<int> units;

  ArchiveNativePath(this.encoding, Iterable<int> units)
      : units = List.unmodifiable(units) {
    final max = encoding == ArchiveNativeEncoding.windowsUtf16 ? 65535 : 255;
    if (this.units.isEmpty || this.units.any((n) => n <= 0 || n > max)) {
      throw ArgumentError('Invalid native path units');
    }
  }

  factory ArchiveNativePath.fromString(String path) {
    if (Platform.isWindows) {
      return ArchiveNativePath(ArchiveNativeEncoding.windowsUtf16, path.codeUnits);
    }
    final bytes = convert.utf8.encode(path);
    if (convert.utf8.decode(bytes) != path) {
      throw ArgumentError('Invalid Unicode path; pass raw Unix byte units explicitly');
    }
    return ArchiveNativePath(ArchiveNativeEncoding.unixBytes, bytes);
  }

  factory ArchiveNativePath.fromJson(Object? value) {
    final data = jsonObject(value);
    return ArchiveNativePath(
      ArchiveNativeEncoding.values.byName(data['encoding'] as String),
      (data['units'] as List).cast<int>(),
    );
  }

  Map<String, Object> toJson() => {'encoding': encoding.name, 'units': units};

  /// For display only; always use the original units for native operations.
  String get displayPath => encoding == ArchiveNativeEncoding.windowsUtf16
      ? String.fromCharCodes(units)
      : convert.utf8.decode(units, allowMalformed: true);
}

enum ArchiveCompression { none, zlib, zstd }
enum ExtractionSync { buffered, perFile }
enum ArchiveMetadataCapture { basic, full }

class ArchiveCoreInfo {
  final int formatVersion;
  final ArchiveCompression compression;
  final ArchiveCompression manifestCompression;
  final int zstdLevel;
  final int zlibLevel;
  final String layout;
  final ArchiveMetadataCapture metadataCapture;
  final ExtractionSync extractionSync;
  final BigInt writerBufferSize;
  final BigInt readerBufferSize;
  final BigInt maxManifestBytes;
  final BigInt maxTotalBytes;

  ArchiveCoreInfo.fromJson(Object? value)
      : this._decode(jsonObject(value));

  ArchiveCoreInfo._decode(Map<String, dynamic> v)
      : formatVersion = v['formatVersion'] as int,
        compression = ArchiveCompression.values.byName(v['compression'] as String),
        manifestCompression = ArchiveCompression.values.byName(v['manifestCompression'] as String),
        zstdLevel = v['zstdLevel'] as int,
        zlibLevel = v['zlibLevel'] as int,
        layout = v['layout'] as String,
        metadataCapture = ArchiveMetadataCapture.values.byName(v['metadataCapture'] as String),
        extractionSync = ExtractionSync.values.byName(v['extractionSync'] as String),
        writerBufferSize = BigInt.parse(v['writerBufferSize'] as String),
        readerBufferSize = BigInt.parse(v['readerBufferSize'] as String),
        maxManifestBytes = BigInt.parse(v['maxManifestBytes'] as String),
        maxTotalBytes = BigInt.parse(v['maxTotalBytes'] as String);
}


enum ArchivePathEncoding { utf8, unixBytes, windowsUtf16 }

/// RVA wire path component. Raw units use canonical base64; Windows units
/// are encoded little-endian, independent of the current host byte order.
class ArchivePathComponent {
  final ArchivePathEncoding encoding;
  final String value;
  const ArchivePathComponent._(this.encoding, this.value);

  factory ArchivePathComponent.utf8(String value) {
    if (convert.utf8.decode(convert.utf8.encode(value)) != value ||
        value.isEmpty || value == '.' || value == '..' ||
        value.contains('/') || value.contains('\u0000')) {
      throw ArgumentError.value(value, 'value', 'Invalid Unicode archive component');
    }
    return ArchivePathComponent._(ArchivePathEncoding.utf8, value);
  }
  factory ArchivePathComponent.unixBytes(Iterable<int> units) {
    final bytes = units.toList(growable: false);
    if (bytes.isEmpty || bytes.any((n) => n <= 0 || n > 255 || n == 47)) {
      throw ArgumentError('Invalid Unix archive component units');
    }
    return ArchivePathComponent._(ArchivePathEncoding.unixBytes, convert.base64.encode(bytes));
  }
  factory ArchivePathComponent.windowsUtf16(Iterable<int> units) {
    final bytes = <int>[];
    for (final n in units) {
      if (n <= 0 || n > 65535 || n == 47 || n == 92 || n == 58) {
        throw ArgumentError('Invalid Windows archive component units');
      }
      bytes.addAll([n & 255, n >> 8]);
    }
    if (bytes.isEmpty) throw ArgumentError('Empty Windows archive component');
    return ArchivePathComponent._(ArchivePathEncoding.windowsUtf16, convert.base64.encode(bytes));
  }
  factory ArchivePathComponent.fromJson(Object? value) {
    final map = jsonObject(value);
    return ArchivePathComponent._(
      ArchivePathEncoding.values.byName(map['encoding'] as String),
      map['value'] as String,
    );
  }
  Map<String, Object> toJson() => {'encoding': encoding.name, 'value': value};
}

/// Relative archive path, not a native absolute path. No traversal normalization.
/// Rust Core remains the authority for canonical encoding and path validation.
class ArchivePath {
  final List<ArchivePathComponent> components;
  ArchivePath(Iterable<ArchivePathComponent> components)
      : components = List.unmodifiable(components) {
    if (this.components.isEmpty) throw ArgumentError('Empty archive path');
  }
  factory ArchivePath.fromString(String path) =>
      ArchivePath(path.split('/').map(ArchivePathComponent.utf8));
  factory ArchivePath.fromJson(Object? value) =>
      ArchivePath((value as List).map(ArchivePathComponent.fromJson));
  List<Map<String, Object>> toJson() =>
      components.map((component) => component.toJson()).toList(growable: false);
}

enum ArchiveLayoutKind { single, split }
class ArchiveLayout {
  final ArchiveLayoutKind kind;
  final BigInt? maxPartSize;
  const ArchiveLayout.single() : kind = ArchiveLayoutKind.single, maxPartSize = null;
  ArchiveLayout.split(BigInt maxPartSize)
      : kind = ArchiveLayoutKind.split, maxPartSize = maxPartSize;
  Map<String, Object> toJson() => {
    'kind': kind.name,
    if (maxPartSize != null) 'maxPartSize': maxPartSize.toString(),
  };
}

/// Unspecified limits retain the Rust Core defaults.
class ArchiveManifestLimits {
  final BigInt? maxManifestBytes, maxEntries, maxDepth, maxFileBytes, maxTotalBytes;
  const ArchiveManifestLimits({
    this.maxManifestBytes, this.maxEntries, this.maxDepth,
    this.maxFileBytes, this.maxTotalBytes,
  });
  Map<String, Object> toJson() => {
    if (maxManifestBytes != null) 'maxManifestBytes': maxManifestBytes.toString(),
    if (maxEntries != null) 'maxEntries': maxEntries.toString(),
    if (maxDepth != null) 'maxDepth': maxDepth.toString(),
    if (maxFileBytes != null) 'maxFileBytes': maxFileBytes.toString(),
    if (maxTotalBytes != null) 'maxTotalBytes': maxTotalBytes.toString(),
  };
}

class ArchiveWriterOptions {
  final ArchiveLayout layout;
  final ArchiveCompression compression, manifestCompression;
  final int zlibLevel, zstdLevel;
  final BigInt? bufferSize;
  final ArchiveMetadataCapture metadataCapture;
  final ArchiveManifestLimits limits;
  const ArchiveWriterOptions({
    this.layout = const ArchiveLayout.single(),
    this.compression = ArchiveCompression.zstd,
    this.manifestCompression = ArchiveCompression.zstd,
    this.zlibLevel = 6,
    this.zstdLevel = 3,
    this.bufferSize,
    this.metadataCapture = ArchiveMetadataCapture.basic,
    this.limits = const ArchiveManifestLimits(),
  });
  Map<String, Object> toJson() => {
    'layout': layout.toJson(), 'compression': compression.name,
    'manifestCompression': manifestCompression.name,
    'zlibLevel': zlibLevel, 'zstdLevel': zstdLevel,
    if (bufferSize != null) 'bufferSize': bufferSize.toString(),
    'metadataCapture': metadataCapture.name, 'limits': limits.toJson(),
  };
}

enum ArchiveProgressPhase { preparing, writing, entryCompleted, finalizing, completed }

/// Actual Core counters, cumulative across the writer session.
/// Whole-archive total is intentionally unknown until finish.
class ArchiveProgress {
  final ArchiveProgressPhase phase;
  final ArchivePath? path;
  final BigInt entriesCompleted, sourceBytesRead, entryBytesRead;
  final BigInt? entryTotalBytes;
  ArchiveProgress.fromJson(Object? value) : this._decode(jsonObject(value));
  ArchiveProgress._decode(Map<String, dynamic> v)
      : phase = ArchiveProgressPhase.values.byName(v['phase'] as String),
        path = v['path'] == null ? null : ArchivePath.fromJson(v['path']),
        entriesCompleted = BigInt.parse(v['entriesCompleted'] as String),
        sourceBytesRead = BigInt.parse(v['sourceBytesRead'] as String),
        entryBytesRead = BigInt.parse(v['entryBytesRead'] as String),
        entryTotalBytes = v['entryTotalBytes'] == null ? null :
            BigInt.parse(v['entryTotalBytes'] as String);
}

class ArchiveWriterResult {
  final ArchiveNativePath path;
  final BigInt entryCount, sourceBytes, archiveBytes, partCount, physicalBytes;
  ArchiveWriterResult.fromJson(Object? value) : this._decode(jsonObject(value));
  ArchiveWriterResult._decode(Map<String, dynamic> v)
      : path = ArchiveNativePath.fromJson(v['path']),
        entryCount = BigInt.parse(v['entryCount'] as String),
        sourceBytes = BigInt.parse(v['sourceBytes'] as String),
        archiveBytes = BigInt.parse(v['archiveBytes'] as String),
        partCount = BigInt.parse(v['partCount'] as String),
        physicalBytes = BigInt.parse(v['physicalBytes'] as String);
}

enum ArchiveBridgeErrorKind {
  loadFailed, incompatibleAbi, invalidInput, invalidHandle,
  panic, invalidResponse, workerFailed, busy,
}

class ArchiveBridgeException implements Exception {
  final ArchiveBridgeErrorKind kind;
  final String operation;
  final String message;
  const ArchiveBridgeException(this.kind, this.operation, this.message);
  @override
  String toString() => 'ArchiveBridgeException(${kind.name}, $operation): $message';
}

enum ArchiveErrorKind {
  io, fileSystem, path, manifest, invalid, unsupported, sourceChanged,
  destinationExists, cancelled, closed, cleanup,
}

enum ArchiveFileSystemErrorKind {
  notFound, alreadyExists, permissionDenied, invalidPath, invalidLocation,
  notDirectory, notFile, destinationConflict, sameLocation,
  descendantDestination, directoryNotEmpty, homeUnavailable,
  watchUnavailable, unsupported, ioError, partialOperation, metadataFailed,
}

class ArchiveFileSystemError {
  final ArchiveFileSystemErrorKind kind;
  final String operation, message;
  final ArchiveNativePath? path;
  final int? osCode;
  ArchiveFileSystemError.fromJson(Map<String, dynamic> v)
      : kind = ArchiveFileSystemErrorKind.values.byName(v['kind'] as String),
        operation = v['operation'] as String, message = v['message'] as String,
        path = v['path'] == null ? null : ArchiveNativePath.fromJson(v['path']),
        osCode = v['osCode'] as int?;
}

/// Typed Core error including native path, OS error, nested filesystem error
/// or original error when Core could not discard staging.
class ArchiveException implements Exception {
  final ArchiveErrorKind kind;
  final String operation, message;
  final ArchiveNativePath? path;
  final int? osCode;
  final String? ioKind, reason;
  final ArchiveFileSystemError? fileSystem;
  final ArchiveException? original;
  final Map<String, dynamic> details;
  ArchiveException.fromJson(Map<String, dynamic> data)
      : kind = ArchiveErrorKind.values.byName(data['kind'] as String),
        operation = data['operation'] as String,
        message = data['message'] as String,
        path = data['path'] == null ? null : ArchiveNativePath.fromJson(data['path']),
        osCode = data['osCode'] as int?,
        ioKind = data['ioKind'] as String?,
        reason = data['reason'] as String?,
        fileSystem = data['fileSystem'] == null ? null :
            ArchiveFileSystemError.fromJson(jsonObject(data['fileSystem'])),
        original = data['original'] == null ? null :
            ArchiveException.fromJson(jsonObject(data['original'])),
        details = Map.unmodifiable(data);
  @override
  String toString() => 'ArchiveException(${kind.name}, $operation): $message';
}
