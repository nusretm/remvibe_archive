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

enum ArchiveProgressPhase { preparing, writing, entryCompleted, finalizing, completed, reading, verifying, extracting, applyingMetadata }

/// Real Core counters. Writer counts are session-cumulative; Reader counts
/// are operation-local. Reader totals are known; Writer totals are not.
class ArchiveProgress {
  final ArchiveProgressPhase phase;
  final ArchivePath? path;
  final BigInt entriesCompleted, entryBytesRead;
  final BigInt? _sourceBytesRead, outputBytes, totalEntries, totalBytes, entryTotalBytes;
  bool get isReader => outputBytes != null;
  BigInt get processedBytes => outputBytes ?? _sourceBytesRead!;
  /// Writer-only cumulative source bytes; use outputBytes for Reader events.
  BigInt get sourceBytesRead => _sourceBytesRead ??
      (throw StateError('Reader progress has outputBytes, not sourceBytesRead'));
  ArchiveProgress.fromJson(Object? value) : this._decode(jsonObject(value));
  ArchiveProgress._decode(Map<String, dynamic> v)
      : phase = ArchiveProgressPhase.values.byName(v['phase'] as String),
        path = v['path'] == null ? null : ArchivePath.fromJson(v['path']),
        entriesCompleted = BigInt.parse(v['entriesCompleted'] as String),
        _sourceBytesRead = v['sourceBytesRead'] == null ? null : BigInt.parse(v['sourceBytesRead'] as String),
        outputBytes = v['outputBytes'] == null ? null : BigInt.parse(v['outputBytes'] as String),
        totalEntries = v['totalEntries'] == null ? null : BigInt.parse(v['totalEntries'] as String),
        totalBytes = v['totalBytes'] == null ? null : BigInt.parse(v['totalBytes'] as String),
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
  format, metadataCodec, entryNotFound, notFile, integrity, collision, metadata,
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
  final BigInt? index;
  final ArchivePath? archivePath;
  final ArchiveMetadataApplyResult? metadataResult;
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
        index = data['index'] == null ? null : BigInt.parse(data['index'] as String),
        archivePath = data['archivePath'] == null ? null : ArchivePath.fromJson(data['archivePath']),
        metadataResult = data['metadataResult'] == null ? null : ArchiveMetadataApplyResult.fromJson(data['metadataResult']),
        details = Map.unmodifiable(data);
  @override
  String toString() => 'ArchiveException(${kind.name}, $operation): $message';
}

// FileSystem-compatible value models (no FileSystem native dependency).
class ArchiveTimestamp {
  final BigInt seconds;
  final int nanoseconds;
  ArchiveTimestamp(this.seconds, this.nanoseconds) {
    if (nanoseconds < 0 || nanoseconds >= 1000000000) {
      throw ArgumentError('Invalid nanoseconds');
    }
  }
  factory ArchiveTimestamp.fromJson(Object? value) {
    final data = jsonObject(value);
    return ArchiveTimestamp(BigInt.parse(data['seconds'] as String),
        data['nanoseconds'] as int);
  }
  Map<String, Object> toJson() => {
    'seconds': seconds.toString(), 'nanoseconds': nanoseconds,
  };

  factory ArchiveTimestamp.fromDateTime(DateTime value) {
    final micros = value.microsecondsSinceEpoch;
    var seconds = micros ~/ 1000000;
    final remainder = micros % 1000000;
    if (micros < 0 && remainder != 0) seconds--;
    return ArchiveTimestamp(BigInt.from(seconds), remainder * 1000);
  }

  /// A display conversion; the exact timestamp remains in seconds/nanoseconds.
  DateTime? get utcDateTime {
    final micros = seconds * BigInt.from(1000000) + BigInt.from(nanoseconds ~/ 1000);
    final limit = BigInt.parse('8640000000000000000');
    if (micros < -limit || micros > limit) return null;
    return DateTime.fromMicrosecondsSinceEpoch(micros.toInt(), isUtc: true);
  }
}

sealed class ArchivePermissions {
  const ArchivePermissions();
  Map<String, Object?> toJson();
  factory ArchivePermissions.fromJson(Object? value) {
    final data = jsonObject(value);
    return switch (data['kind']) {
      'unix' => ArchiveUnixPermissions(data['mode'] as int, data['uid'] as int, data['gid'] as int),
      'windows' => ArchiveWindowsPermissions(
        ownerSid: data['ownerSid'] as String?,
        groupSid: data['groupSid'] as String?,
        dacl: ArchiveWindowsDacl.fromJson(data['dacl']),
        inheritanceEnabled: data['inheritanceEnabled'] as bool,
      ),
      _ => throw FormatException('Unknown permission model'),
    };
  }
}

