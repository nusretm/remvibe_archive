import 'dart:typed_data';
import 'dart:convert';

/// Delphi TntArchiveHeader_Item eşdeğeri
/// Boyut: 1 (IsFolder) + 9 (CRC32 ShortString[8]) + 2 + 2 + 8 + 8 + 8 + 8 + 8 + 8 = 62 bayt
const int headerStructSize = 62;

class ArchiveHeaderItem {
  bool isFolder;
  String crc32; // 8 karakter (hex), ShortString[8] içinde yazılacak
  int fullNameLen;   // Word (2 byte, little-endian)
  int realNameLen;   // Word (2 byte, little-endian)
  int realSize;      // int64 (8)
  int compressedSize;// int64 (8)
  int contentStart;  // int64 (8)
  int contentLen;    // int64 (8)
  DateTime dtCreate; // double (8)
  DateTime dtModify; // double (8)

  ArchiveHeaderItem({
    required this.isFolder,
    required this.crc32,
    required this.fullNameLen,
    required this.realNameLen,
    required this.realSize,
    required this.compressedSize,
    required this.contentStart,
    required this.contentLen,
    required this.dtCreate,
    required this.dtModify,
  });

  /// **ShortString[8] yazımı:** 1 bayt uzunluk + 8 bayt karakter (padding ' ' veya 0)
  static void _writeShortString8(ByteData b, int offset, String s) {
    final bytes = utf8.encode(s);
    final len = bytes.length.clamp(0, 8);
    b.setUint8(offset, len);
    for (var i = 0; i < 8; i++) {
      b.setUint8(offset + 1 + i, i < len ? bytes[i] : 0);
    }
  }

  /// **ShortString[8] okuma**
  static String _readShortString8(Uint8List data, int offset) {
    final len = data[offset];
    final slice = data.sublist(offset + 1, offset + 1 + len);
    return utf8.decode(slice);
  }

  Uint8List toBytes() {
    final b = ByteData(headerStructSize);
    var off = 0;

    b.setUint8(off, isFolder ? 1 : 0);
    off += 1;

    _writeShortString8(b, off, crc32.padRight(8).substring(0, 8));
    off += 9;

    b.setUint16(off, fullNameLen, Endian.little); off += 2;
    b.setUint16(off, realNameLen, Endian.little); off += 2;

    b.setInt64(off, realSize, Endian.little); off += 8;
    b.setInt64(off, compressedSize, Endian.little); off += 8;
    b.setInt64(off, contentStart, Endian.little); off += 8;
    b.setInt64(off, contentLen, Endian.little); off += 8;

    // Delphi TDateTime = double (8 byte). Burada ms epoch double yazıyoruz.
    b.setFloat64(off, dtCreate.millisecondsSinceEpoch.toDouble(), Endian.little); off += 8;
    b.setFloat64(off, dtModify.millisecondsSinceEpoch.toDouble(), Endian.little); off += 8;

    return b.buffer.asUint8List();
  }

  static ArchiveHeaderItem fromBytes(Uint8List bytes) {
    assert(bytes.length >= headerStructSize);
    final b = ByteData.sublistView(bytes);
    var off = 0;

    final isFolder = b.getUint8(off) == 1; off += 1;
    final crc32 = _readShortString8(bytes, off); off += 9;

    final fullNameLen = b.getUint16(off, Endian.little); off += 2;
    final realNameLen = b.getUint16(off, Endian.little); off += 2;

    final realSize = b.getInt64(off, Endian.little); off += 8;
    final compressedSize = b.getInt64(off, Endian.little); off += 8;
    final contentStart = b.getInt64(off, Endian.little); off += 8;
    final contentLen = b.getInt64(off, Endian.little); off += 8;

    final dtCreate = DateTime.fromMillisecondsSinceEpoch(
      b.getFloat64(off, Endian.little).toInt(),
    ); off += 8;
    final dtModify = DateTime.fromMillisecondsSinceEpoch(
      b.getFloat64(off, Endian.little).toInt(),
    ); off += 8;

    return ArchiveHeaderItem(
      isFolder: isFolder,
      crc32: crc32,
      fullNameLen: fullNameLen,
      realNameLen: realNameLen,
      realSize: realSize,
      compressedSize: compressedSize,
      contentStart: contentStart,
      contentLen: contentLen,
      dtCreate: dtCreate,
      dtModify: dtModify,
    );
  }
}
