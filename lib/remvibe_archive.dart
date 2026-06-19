import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'remvibe_archive_aes.dart';
import 'remvibe_archive_header.dart';
import 'remvibe_archive_objects.dart';
export 'remvibe_archive_objects.dart';

// ... ArchiveFile, ArchiveFolder, CRC32 vs. sınıflarını önceden tanımladığını varsayıyorum ...

class RemvibeArchive {
  late ArchiveFolder root;

  RemvibeArchive() {
    clear();
  }

  static final defaultCryptKey = 'A48C31FA';
  String _cryptKey = defaultCryptKey;
  String get cryptKey => _cryptKey;
  String _fileName = '';
  String get fileName => _fileName;

  /// **Int -> 4 byte (big-endian)** (Delphi tarafında ilk 4 bayt uzunluk yazımı)
  Uint8List _intToBytes(int value) {
    final b = ByteData(4);
    b.setUint32(0, value, Endian.big);
    return b.buffer.asUint8List();
  }

  /// **4 byte -> Int (big-endian)**
  int _bytesToInt(Uint8List bytes) {
    final b = ByteData.sublistView(bytes);
    return b.getUint32(0, Endian.big);
  }

  void _debugPrint(ArchiveFolder folder, { int level = 0 , String prefix=""}) {
    for(var item in folder.folders) {
      bool isLast = (folder.folders.last == item && folder.files.isEmpty);
      String ic = isLast ? "└" : "├";
      print("$prefix$ic─📁${item.name}");
      _debugPrint(item, level: level+1, prefix: isLast ? prefix+"    " : prefix+"|   ");
    }
    for(var item in folder.files) {
      String ic = folder.files.last == item ? "└" : "├";
      print("$prefix$ic─🗒️${item.name}");
    }
  }

  void debugPrint() {
    print(fileName.isEmpty ? "📦New.nta" : "📦$fileName");
    _debugPrint(root, prefix: "  ");
  }

  ArchiveFile? addFile(String path) {
    return root.addFile(path);
  }

  ArchiveFolder addFolder(String path) {
    return root.addFolder(path);
  }

  void addFolderContent(String path) {
    return root.addFolderContent(path);
  }

  void clear() {
    _cryptKey = defaultCryptKey;
    _fileName = '';
    root = ArchiveFolder(null, '', '', 0, null, DateTime.now(), DateTime.now());
  }

  void extract(String path) {
    root.extract(path);
  }

  /// **Header ve Content buffer’larını üretip AES ile şifreleyip dosyaya yazar**
  void saveToFile({ String? cryptKey, String? fileName }) {
    _cryptKey = cryptKey ?? _cryptKey;
    _fileName = fileName ?? _fileName;
    final headerBuffer = BytesBuilder();
    final contentBuffer = BytesBuilder();

    // Kök klasör ve içeriği derinlemesine yazmak istersen,
    // burada bir DFS ile tüm folder/file’ları dolaşabilirsin.
    // Basit: sadece root altını dolaşalım:
    void writeFolder(ArchiveFolder folder) {
      // Önce dosyalar
      for (final f in folder.files) {
        f.contentStart = contentBuffer.length;
        f.contentLen = f.fileContent.length;
        contentBuffer.add(f.fileContent);

        final fullNameBytes = utf8.encode(f.fullName);
        final realNameBytes = utf8.encode(f.realName);

        final header = ArchiveHeaderItem(
          isFolder: false,
          crc32: f.crc32,
          fullNameLen: fullNameBytes.length,
          realNameLen: realNameBytes.length,
          realSize: f.size,
          compressedSize: f.fileContent.length,
          contentStart: f.contentStart,
          contentLen: f.contentLen,
          dtCreate: f.dtCreate,
          dtModify: f.dtModify,
        );

        headerBuffer.add(header.toBytes());
        headerBuffer.add(fullNameBytes);
        headerBuffer.add(realNameBytes);
      }

      // Sonra klasörler (Delphi’de klasör header’ı da yazılıyor)
      for (final sub in folder.folders) {
        final fullNameBytes = utf8.encode(sub.fullName);
        final realNameBytes = utf8.encode(sub.realName);

        final header = ArchiveHeaderItem(
          isFolder: true,
          crc32: '',
          fullNameLen: fullNameBytes.length,
          realNameLen: realNameBytes.length,
          realSize: 0,            // doldurmak istersen toplam boyutu hesaplayıp yazabilirsin
          compressedSize: 0,
          contentStart: headerBuffer.length + headerStructSize + fullNameBytes.length + realNameBytes.length,
          contentLen: 0,          // Delphi’de bu sınırlarda güncelleniyordu; basit haliyle 0 bırakıyoruz
          dtCreate: sub.dtCreate,
          dtModify: sub.dtModify,
        );

        headerBuffer.add(header.toBytes());
        headerBuffer.add(fullNameBytes);
        headerBuffer.add(realNameBytes);

        // Recursive:
        writeFolder(sub);
      }
    }

    writeFolder(root);

    // Header: zlib + AES
    final compressedHeader = Uint8List.fromList(ZLibCodec().encode(headerBuffer.toBytes()));
    final key = deriveKeyFromPassphrase(this.cryptKey);
    final encryptedHeader = aesEncrypt(compressedHeader, key);

    // Content: AES (dosya içerikleri daha önce zlib ile sıkıştırılmıştı)
    final encryptedContent = aesEncrypt(Uint8List.fromList(contentBuffer.toBytes()), key);

    // Dosyaya: [4 byte headerLen] [encHeader] [encContent]
    final out = BytesBuilder();
    out.add(_intToBytes(encryptedHeader.length));
    out.add(encryptedHeader);
    out.add(encryptedContent);

    File(this.fileName).writeAsBytesSync(out.toBytes(), flush: true);
  }