final class ArchiveUnixPermissions extends ArchivePermissions {
  final int mode, uid, gid;
  const ArchiveUnixPermissions(this.mode, this.uid, this.gid);
  @override
  Map<String, Object> toJson() => {
    'kind': 'unix', 'mode': mode, 'uid': uid, 'gid': gid,
  };
}

final class ArchiveWindowsPermissions extends ArchivePermissions {
  final String? ownerSid, groupSid;
  final ArchiveWindowsDacl dacl;
  final bool inheritanceEnabled;
  const ArchiveWindowsPermissions({required this.ownerSid, required this.groupSid,
      required this.dacl, required this.inheritanceEnabled});
  @override
  Map<String, Object?> toJson() => {
    'kind': 'windows', 'ownerSid': ownerSid, 'groupSid': groupSid,
    'dacl': dacl.toJson(), 'inheritanceEnabled': inheritanceEnabled,
  };
}

enum ArchiveWindowsDaclKind { absent, nullDacl, entries }

class ArchiveWindowsDacl {
  final ArchiveWindowsDaclKind kind;
  final int? revision;
  final List<ArchiveWindowsAce> entries;
  ArchiveWindowsDacl._(this.kind, this.revision, Iterable<ArchiveWindowsAce> entries)
      : entries = List.unmodifiable(entries);
  factory ArchiveWindowsDacl.absent() => ArchiveWindowsDacl._(ArchiveWindowsDaclKind.absent, null, []);
  factory ArchiveWindowsDacl.nullDacl() => ArchiveWindowsDacl._(ArchiveWindowsDaclKind.nullDacl, null, []);
  factory ArchiveWindowsDacl.entries(int revision, Iterable<ArchiveWindowsAce> entries) =>
      ArchiveWindowsDacl._(ArchiveWindowsDaclKind.entries, revision, entries);

  Map<String, Object> toJson() => switch (kind) {
    ArchiveWindowsDaclKind.absent => {'kind': 'absent'},
    ArchiveWindowsDaclKind.nullDacl => {'kind': 'null'},
    ArchiveWindowsDaclKind.entries => {'kind': 'entries', 'revision': revision!,
        'entries': entries.map((ace) => ace.toJson()).toList()},
  };

  factory ArchiveWindowsDacl.fromJson(Object? value) {
    final data = jsonObject(value);
    return switch (data['kind']) {
      'absent' => ArchiveWindowsDacl._(ArchiveWindowsDaclKind.absent, null, []),
      'null' => ArchiveWindowsDacl._(ArchiveWindowsDaclKind.nullDacl, null, []),
      'entries' => ArchiveWindowsDacl._(ArchiveWindowsDaclKind.entries, data['revision'] as int,
          (data['entries'] as List).map(ArchiveWindowsAce.fromJson)),
      _ => throw FormatException('Unknown DACL kind'),
    };
  }
}

enum ArchiveWindowsAccessType { allow, deny }

sealed class ArchiveWindowsAce {
  const ArchiveWindowsAce();
  Map<String, Object> toJson();
  factory ArchiveWindowsAce.fromJson(Object? value) {
    final data = jsonObject(value);
    return switch (data['kind']) {
      'access' => ArchiveWindowsAccessAce(data['sid'] as String, data['accessMask'] as int,
          ArchiveWindowsAccessType.values.byName(data['accessType'] as String), data['flags'] as int),
      'opaque' => ArchiveWindowsOpaqueAce((data['bytes'] as List).cast<int>()),
      _ => throw FormatException('Unknown ACE kind'),
    };
  }
}

final class ArchiveWindowsAccessAce extends ArchiveWindowsAce {
  final String sid;
  final int accessMask, flags;
  final ArchiveWindowsAccessType accessType;
  const ArchiveWindowsAccessAce(this.sid, this.accessMask, this.accessType, this.flags);
  @override
  Map<String, Object> toJson() => {
    'kind': 'access', 'sid': sid, 'accessMask': accessMask,
    'accessType': accessType.name, 'flags': flags,
  };
}

final class ArchiveWindowsOpaqueAce extends ArchiveWindowsAce {
  final List<int> bytes;
  ArchiveWindowsOpaqueAce(Iterable<int> bytes)
      : bytes = List.unmodifiable(bytes);
  @override
  Map<String, Object> toJson() => {'kind': 'opaque', 'bytes': bytes};
}

class ArchiveAttributes {
  final bool? readonly;
  final int? windows;
  const ArchiveAttributes(this.readonly, this.windows);
  Map<String, Object?> toJson() => {'readonly': readonly, 'windows': windows};
  factory ArchiveAttributes.fromJson(Object? value) {
    final data = jsonObject(value);
    return ArchiveAttributes(data['readonly'] as bool?, data['windows'] as int?);
  }
}

