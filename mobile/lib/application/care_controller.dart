import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/records.dart';
import '../infrastructure/care_database.dart';
import '../infrastructure/crypto.dart';
import '../infrastructure/platform_services.dart';
import '../infrastructure/vault_store.dart';

class CareController extends ChangeNotifier {
  CareController(this.vault, this.platform);
  final VaultStore vault;
  final PlatformServices platform;
  bool ready = false,
      unlocked = false,
      hasPin = false,
      busy = false,
      externalOperation = false;
  bool _vaultOpen = false;
  int _lockEpoch = 0;
  String? selectedId, notice;
  CareDatabase get db => vault.db;
  List<Patient> get patients => _vaultOpen ? db.patients() : [];
  Patient get patient => patients.firstWhere((p) => p.id == selectedId);
  List<CareEntry> get entries =>
      selectedId == null ? [] : db.entries(selectedId!);
  List<Medication> get medications =>
      selectedId == null ? [] : db.medications(selectedId!);
  List<CareTask> get tasks => selectedId == null ? [] : db.tasks(selectedId!);
  List<VisitPreparation> get visits =>
      selectedId == null ? [] : db.visits(selectedId!);
  bool get notificationsEnabled =>
      _vaultOpen && db.setting('reminders_enabled') == 'true';

  Future<void> initialize() async {
    hasPin = await vault.secrets.read('auth.pin') != null;
    ready = true;
    notifyListeners();
  }

  Future<void> _open(int epoch) async {
    if (!_vaultOpen) {
      await vault.open();
      _vaultOpen = true;
    }
    if (db.patients().isEmpty) {
      db.createPatient();
    }
    selectedId = db.setting('selected_patient');
    if (!db.patients().any((p) => p.id == selectedId)) {
      selectedId = db.patients().first.id;
    }
    db.setSetting('selected_patient', selectedId!);
    if (epoch != _lockEpoch) {
      return;
    }
    unlocked = true;
    await refresh();
  }