  /// **Dosyadan AES ile çözerek arşivi yükler**
  bool loadFromFile({ String? cryptKey, String? fileName }) {
    _cryptKey = cryptKey ?? _cryptKey;
    _fileName = fileName ?? _fileName;
    final f = File(this.fileName);
    if (!f.existsSync()) return false;

    final all = f.readAsBytesSync();
    var pos = 0;

    final headerLen = _bytesToInt(all.sublist(pos, pos + 4));
    pos += 4;

    var encHeader = all.sublist(pos, pos + headerLen);
    pos += headerLen;
    var encContent = all.sublist(pos);

    final key = deriveKeyFromPassphrase(this.cryptKey);
    final headerBytes = aesDecrypt(encHeader, key);
    final contentBytes = aesDecrypt(encContent, key);

    // Header’ı zlib ile aç
    final headerPlain = Uint8List.fromList(ZLibCodec().decode(headerBytes));

    // Arşivi temizle
    root.files.clear();
    root.folders.clear();

    // Parse döngüsü
    var buffPos = 0;
    while (buffPos < headerPlain.length) {
      // Struct
      final itemBytes = headerPlain.sublist(buffPos, buffPos + headerStructSize);
      buffPos += headerStructSize;
      final item = ArchiveHeaderItem.fromBytes(itemBytes);

      // İsimler
      final fullName = utf8.decode(headerPlain.sublist(buffPos, buffPos + item.fullNameLen));
      buffPos += item.fullNameLen;
      final realName = utf8.decode(headerPlain.sublist(buffPos, buffPos + item.realNameLen));
      buffPos += item.realNameLen;

      if (item.isFolder) {
        // Klasör oluşturma: fullName yolunu hiyerarşik eklemek istersen parçalayabilirsin.
        /*final folder = */
        //print(parentList);
        //ArchiveFolder(root, item.crc32, parentList.last, 0, null, item.dtCreate, item.dtModify).realName = realName;
        root.createFolder(fullName);
        // Derinlik: fullName içindeki ara klasörleri oluşturarak en sona yerleştirme yapılabilir.
      } else {
        var lst = fullName.split('/');
        var aName = lst.last;
        lst.removeLast();
        var fld = root.createFolder(lst.join('/'));
        final fContent = contentBytes.sublist(item.contentStart, item.contentStart + item.contentLen);
        final fileItem = ArchiveFile(fld, item.crc32, aName, item.realSize, null, item.dtCreate, item.dtModify)
          ..realName = realName
          ..contentStart = item.contentStart
          ..contentLen = item.contentLen
          ..fileContent = Uint8List.fromList(fContent)
          ..loaded = true;

        // İstersen CRC kontrolü:
        if(fileItem.crc32 != calculateCRC32Hex(fContent)) {
          return false;
        }
      }
    }
    return true;
  }

}
