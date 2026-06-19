import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

/// Item action types
enum ItemAction { add, change, remove }

/// Base class for archive items
abstract class ArchiveBaseItem {
  final String crc32;
  final String name;
  String realName;
  final int size;
  final FileStat? attr;
  final DateTime dtCreate;
  final DateTime dtModify;

  int contentStart = 0;
  int contentLen = 0;

  ArchiveBaseItem(this.crc32, this.name, this.realName, this.size,
      this.attr, this.dtCreate, this.dtModify);

  String get fullName;
}

/// File item
class ArchiveFile extends ArchiveBaseItem {
  final ArchiveFolder? parent;
  bool loaded = false;
  Uint8List fileContent = Uint8List(0);

  ArchiveFile(this.parent, String crc32, String name, int size, FileStat? attr, DateTime dtCreate, DateTime dtModify): super(crc32, name, name, size, attr, dtCreate, dtModify) {
    parent?.files.add(this);
  }

  @override
  String get fullName {
    String res = name;
    if(parent != null && parent!.fullName.isNotEmpty) {
      res = '${parent!.fullName}/$name';
    }
    return res;
  }

  double get compressionRatio =>
      size > 0 && contentLen > 0 ? (size - contentLen) / (size / 100) : 0;

  String get compressionRatioText =>
      compressionRatio > 0 ? '${compressionRatio.toStringAsFixed(1)}%' : '';

  String extract(String folderPath) {
    final dir = Directory(p.dirname("$folderPath/$name"));
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      try {
        final file = File('${dir.path}/${p.basename(name)}');
        file.writeAsBytesSync(ZLibCodec().decode(fileContent));
        file.setLastModifiedSync(dtModify);
        file.setLastAccessedSync(dtModify);
      } catch(e) {
        return e.toString();
      }
    } catch(e) {
      return e.toString();
    }
    return '';
  }
}

/// Folder item
class ArchiveFolder extends ArchiveBaseItem {
  final ArchiveFolder? parent;
  final List<ArchiveFolder> folders = [];
  final List<ArchiveFile> files = [];

  ArchiveFolder(this.parent, String crc32, String name, int size,
      FileStat? attr, DateTime dtCreate, DateTime dtModify)
      : super(crc32, name, name, size, attr, dtCreate, dtModify) {
    parent?.folders.add(this);
  }

  @override
  String get fullName {
    String res = name;
    if(parent != null && parent!.fullName.isNotEmpty) {
      res = '${parent!.fullName}/$name';
    }
    return res;
  }

  ArchiveFile? addFile(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    final content = file.readAsBytesSync();
    final compressed = ZLibCodec().encode(content);
    final crc = calculateCRC32Hex(Uint8List.fromList(compressed));
    files.removeWhere((f) => f.name == file.uri.pathSegments.last);
    final af = ArchiveFile(
      this, 
      crc, 
      file.uri.pathSegments.last, 
      content.length, 
      file.statSync(), 
      file.statSync().changed,
      file.statSync().modified,
    );
    af.fileContent = Uint8List.fromList(compressed);
    af.loaded = true;
    return af;
  }

  ArchiveFolder addFolder(String path) {
    final dir = Directory(path.trim());
    if (!dir.existsSync()) return this;
    String aName = dir.uri.pathSegments.last;
    if(aName.isEmpty && dir.uri.pathSegments.length>1) {
      aName = dir.uri.pathSegments[dir.uri.pathSegments.length-2];
    }
    folders.removeWhere((f) => f.name == aName);
    final af = ArchiveFolder(this, '', aName, 0, dir.statSync(), dir.statSync().changed, dir.statSync().modified);
    for (var f in dir.listSync()) {
      if (f is File) af.addFile(f.path);
      if (f is Directory) af.addFolder(f.path);
    }
    return af;
  }

  void addFolderContent(String path) {
    final dir = Directory(path.trim());
    if (!dir.existsSync()) exit(0);
    String aName = dir.uri.pathSegments.last;
    if(aName.isEmpty && dir.uri.pathSegments.length>1) {
      aName = dir.uri.pathSegments[dir.uri.pathSegments.length-2];
    }
    for (var f in dir.listSync()) {
      if (f is File) addFile(f.path);
      if (f is Directory) addFolder(f.path);
    }
  }