  Future<void> setPin(String pin) async {
    final epoch = _lockEpoch;
    if (hasPin && !unlocked) {
      throw const CareError('기존 잠금 번호로 수첩을 먼저 열어 주세요.');
    }
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw const CareError('잠금 번호는 숫자 6자리로 입력해 주세요.');
    }
    final salt = base64Encode(VaultCrypto.randomBytes(16));
    final hash = await VaultCrypto.pinHash(pin, salt);
    await vault.secrets.write(
      'auth.pin',
      jsonEncode({'salt': salt, 'hash': hash}),
    );
    await vault.secrets.write('auth.failures', '0');
    await vault.secrets.write('auth.until', '0');
    hasPin = true;
    await _open(epoch);
  }

  Future<void> unlockPin(String pin) async {
    final epoch = _lockEpoch;
    final until =
        int.tryParse(await vault.secrets.read('auth.until') ?? '0') ?? 0;
    if (DateTime.now().millisecondsSinceEpoch < until) {
      throw const CareError('잠시 후 다시 시도해 주세요.');
    }
    final encoded = await vault.secrets.read('auth.pin');
    final config = encoded == null
        ? <String, dynamic>{}
        : jsonDecode(encoded) as Map<String, dynamic>;
    final salt = config['salt'] as String?;
    final expected = config['hash'] as String?;
    if (salt == null || expected == null) {
      throw const CareError('잠금 번호 설정을 확인해 주세요.');
    }
    if (!VaultCrypto.equal(await VaultCrypto.pinHash(pin, salt), expected)) {
      final fails =
          (int.tryParse(await vault.secrets.read('auth.failures') ?? '0') ??
              0) +
          1;
      await vault.secrets.write('auth.failures', '$fails');
      if (fails >= 5) {
        await vault.secrets.write(
          'auth.until',
          '${DateTime.now().add(Duration(seconds: min(600, 30 * pow(2, (fails - 5) ~/ 5).toInt()))).millisecondsSinceEpoch}',
        );
      }
      throw const CareError('잠금 번호가 일치하지 않습니다.');
    }
    await vault.secrets.write('auth.failures', '0');
    await vault.secrets.write('auth.until', '0');
    await _open(epoch);
  }

  Future<void> unlockDevice() async {
    final epoch = _lockEpoch;
    if (await vault.secrets.read('auth.device') != 'true') {
      throw const CareError('설정에서 기기 인증을 먼저 켜 주세요.');
    }
    externalOperation = true;
    try {
      if (await platform.authenticate()) {
        await _open(epoch);
      } else {
        throw const CareError('기기 인증을 완료하지 못했습니다. 잠금 번호로 열어 주세요.');
      }
    } finally {
      externalOperation = false;
    }
  }

  Future<bool> get deviceAuthEnabled async =>
      await vault.secrets.read('auth.device') == 'true';
  Future<void> enableDeviceAuth(bool value) async {
    if (value) {
      externalOperation = true;
      try {
        if (!await platform.authenticate()) {
          throw const CareError('기기 인증을 완료하지 못했습니다.');
        }
      } finally {
        externalOperation = false;
      }
    }
    await vault.secrets.write('auth.device', value.toString());
    notifyListeners();
  }

  void lock() {
    _lockEpoch++;
    unlocked = false;
    notifyListeners();
  }

  Future<void> selectPatient(String id) async {
    if (!patients.any((p) => p.id == id)) {
      throw const CareError('돌봄 대상을 찾을 수 없습니다.');
    }
    selectedId = id;
    db.setSetting('selected_patient', id);
    await refresh();
  }

  Future<void> refresh() async {
    if (!_vaultOpen) {
      return;
    }
    if (!patients.any((p) => p.id == selectedId)) {
      if (patients.isEmpty) {
        db.createPatient();
      }
      selectedId = patients.first.id;
      db.setSetting('selected_patient', selectedId!);
    }
    notice = null;
    try {
      await vault.cleanup();
    } catch (_) {
      notice = '기록은 저장되었습니다. 첨부파일 정리는 다음 실행 때 다시 시도합니다.';
    }
    try {
      await _syncReminders();
    } catch (_) {
      notice = '기록은 저장되었습니다. 알림 권한과 기기 설정을 확인해 주세요.';
    }
    notifyListeners();
  }

  Future<T> mutate<T>(T Function() action) async {
    if (busy) {
      throw const CareError('진행 중인 작업이 끝난 뒤 다시 시도해 주세요.');
    }
    if (!unlocked) {
      throw const CareError('수첩 잠금을 해제해 주세요.');
    }
    final result = action();
    await refresh();
    return result;
  }

  Future<void> enableNotifications(bool enabled) async {
    if (enabled) {
      externalOperation = true;
      try {
        if (!await platform.requestNotifications()) {
          throw const CareError('기기 설정에서 알림을 허용해 주세요.');
        }
      } finally {
        externalOperation = false;
      }
    }
    db.setSetting('reminders_enabled', enabled.toString());
    await refresh();
  }

  Future<void> _syncReminders() async {
    final reminders = <Reminder>[];
    final now = DateTime.now();
    var id = 1;
    if (notificationsEnabled) {
      for (final p in patients) {
        for (final t
            in db
                .tasks(p.id)
                .where((t) => !t.done && t.reminder && t.dueAt.isAfter(now))) {
          reminders.add(Reminder(id++, t.dueAt));
        }
        for (final med in db.medications(p.id)) {
          for (final time in med.times) {
            final parts = time.split(':').map(int.parse).toList();
            var at = DateTime(now.year, now.month, now.day, parts[0], parts[1]);
            if (!at.isAfter(now)) {
              at = DateTime(
                now.year,
                now.month,
                now.day + 1,
                parts[0],
                parts[1],
              );
            }
            reminders.add(Reminder(id++, at, daily: true));
          }
        }
      }
      reminders.sort((a, b) => a.at.compareTo(b.at));
      if (reminders.length > 60) {
        notice = '기록은 저장되었습니다. 가까운 일정부터 최대 60개 알림을 예약했습니다.';
      }
    }
    await platform.schedule(reminders);
  }

  Future<void> addPhoto(String pid, String eid, {bool camera = false}) async {
    if (busy) {
      return;
    }
    busy = true;
    notifyListeners();
    externalOperation = true;
    try {
      final data = await platform.pickPhoto(camera: camera);
      if (data != null) {
        await vault.addPhoto(pid, eid, data);
        await refresh();
      }
    } finally {
      externalOperation = false;
      busy = false;
      notifyListeners();
    }
  }

  Future<void> exportBackup(String password) async {
    if (busy) {
      throw const CareError('진행 중인 작업을 먼저 마쳐 주세요.');
    }
    busy = true;
    notifyListeners();
    try {
      final data = await vault.backup(password);
      externalOperation = true;
      try {
        await platform.saveBackup(data);
      } finally {
        externalOperation = false;
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<Uint8List?> chooseBackup() async {
    externalOperation = true;
    try {
      return await platform.pickBackup();
    } finally {
      externalOperation = false;
    }
  }

  Future<void> restoreBackup(Uint8List data, String password) async {
    if (busy) {
      throw const CareError('진행 중인 작업을 먼저 마쳐 주세요.');
    }
    busy = true;
    notifyListeners();
    try {
      await vault.restore(data, password);
      selectedId = null;
      await refresh();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> deleteAll() async {
    if (busy) {
      throw const CareError('진행 중인 작업을 먼저 마쳐 주세요.');
    }
    try {
      await platform.schedule([]);
    } catch (_) {
      /* Local erasure must remain available when notification services fail. */
    }
    await vault.wipe();
    _vaultOpen = false;
    for (final key in [
      'auth.pin',
      'auth.hash',
      'auth.salt',
      'auth.failures',
      'auth.until',
      'auth.device',
    ]) {
      await vault.secrets.delete(key);
    }
    unlocked = false;
    hasPin = false;
    selectedId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    vault.close();
    super.dispose();
  }
}
