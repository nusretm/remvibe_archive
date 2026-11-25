import 'dart:convert';
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

  factory ArchiveNativePath.fromString(String path) => Platform.isWindows
      ? ArchiveNativePath(ArchiveNativeEncoding.windowsUtf16, path.codeUnits)
      : ArchiveNativePath(ArchiveNativeEncoding.unixBytes, utf8.encode(path));

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
      : utf8.decode(units, allowMalformed: true);
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

/// A only establishes the operation contract; archive progress arrives in B/C.
class ArchiveProgress {
  final String phase;
  const ArchiveProgress(this.phase);
}

enum ArchiveBridgeErrorKind {
  loadFailed, incompatibleAbi, invalidInput, invalidHandle,
  panic, invalidResponse, workerFailed,
}

class ArchiveBridgeException implements Exception {
  final ArchiveBridgeErrorKind kind;
  final String operation;
  final String message;
  const ArchiveBridgeException(this.kind, this.operation, this.message);
  @override
  String toString() => 'ArchiveBridgeException(${kind.name}, $operation): $message';
}

/// Core-domain error. Functional variants and structured details arrive in B/C.
class ArchiveException implements Exception {
  final String kind;
  final String operation;
  final String message;
  final Map<String, dynamic> details;
  ArchiveException.fromJson(Map<String, dynamic> data)
      : kind = data['kind'] as String,
        operation = data['operation'] as String,
        message = data['message'] as String,
        details = Map.unmodifiable(data);
  @override
  String toString() => 'ArchiveException($kind, $operation): $message';
}
