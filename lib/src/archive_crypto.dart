import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

const int scryptCost = 16384;
const int scryptBlockSize = 8;
const int scryptParallelization = 1;
const int archiveKeyLength = 32;
const int gcmNonceLength = 12;
const int gcmTagLength = 16;

Uint8List secureRandomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

Uint8List deriveArchiveKey(String passphrase, Uint8List salt) {
  final derivator = Scrypt()
    ..init(
      ScryptParameters(
        scryptCost,
        scryptBlockSize,
        scryptParallelization,
        archiveKeyLength,
        salt,
      ),
    );
  final key = Uint8List(archiveKeyLength);
  derivator.deriveKey(Uint8List.fromList(utf8.encode(passphrase)), 0, key, 0);
  return key;
}

GCMBlockCipher createGcmCipher({
  required bool forEncryption,
  required Uint8List key,
  required Uint8List nonce,
  required Uint8List associatedData,
}) {
  return GCMBlockCipher(AESEngine())
    ..init(
      forEncryption,
      AEADParameters<KeyParameter>(
        KeyParameter(key),
        gcmTagLength * 8,
        nonce,
        associatedData,
      ),
    );
}

String sha256Hex(List<int> bytes) {
  final digest = SHA256Digest().process(Uint8List.fromList(bytes));
  return hexEncode(digest);
}

String hexEncode(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