  ArchiveFolder? createFolder(String aPath) {
    if(aPath.isEmpty) {
      return this;
    }
    List<String> lst = aPath.split('/');
    String aName = lst.first;
    lst.removeAt(0);
    try {
      var res = folders.firstWhere((f) => f.name == aName);
      return res.createFolder(lst.join('/'));
    } catch(_) {
      var res = ArchiveFolder(this, '', aName, 0, null, DateTime.now(), DateTime.now());
      res.realName = aName;
      return res.createFolder(lst.join('/'));
    }
  }

  void extract(String folderPath) {
    if(folderPath.substring(folderPath.length-1) != '/') {
      folderPath += '/';
    }
    String aPath = "$folderPath${parent == null ? '' : parent!.name}";
    if(aPath.substring(aPath.length-1) != '/') {
      aPath += '/';
    }
    final dir = Directory("$aPath$name");
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    for(var fld in folders) {
      fld.extract(aPath);
    }
    for(var fl in files) {
      fl.extract(dir.path);
      print(fl.fullName);
    }
  }

}

/// Compressed archive
class CompressedArchive {
  final String cryptKey;
  final String fileName;
  late ArchiveFolder root;

  CompressedArchive(this.cryptKey, this.fileName) {
    root = ArchiveFolder(null, '', '', 0, null, DateTime.now(), DateTime.now());
  }

  void clear() {
    root.folders.clear();
    root.files.clear();
  }

  void extract(String folderPath) {
    root.extract(folderPath);
  }

  void updateFile() {
    // burada header + content buffer oluşturulup dosyaya yazılır
    final file = File(fileName);
    // örnek: sadece root içeriğini yazıyoruz
    for (var f in root.files) {
      file.writeAsBytesSync(f.fileContent, mode: FileMode.append);
    }
  }
}

/// CRC32 hesaplama
String calculateCRC32Hex(Uint8List data) {
  int crc = 0xffffffff;
  for (var b in data) {
    crc = (crc >> 8) ^ _crc32Table[(crc ^ b) & 0xff];
  }
  crc = ~crc;
  if(crc<0) {
    crc = crc*-1;
  }
  return crc.toRadixString(16).padLeft(8, '0').toUpperCase();
}

