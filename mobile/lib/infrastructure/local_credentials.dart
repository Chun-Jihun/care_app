import 'dart:convert';
import 'dart:math';

import '../application/ports.dart';
import '../domain/records.dart';
import 'crypto.dart';

final class LocalCredentials implements Credentials {
  LocalCredentials(this._secrets);
  final SecretStore _secrets;
  @override
  Future<bool> hasPin() async => await _secrets.read('auth.pin') != null;
  @override
  Future<void> setPin(
    String pin, {
    required void Function() beforeCommit,
  }) async {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw CareError(CareErrorCode.invalidPinFormat);
    }
    final salt = base64Encode(VaultCrypto.randomBytes(16));
    final hash = await VaultCrypto.pinHash(pin, salt);
    beforeCommit();
    await _secrets.write('auth.pin', jsonEncode({'salt': salt, 'hash': hash}));
    await _secrets.write('auth.failures', '0');
    await _secrets.write('auth.until', '0');
  }

  @override
  Future<void> verifyPin(String pin) async {
    final until = int.tryParse(await _secrets.read('auth.until') ?? '0') ?? 0;
    if (DateTime.now().millisecondsSinceEpoch < until) {
      throw CareError(CareErrorCode.pinThrottled);
    }
    final encoded = await _secrets.read('auth.pin');
    final config = encoded == null
        ? <String, dynamic>{}
        : jsonDecode(encoded) as Map<String, dynamic>;
    final salt = config['salt'] as String?,
        expected = config['hash'] as String?;
    if (salt == null || expected == null) {
      throw CareError(CareErrorCode.pinConfigurationInvalid);
    }
    if (!VaultCrypto.equal(await VaultCrypto.pinHash(pin, salt), expected)) {
      final fails =
          (int.tryParse(await _secrets.read('auth.failures') ?? '0') ?? 0) + 1;
      await _secrets.write('auth.failures', '$fails');
      if (fails >= 5) {
        await _secrets.write(
          'auth.until',
          '${DateTime.now().add(Duration(seconds: min(600, 30 * pow(2, (fails - 5) ~/ 5).toInt()))).millisecondsSinceEpoch}',
        );
      }
      throw CareError(CareErrorCode.pinMismatch);
    }
    await _secrets.write('auth.failures', '0');
    await _secrets.write('auth.until', '0');
  }

  @override
  Future<bool> deviceEnabled() async =>
      await _secrets.read('auth.device') == 'true';
  @override
  Future<void> setDeviceEnabled(bool value) =>
      _secrets.write('auth.device', value.toString());
  @override
  Future<String?> language() => _secrets.read('app.language');
  @override
  Future<void> setLanguage(String code) => _secrets.write('app.language', code);
  @override
  Future<void> clearAuthentication() async {
    for (final key in [
      'auth.pin',
      'auth.hash',
      'auth.salt',
      'auth.failures',
      'auth.until',
      'auth.device',
    ]) {
      await _secrets.delete(key);
    }
  }
}
