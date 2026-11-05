import 'dart:convert';
import 'dart:typed_data';

import 'archive_exception.dart';
import 'archive_model.dart';

const int ntaVersion = 2;
const int preambleLength = 24;
const int maxPublicHeaderLength = 1024 * 1024;
const int maxManifestLength = 16 * 1024 * 1024;
const int absoluteMaxEntries = 1000000;
const List<int> ntaMagic = [0x4e, 0x54, 0x41, 0x32, 0x0d, 0x0a, 0x1a, 0x0a];

Uint8List uint64Bytes(int value) {
  if (value < 0) {
    throw const ArchiveException(
      ArchiveErrorCode.invalidArgument,
      'A length cannot be negative.',
    );
  }
  final data = ByteData(8)..setUint64(0, value, Endian.big);
  return data.buffer.asUint8List();
}

int readUint64(Uint8List bytes) =>
    ByteData.sublistView(bytes).getUint64(0, Endian.big);

Uint8List buildPreamble({
  required bool encrypted,
  required int publicHeaderLength,
  required int bodyLength,
}) {
  final data = ByteData(preambleLength);
  final bytes = data.buffer.asUint8List()..setRange(0, ntaMagic.length, ntaMagic);
  data.setUint16(8, ntaVersion, Endian.big);
  data.setUint16(10, encrypted ? 1 : 0, Endian.big);
  data.setUint32(12, publicHeaderLength, Endian.big);
  data.setUint64(16, bodyLength, Endian.big);
  return bytes;
}

Preamble parsePreamble(Uint8List bytes) {
  if (bytes.length != preambleLength ||
      !listEquals(bytes.sublist(0, ntaMagic.length), ntaMagic)) {
    throw const ArchiveException(
      ArchiveErrorCode.invalidArchive,
      'The NTA V2 magic header is missing or corrupt.',
    );
  }
  final data = ByteData.sublistView(bytes);
  final version = data.getUint16(8, Endian.big);
  if (version != ntaVersion) {
    throw ArchiveException(
      ArchiveErrorCode.unsupportedVersion,
      'Unsupported NTA version $version.',
    );
  }
  final flags = data.getUint16(10, Endian.big);
  if (flags & ~1 != 0) {
    throw ArchiveException(
      ArchiveErrorCode.invalidArchive,
      'Unknown NTA V2 flags: $flags.',
    );
  }
  final headerLength = data.getUint32(12, Endian.big);
  final bodyLength = data.getUint64(16, Endian.big);
  if (headerLength == 0 || headerLength > maxPublicHeaderLength) {
    throw const ArchiveException(
      ArchiveErrorCode.invalidArchive,
      'The public header length is invalid.',
    );
  }
  return Preamble(
    encrypted: flags & 1 != 0,
    publicHeaderLength: headerLength,
    bodyLength: bodyLength,
  );
}

bool listEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Map<String, Object?> decodeJsonObject(Uint8List bytes, String label) {
  try {
    final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (value is! Map<String, Object?>) {
      throw const FormatException('Expected an object.');
    }
    return value;
  } catch (error) {
    throw ArchiveException(
      ArchiveErrorCode.invalidArchive,
      'The $label is not valid UTF-8 JSON.',
      error,
    );
  }
}

class Preamble {
  const Preamble({
    required this.encrypted,
    required this.publicHeaderLength,
    required this.bodyLength,
  });

  final bool encrypted;
  final int publicHeaderLength;
  final int bodyLength;
}

class StoredEntry {
  const StoredEntry({
    required this.entry,
    required this.dataOffset,
    required this.storedSize,
  });

  final ArchiveEntry entry;
  final int? dataOffset;
  final int? storedSize;
}