class ArchiveMetadata {
  final BigInt? size;
  final ArchiveTimestamp? createdAt, modifiedAt, accessedAt;
  final ArchivePermissions? permissions;
  final ArchiveAttributes attributes;
  const ArchiveMetadata({required this.size, required this.createdAt,
    required this.modifiedAt, required this.accessedAt, required this.permissions,
    required this.attributes});

  Map<String, Object?> toJson() => {
    'size': size?.toString(), 'createdAt': createdAt?.toJson(),
    'modifiedAt': modifiedAt?.toJson(), 'accessedAt': accessedAt?.toJson(),
    'permissions': permissions?.toJson(), 'attributes': attributes.toJson(),
  };

  factory ArchiveMetadata.fromJson(Object? value) {
    final data = jsonObject(value);
    ArchiveTimestamp? time(String key) => data[key] == null
        ? null : ArchiveTimestamp.fromJson(data[key]);
    return ArchiveMetadata(
      size: data['size'] == null ? null : BigInt.parse(data['size'] as String),
      createdAt: time('createdAt'), modifiedAt: time('modifiedAt'),
      accessedAt: time('accessedAt'),
      permissions: data['permissions'] == null ? null
          : ArchivePermissions.fromJson(data['permissions']),
      attributes: ArchiveAttributes.fromJson(data['attributes']),
    );
  }
}

enum ArchiveMetadataRequirement { ignore, ifSupported, bestEffort, required }

class ArchiveMetadataPolicy {
  final ArchiveMetadataRequirement modifiedTime, accessedTime, createdTime, posixMode,
      ownership, windowsAcl, windowsAttributes, readonly;
  final bool allowPrivilegedMode;

  /// Defaults mirror the Rust core ArchiveMetadataPolicy::default().
  const ArchiveMetadataPolicy({
    this.modifiedTime = ArchiveMetadataRequirement.ifSupported,
    this.accessedTime = ArchiveMetadataRequirement.ignore,
    this.createdTime = ArchiveMetadataRequirement.ignore,
    this.posixMode = ArchiveMetadataRequirement.ifSupported,
    this.ownership = ArchiveMetadataRequirement.ignore,
    this.windowsAcl = ArchiveMetadataRequirement.ignore,
    this.windowsAttributes = ArchiveMetadataRequirement.ignore,
    this.readonly = ArchiveMetadataRequirement.ignore,
    this.allowPrivilegedMode = false,
  });

  Map<String, Object> toJson() => {
    'modifiedTime': modifiedTime.name, 'accessedTime': accessedTime.name,
    'createdTime': createdTime.name, 'posixMode': posixMode.name,
    'ownership': ownership.name, 'windowsAcl': windowsAcl.name,
    'windowsAttributes': windowsAttributes.name, 'readonly': readonly.name,
    'allowPrivilegedMode': allowPrivilegedMode,
  };
}

enum ArchiveMetadataField {
  modifiedTime, accessedTime, createdTime, posixMode, ownership, windowsAcl,
  windowsAttributes, readonly,
}

enum ArchiveMetadataApplyStatus { applied, restricted, unavailable, unsupported, failed }

class ArchiveMetadataFieldResult {
  final ArchiveMetadataField field;
  final ArchiveMetadataApplyStatus status;
  final ArchiveFileSystemError? error;
  final bool fatal;

  const ArchiveMetadataFieldResult(this.field, this.status, this.error, this.fatal);

  factory ArchiveMetadataFieldResult.fromJson(Object? value) {
    final data = jsonObject(value);
    return ArchiveMetadataFieldResult(
      ArchiveMetadataField.values.byName(data['field'] as String),
      ArchiveMetadataApplyStatus.values.byName(data['status'] as String),
      data['error'] == null ? null : ArchiveFileSystemError.fromJson(jsonObject(data['error'])),
      data['fatal'] as bool,
    );
  }
}

/// Core's result, including unsuccessful required fields. No implicit rollback.
class ArchiveMetadataApplyResult {
  final bool isSuccess;
  final List<ArchiveMetadataFieldResult> fields;

  ArchiveMetadataApplyResult._(this.isSuccess, Iterable<ArchiveMetadataFieldResult> fields)
      : fields = List.unmodifiable(fields);

  factory ArchiveMetadataApplyResult.fromJson(Object? value) {
    final data = jsonObject(value);
    return ArchiveMetadataApplyResult._(data['isSuccess'] as bool,
        (data['fields'] as List).map(ArchiveMetadataFieldResult.fromJson));
  }
}



enum ArchiveSourceKind { single, split, embedded }
class ArchiveSource {
  final ArchiveSourceKind kind;
  final BigInt? offset, length;
  const ArchiveSource.single() : kind = ArchiveSourceKind.single, offset = null, length = null;
  const ArchiveSource.split() : kind = ArchiveSourceKind.split, offset = null, length = null;
  ArchiveSource.embedded({required BigInt offset, required BigInt length})
      : kind = ArchiveSourceKind.embedded, offset = offset, length = length;
  Map<String, Object> toJson() => {
    'kind': kind.name,
    if (offset != null) 'offset': offset.toString(),
    if (length != null) 'length': length.toString(),
  };
}

