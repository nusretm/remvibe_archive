import 'package:remvibe_archive/remvibe_archive.dart';

void main(List<String> arguments) {
  String testArchive = 'dosyacepte.nta';
  String testKey = 'TESTKEY';
  RemvibeArchive arc = RemvibeArchive();
  bool oprCompress = false;
  if(oprCompress) {
    arc.root.addFolderContent('D:/development/DosyaCepte_v2/dosyacepte/build/windows/x64/runner/Release');
    arc.saveToFile(fileName: testArchive, cryptKey: testKey);
    arc.debugPrint();
  } else {
    if(arc.loadFromFile(fileName: testArchive, cryptKey: testKey)) {
      print("\nArşiv dosyası yüklendi: $testArchive");
      print("-----------------------------------------------------");
      arc.debugPrint();
      print("\nArşiv dosyası açılıyor: $testArchive");
      arc.extract('test_exctract');
      print("Bitti.\n");
    } else {
      print("Arşiv dosyası bulunamadı: $testArchive");
    }
  }
}
