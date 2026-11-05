enum ArchiveEncryption { none, aes256Gcm }

enum ArchiveCompression { none, zlib }

enum ArchiveEntryType { file, directory, symbolicLink }

class ArchiveEntry {
  const ArchiveEntry({
    required this.path,
    required this.type,
    required this.size,
    required this.modifiedTimeUtc,
    required this.platformMetadata,
    required this.criticalMetadata,
    this.sha256,
    this.posixMode,
    this.linkTarget,
    this.compression,
  });

  final String path;
  final ArchiveEntryType type;
  final int size;
  final String? sha256;
  final DateTime modifiedTimeUtc;
  final int? posixMode;
  final String? linkTarget;
  final ArchiveCompression? compression;
  final Map<String, Object?> platformMetadata;
  final Set<String> criticalMetadata;
}

class ArchiveExtractionPolicy {
  const ArchiveExtractionPolicy({
    this.maxEntries = 100000,
    this.maxEntryUncompressedBytes = 16 * 1024 * 1024 * 1024,
    this.maxTotalUncompressedBytes = 64 * 1024 * 1024 * 1024,
    this.failOnNonCriticalMetadataError = false,
  });

  static const strict = ArchiveExtractionPolicy();

  final int maxEntries;
  final int maxEntryUncompressedBytes;
  final int maxTotalUncompressedBytes;
  final bool failOnNonCriticalMetadataError;
}

class ArchiveReadPolicy {
  const ArchiveReadPolicy({
    this.maxStoredBodyBytes = 64 * 1024 * 1024 * 1024,
    this.maxManifestBytes = 16 * 1024 * 1024,
  });

  static const strict = ArchiveReadPolicy();

  final int maxStoredBodyBytes;
  final int maxManifestBytes;
}

class ArchiveExtractionResult {
  const ArchiveExtractionResult({
    required this.destination,
    required this.entriesExtracted,
    required this.warnings,
  });

  final String destination;
  final int entriesExtracted;
  final List<String> warnings;
}
