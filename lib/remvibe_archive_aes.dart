import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

/// **Key türetme:** passphrase -> 32-byte key (SHA-256)
Uint8List deriveKeyFromPassphrase(String passphrase) {
  final digest = Digest('SHA-256');
  final key = digest.process(Uint8List.fromList(utf8.encode(passphrase)));
  return key; // 32 bytes
}

/// **Rastgele IV üretimi** (16 byte)
Uint8List generateIV([int length = 16]) {
  final rnd = Random.secure();
  final iv = Uint8List(length);
  for (var i = 0; i < length; i++) {
    iv[i] = rnd.nextInt(256);
  }
  return iv;
}

/// **AES-CBC PKCS7 ile şifreleme**. Çıktı: IV + ciphertext
Uint8List aesEncrypt(Uint8List data, Uint8List key) {
  final iv = generateIV(16);
  final params = PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
    ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
    null,
  );
  final cipher = PaddedBlockCipher('AES/CBC/PKCS7')..init(true, params);
  final out = cipher.process(data);
  final result = Uint8List(iv.length + out.length)
    ..setRange(0, iv.length, iv)
    ..setRange(iv.length, iv.length + out.length, out);
  return result;
}

/// **AES-CBC PKCS7 ile çözme**. Girdi: IV + ciphertext
Uint8List aesDecrypt(Uint8List ivPlusCipher, Uint8List key) {
  final iv = ivPlusCipher.sublist(0, 16);
  final cipherText = ivPlusCipher.sublist(16);
  final params = PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
    ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
    null,
  );
  final cipher = PaddedBlockCipher('AES/CBC/PKCS7')..init(false, params);
  return cipher.process(cipherText);
}
