import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class CryptoUtils {
  static const int saltLengthBytes = 16;
  static const int nonceLengthBytes = 12; // AES-GCM standard
  static const int pbkdf2Iterations = 200000;

  static final AesGcm cipher = AesGcm.with256bits();

  static Uint8List generateRandomBytes(int length) {
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  static Future<SecretKey> deriveKey({
    required String password,
    required Uint8List salt,
    int iterations = pbkdf2Iterations,
  }) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return secretKey;
  }

  static Future<EncryptedPayload> encryptBytes({
    required List<int> plaintext,
    required SecretKey key,
  }) async {
    final nonce = generateRandomBytes(nonceLengthBytes);
    final box = await cipher.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
    );
    return EncryptedPayload(
      nonce: Uint8List.fromList(box.nonce),
      cipherText: Uint8List.fromList(box.cipherText),
      macBytes: Uint8List.fromList(box.mac.bytes),
    );
  }

  static Future<Uint8List> decryptBytes({
    required EncryptedPayload payload, 
    required SecretKey key,
  }) async {
    final box = SecretBox(
      payload.cipherText,
      nonce: payload.nonce,
      mac: Mac(payload.macBytes),
    );
    final clear = await cipher.decrypt(
      box,
      secretKey: key,
    );
    return Uint8List.fromList(clear);
  }
}

class EncryptedPayload {
  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List macBytes;

  EncryptedPayload({
    required this.nonce,
    required this.cipherText,
    required this.macBytes,
  });

  Map<String, dynamic> toJson() => {
        'nonce': base64Encode(nonce),
        'cipherText': base64Encode(cipherText),
        'mac': base64Encode(macBytes),
      };

  static EncryptedPayload fromJson(Map<String, dynamic> json) {
    return EncryptedPayload(
      nonce: Uint8List.fromList(base64Decode(json['nonce'] as String)),
      cipherText: Uint8List.fromList(base64Decode(json['cipherText'] as String)),
      macBytes: Uint8List.fromList(base64Decode(json['mac'] as String)),
    );
  }
}