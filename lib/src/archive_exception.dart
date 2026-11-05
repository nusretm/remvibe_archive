enum ArchiveErrorCode {
  invalidArgument,
  invalidArchive,
  unsupportedVersion,
  unsupportedAlgorithm,
  authenticationFailed,
  integrityMismatch,
  unsafePath,
  duplicateEntry,
  resourceLimitExceeded,
  unsupportedMetadata,
  destinationExists,
  sourceChanged,
  ioFailure,
}

class ArchiveException implements Exception {
  const ArchiveException(this.code, this.message, [this.cause]);

  final ArchiveErrorCode code;
  final String message;
  final Object? cause;

  @override
  String toString() {
    final suffix = cause == null ? '' : ': $cause';
    return 'ArchiveException(${code.name}): $message$suffix';
  }
}