class ArchiveReaderOptions {
  final BigInt? bufferSize;
  final ArchiveManifestLimits limits;
  const ArchiveReaderOptions({this.bufferSize, this.limits = const ArchiveManifestLimits()});
  Map<String, Object> toJson() => {
    if (bufferSize != null) 'bufferSize': bufferSize.toString(),
    'limits': limits.toJson(),
  };
}

class ArchiveExtractOptions {
  final ExtractionSync sync;
  /// null explicitly defers metadata application (no field is applied).
  final ArchiveMetadataPolicy? metadataPolicy;
  const ArchiveExtractOptions({
    this.sync = ExtractionSync.buffered,
    this.metadataPolicy = const ArchiveMetadataPolicy(),
  });
  Map<String, Object> toJson() => {
    'sync': sync.name,
    'deferMetadata': metadataPolicy == null,
    if (metadataPolicy != null) 'metadataPolicy': metadataPolicy!.toJson(),
  };
}

class ArchiveRegion {
  final BigInt offset, length;
  ArchiveRegion.fromJson(Object? value) : this._decode(jsonObject(value));
  ArchiveRegion._decode(Map<String, dynamic> v)
      : offset = BigInt.parse(v['offset'] as String),
        length = BigInt.parse(v['length'] as String);
}

enum ArchiveEntryKind { directory, file }

class ArchiveFilePayload {
  final BigInt offset, storedSize, originalSize;
  final ArchiveCompression compression;
  final String sha256;
  ArchiveFilePayload.fromJson(Object? value) : this._decode(jsonObject(value));
  ArchiveFilePayload._decode(Map<String, dynamic> v)
      : offset = BigInt.parse(v['offset'] as String),
        storedSize = BigInt.parse(v['storedSize'] as String),
        originalSize = BigInt.parse(v['originalSize'] as String),
        compression = ArchiveCompression.values.byName(v['compression'] as String),
        sha256 = v['sha256'] as String;
}

class ArchiveEntry {
  final BigInt index;
  final ArchivePath path;
  final ArchiveEntryKind kind;
  final ArchiveFilePayload? payload;
  final ArchiveMetadata metadata;
  ArchiveEntry.fromJson(Object? value) : this._decode(jsonObject(value));
  ArchiveEntry._decode(Map<String, dynamic> v)
      : index = BigInt.parse(v['index'] as String),
        path = ArchivePath.fromJson(v['path']),
        kind = ArchiveEntryKind.values.byName(v['kind'] as String),
        payload = v['payload'] == null ? null : ArchiveFilePayload.fromJson(v['payload']),
        metadata = ArchiveMetadata.fromJson(v['metadata']);
}

class ArchiveManifest {
  final List<ArchiveEntry> entries;
  final BigInt totalBytes;
  ArchiveManifest.fromJson(Object? value) : this._decode(jsonObject(value));
  ArchiveManifest._decode(Map<String, dynamic> v)
      : entries = List.unmodifiable((v['entries'] as List).map(ArchiveEntry.fromJson)),
        totalBytes = BigInt.parse(v['totalBytes'] as String);
}

class ArchiveReadResult {
  final BigInt entryCount, outputBytes;
  ArchiveReadResult.fromJson(Object? value) : this._decode(jsonObject(value));
  ArchiveReadResult._decode(Map<String, dynamic> v)
      : entryCount = BigInt.parse(v['entryCount'] as String),
        outputBytes = BigInt.parse(v['outputBytes'] as String);
}

class ArchiveEntryMetadataResult {
  final ArchivePath path;
  final ArchiveMetadataApplyResult result;
  ArchiveEntryMetadataResult.fromJson(Object? value) : this._decode(jsonObject(value));
  ArchiveEntryMetadataResult._decode(Map<String, dynamic> v)
      : path = ArchivePath.fromJson(v['path']),
        result = ArchiveMetadataApplyResult.fromJson(v['result']);
}

class ArchiveExtractResult {
  final ArchiveNativePath path;
  final BigInt entryCount, outputBytes;
  final List<ArchiveEntryMetadataResult> metadata;
  ArchiveExtractResult.fromJson(Object? value) : this._decode(jsonObject(value));
  ArchiveExtractResult._decode(Map<String, dynamic> v)
      : path = ArchiveNativePath.fromJson(v['path']),
        entryCount = BigInt.parse(v['entryCount'] as String),
        outputBytes = BigInt.parse(v['outputBytes'] as String),
        metadata = List.unmodifiable((v['metadata'] as List).map(ArchiveEntryMetadataResult.fromJson));
}