const List<int> _crc32Table = [
    0x00000000, 0x77073096, 0xEE0E612C, 0x990951BA,
    0x076DC419, 0x706AF48F, 0xE963A535, 0x9E6495A3,
    0x0EDB8832, 0x79DCB8A4, 0xE0D5E91E, 0x97D2D988,
    0x09B64C2B, 0x7EB17CBD, 0xE7B82D07, 0x90BF1D91,
    0x1DB71064, 0x6AB020F2, 0xF3B97148, 0x84BE41DE,
    0x1ADAD47D, 0x6DDDE4EB, 0xF4D4B551, 0x83D385C7,
    0x136C9856, 0x646BA8C0, 0xFD62F97A, 0x8A65C9EC,
    0x14015C4F, 0x63066CD9, 0xFA0F3D63, 0x8D080DF5,
    0x3B6E20C8, 0x4C69105E, 0xD56041E4, 0xA2677172,
    0x3C03E4D1, 0x4B04D447, 0xD20D85FD, 0xA50AB56B,
    0x35B5A8FA, 0x42B2986C, 0xDBBBC9D6, 0xACBCF940,
    0x32D86CE3, 0x45DF5C75, 0xDCD60DCF, 0xABD13D59,
    0x26D930AC, 0x51DE003A, 0xC8D75180, 0xBFD06116,
    0x21B4F4B5, 0x56B3C423, 0xCFBA9599, 0xB8BDA50F,
    0x2802B89E, 0x5F058808, 0xC60CD9B2, 0xB10BE924,
    0x2F6F7C87, 0x58684C11, 0xC1611DAB, 0xB6662D3D,
    0x76DC4190, 0x01DB7106, 0x98D220BC, 0xEFD5102A,
    0x71B18589, 0x06B6B51F, 0x9FBFE4A5, 0xE8B8D433,
    0x7807C9A2, 0x0F00F934, 0x9609A88E, 0xE10E9818,
    0x7F6A0DBB, 0x086D3D2D, 0x91646C97, 0xE6635C01,
    0x6B6B51F4, 0x1C6C6162, 0x856530D8, 0xF262004E,
    0x6C0695ED, 0x1B01A57B, 0x8208F4C1, 0xF50FC457,
    0x65B0D9C6, 0x12B7E950, 0x8BBEB8EA, 0xFCB9887C,
    0x62DD1DDF, 0x15DA2D49, 0x8CD37CF3, 0xFBD44C65,
    0x4DB26158, 0x3AB551CE, 0xA3BC0074, 0xD4BB30E2,
    0x4ADFA541, 0x3DD895D7, 0xA4D1C46D, 0xD3D6F4FB,
    0x4369E96A, 0x346ED9FC, 0xAD678846, 0xDA60B8D0,
    0x44042D73, 0x33031DE5, 0xAA0A4C5F, 0xDD0D7CC9,
    0x5005713C, 0x270241AA, 0xBE0B1010, 0xC90C2086,
    0x5768B525, 0x206F85B3, 0xB966D409, 0xCE61E49F,
    0x5EDEF90E, 0x29D9C998, 0xB0D09822, 0xC7D7A8B4,
    0x59B33D17, 0x2EB40D81, 0xB7BD5C3B, 0xC0BA6CAD,
    0xEDB88320, 0x9ABFB3B6, 0x03B6E20C, 0x74B1D29A,
    0xEAD54739, 0x9DD277AF, 0x04DB2615, 0x73DC1683,
    0xE3630B12, 0x94643B84, 0x0D6D6A3E, 0x7A6A5AA8,
    0xE40ECF0B, 0x9309FF9D, 0x0A00AE27, 0x7D079EB1,
    0xF00F9344, 0x8708A3D2, 0x1E01F268, 0x6906C2FE,
    0xF762575D, 0x806567CB, 0x196C3671, 0x6E6B06E7,
    0xFED41B76, 0x89D32BE0, 0x10DA7A5A, 0x67DD4ACC,
    0xF9B9DF6F, 0x8EBEEFF9, 0x17B7BE43, 0x60B08ED5,
    0xD6D6A3E8, 0xA1D1937E, 0x38D8C2C4, 0x4FDFF252,
    0xD1BB67F1, 0xA6BC5767, 0x3FB506DD, 0x48B2364B,
    0xD80D2BDA, 0xAF0A1B4C, 0x36034AF6, 0x41047A60,
    0xDF60EFC3, 0xA867DF55, 0x316E8EEF, 0x4669BE79,
    0xCB61B38C, 0xBC66831A, 0x256FD2A0, 0x5268E236,
    0xCC0C7795, 0xBB0B4703, 0x220216B9, 0x5505262F,
    0xC5BA3BBE, 0xB2BD0B28, 0x2BB45A92, 0x5CB36A04,
    0xC2D7FFA7, 0xB5D0CF31, 0x2CD99E8B, 0x5BDEAE1D,
    0x9B64C2B0, 0xEC63F226, 0x756AA39C, 0x026D930A,
    0x9C0906A9, 0xEB0E363F, 0x72076785, 0x05005713,
    0x95BF4A82, 0xE2B87A14, 0x7BB12BAE, 0x0CB61B38,
    0x92D28E9B, 0xE5D5BE0D, 0x7CDCEFB7, 0x0BDBDF21,
    0x86D3D2D4, 0xF1D4E242, 0x68DDB3F8, 0x1FDA836E,
    0x81BE16CD, 0xF6B9265B, 0x6FB077E1, 0x18B74777,
    0x88085AE6, 0xFF0F6A70, 0x66063BCA, 0x11010B5C,
    0x8F659EFF, 0xF862AE69, 0x616BFFD3, 0x166CCF45,
    0xA00AE278, 0xD70DD2EE, 0x4E048354, 0x3903B3C2,
    0xA7672661, 0xD06016F7, 0x4969474D, 0x3E6E77DB,
    0xAED16A4A, 0xD9D65ADC, 0x40DF0B66, 0x37D83BF0,
    0xA9BCAE53, 0xDEBB9EC5, 0x47B2CF7F, 0x30B5FFE9,
    0xBDBDF21C, 0xCABAC28A, 0x53B39330, 0x24B4A3A6,
    0xBAD03605, 0xCDD70693, 0x54DE5729, 0x23D967BF,
    0xB3667A2E, 0xC4614AB8, 0x5D681B02, 0x2A6F2B94,
    0xB40BBE37, 0xC30C8EA1, 0x5A05DF1B, 0x2D02EF8D,
];
