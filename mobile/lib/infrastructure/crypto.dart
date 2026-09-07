import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../domain/records.dart';

class VaultCrypto {
  static final _aes = AesGcm.with256bits();
  static Uint8List randomBytes([int length = 32]) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => r.nextInt(256)));
  }

  static Future<Uint8List> seal(
    List<int> data,
    List<int> key, {
    String context = 'care-file-v1',
  }) async {
    final result = await _aes.encrypt(
      data,
      secretKey: SecretKey(key),
      aad: utf8.encode(context),
    );
    return Uint8List.fromList([
      ...result.nonce,
      ...result.cipherText,
      ...result.mac.bytes,
    ]);
  }

  static Future<Uint8List> open(
    List<int> data,
    List<int> key, {
    String context = 'care-file-v1',
  }) async {
    if (data.length < 28) {
      throw const CareError('암호화 파일 형식이 올바르지 않습니다.');
    }
    final result = await _aes.decrypt(
      SecretBox(
        data.sublist(12, data.length - 16),
        nonce: data.sublist(0, 12),
        mac: Mac(data.sublist(data.length - 16)),
      ),
      secretKey: SecretKey(key),
      aad: utf8.encode(context),
    );
    return Uint8List.fromList(result);
  }

  static Future<List<int>> derive(String password, List<int> salt) async =>
      (await Pbkdf2(
            macAlgorithm: Hmac.sha256(),
            iterations: 210000,
            bits: 256,
          ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt))
          .extractBytes();
  static Future<Uint8List> passwordSeal(Uint8List data, String password) async {
    if (password.length < 12) {
      throw const CareError('백업 비밀번호는 12자 이상으로 입력해 주세요.');
    }
    final salt = randomBytes(16);
    final encrypted = await seal(
      data,
      await derive(password, salt),
      context: 'care-backup-v1',
    );
    return Uint8List.fromList([
      ...utf8.encode('CAREBK01'),
      ...salt,
      ...encrypted,
    ]);
  }

  static Future<Uint8List> passwordOpen(Uint8List data, String password) async {
    if (data.length < 52 ||
        utf8.decode(data.sublist(0, 8), allowMalformed: true) != 'CAREBK01') {
      throw const CareError('간병수첩 백업 파일이 아닙니다.');
    }
    return open(
      data.sublist(24),
      await derive(password, data.sublist(8, 24)),
      context: 'care-backup-v1',
    );
  }

  static Future<String> pinHash(String pin, String salt) async =>
      base64Encode(await derive(pin, base64Decode(salt)));
  static bool equal(String a, String b) {
    var diff = a.length ^ b.length;
    for (var i = 0; i < min(a.length, b.length); i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
