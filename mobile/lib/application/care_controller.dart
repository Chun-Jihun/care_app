import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/records.dart';
import '../domain/chat.dart';
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
  String? _reminderState;

  void _checkSession(int epoch, {bool requireUnlock = true}) {
    if (epoch != _lockEpoch || (requireUnlock && !unlocked)) {
      throw const CareError('수첩 잠금을 해제한 뒤 다시 시도해 주세요.');
    }
  }

  Future<T> _exclusive<T>(
    Future<T> Function(int epoch) action, {
    bool requireUnlock = true,
  }) async {
    if (busy) {
      throw const CareError('진행 중인 작업이 끝난 뒤 다시 시도해 주세요.');
    }
    final epoch = _lockEpoch;
    _checkSession(epoch, requireUnlock: requireUnlock);
    busy = true;
    notifyListeners();
    try {
      return await action(epoch);
    } finally {
      busy = false;
      if (!unlocked) {
        _closeVault();
      }
      notifyListeners();
    }
  }

  Future<T> _external<T>(Future<T> Function() action) async {
    externalOperation = true;
    try {
      return await action();
    } finally {
      externalOperation = false;
    }
  }

  void _closeVault() {
    vault.close();
    _vaultOpen = false;
  }

  final _sessionChats = <String, List<ChatMessage>>{};
  List<ChatMessage> chatMessages(String pid) {
    if (!unlocked) {
      return [];
    }
    return [...db.chatMessages(pid), ...?_sessionChats[pid]];
  }

  Future<void> setChatRetention(String pid, ChatRetention value) async {
    await mutate(() {
      db.setChatRetention(pid, value);
      _sessionChats.remove(pid);
    });
  }

  Future<void> addChatMessage(String pid, String text) async {
    await mutate(() {
      final policy = db.chatRetention(pid);
      if (policy == null) {
        throw const CareError('질문 보관 방식을 먼저 선택해 주세요.');
      }
      if (text.trim().isEmpty || text.length > 20000) {
        throw const CareError('질문을 1~20,000자로 입력해 주세요.');
      }
      if (policy == ChatRetention.session) {
        (_sessionChats[pid] ??= []).add(
          ChatMessage(
            id: CareDatabase.newId(),
            patientId: pid,
            text: text.trim(),
            createdAt: DateTime.now(),
          ),
        );
      } else {
        db.addChatMessage(pid, text);
      }
    });
  }

  Future<void> deleteChatMessage(String pid, String id) async {
    await mutate(() {
      if (_sessionChats[pid]?.any((m) => m.id == id) ?? false) {
        _sessionChats[pid]!.removeWhere((m) => m.id == id);
      } else {
        db.deleteChatMessage(pid, id);
      }
    });
  }

  Future<void> clearChatMessages(String pid) async {
    await mutate(() {
      db.clearChatMessages(pid);
      _sessionChats.remove(pid);
    });
  }

  String? selectedId, notice;
  CareDatabase get db {
    _checkSession(_lockEpoch);
    return vault.db;
  }

  List<Patient> get patients => unlocked ? db.patients() : [];
  Patient get patient => patients.firstWhere((p) => p.id == selectedId);
  List<CareEntry> get entries =>
      !unlocked || selectedId == null ? [] : db.entries(selectedId!);
  List<Medication> get medications =>
      !unlocked || selectedId == null ? [] : db.medications(selectedId!);
  List<CareTask> get tasks =>
      !unlocked || selectedId == null ? [] : db.tasks(selectedId!);
  List<VisitPreparation> get visits =>
      !unlocked || selectedId == null ? [] : db.visits(selectedId!);
  bool get notificationsEnabled =>
      unlocked && db.setting('reminders_enabled') == 'true';

  Future<void> initialize() async {
    hasPin = await vault.secrets.read('auth.pin') != null;
    ready = true;
    notifyListeners();
  }

  Future<void> _open(int epoch) async {
    if (epoch != _lockEpoch) return;
    if (!_vaultOpen) {
      await vault.open();
      _vaultOpen = true;
    }
    if (epoch != _lockEpoch) return;
    final db = vault.db;
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
    await _refresh();
  }

  Future<void> setPin(String pin) => _exclusive((epoch) async {
    if (hasPin && !unlocked) {
      throw const CareError('기존 잠금 번호로 수첩을 먼저 열어 주세요.');
    }
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw const CareError('잠금 번호는 숫자 6자리로 입력해 주세요.');
    }
    final salt = base64Encode(VaultCrypto.randomBytes(16));
    final hash = await VaultCrypto.pinHash(pin, salt);
    _checkSession(epoch, requireUnlock: hasPin);
    await vault.secrets.write(
      'auth.pin',
      jsonEncode({'salt': salt, 'hash': hash}),
    );
    await vault.secrets.write('auth.failures', '0');
    await vault.secrets.write('auth.until', '0');
    hasPin = true;
    await _open(epoch);
  }, requireUnlock: hasPin);

  Future<void> unlockPin(String pin) => _exclusive((epoch) async {
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
  }, requireUnlock: false);

  Future<void> unlockDevice() => _exclusive((epoch) async {
    if (await vault.secrets.read('auth.device') != 'true') {
      throw const CareError('설정에서 기기 인증을 먼저 켜 주세요.');
    }
    if (await _external(platform.authenticate)) {
      await _open(epoch);
    } else {
      throw const CareError('기기 인증을 완료하지 못했습니다. 잠금 번호로 열어 주세요.');
    }
  }, requireUnlock: false);

  Future<bool> get deviceAuthEnabled async =>
      await vault.secrets.read('auth.device') == 'true';
  Future<void> enableDeviceAuth(bool value) => _exclusive((epoch) async {
    if (value) {
      if (!await _external(platform.authenticate)) {
        throw const CareError('기기 인증을 완료하지 못했습니다.');
      }
    }
    _checkSession(epoch);
    await vault.secrets.write('auth.device', value.toString());
    notifyListeners();
  });

  void lock() {
    _sessionChats.clear();
    _lockEpoch++;
    unlocked = false;
    if (!busy) _closeVault();
    notifyListeners();
  }

  Future<void> selectPatient(String id) => _exclusive((epoch) async {
    if (!patients.any((p) => p.id == id)) {
      throw const CareError('돌봄 대상을 찾을 수 없습니다.');
    }
    selectedId = id;
    db.setSetting('selected_patient', id);
    await _refresh();
  });

  Future<void> refresh() async {
    if (busy || !unlocked) return;
    await _exclusive((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!_vaultOpen || !unlocked) {
      return;
    }
    db.pruneChats();
    _sessionChats.removeWhere((pid, _) => !patients.any((p) => p.id == pid));
    if (!patients.any((p) => p.id == selectedId)) {
      if (patients.isEmpty) {
        db.createPatient();
      }
      selectedId = patients.first.id;
      db.setSetting('selected_patient', selectedId!);
    }
    notice = vault.maintenancePending
        ? '기록은 열렸습니다. 저장소 정리는 다음 실행 때 다시 시도합니다.'
        : null;
    try {
      await vault.cleanup(removeOrphans: false);
    } catch (_) {
      notice = '기록은 저장되었습니다. 첨부파일 정리는 다음 실행 때 다시 시도합니다.';
    }
    if (!unlocked) return;
    try {
      await _syncReminders();
    } catch (_) {
      notice = '기록은 저장되었습니다. 알림 권한과 기기 설정을 확인해 주세요.';
    }
    notifyListeners();
  }

  Future<T> mutate<T>(T Function() action) => _exclusive((_) async {
    final result = action();
    await _refresh();
    return result;
  });

  Future<void> enableNotifications(bool enabled) => _exclusive((epoch) async {
    if (enabled) {
      if (!await _external(platform.requestNotifications)) {
        throw const CareError('기기 설정에서 알림을 허용해 주세요.');
      }
    }
    _checkSession(epoch);
    db.setSetting('reminders_enabled', enabled.toString());
    await _refresh();
  });

  Future<void> _syncReminders() async {
    final reminders = <Reminder>[];
    final now = DateTime.now();
    final definitions = <String>[];
    if (notificationsEnabled) {
      for (final p in patients) {
        for (final t in db.tasks(p.id).where((t) => !t.done && t.reminder)) {
          final source = 'task:${p.id}:${t.id}';
          definitions.add('$source:${t.dueAt.millisecondsSinceEpoch}');
          reminders.add(Reminder(Reminder.idFor(source), t.dueAt));
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
            final source = 'med:${p.id}:${med.id}:$time';
            definitions.add(source);
            reminders.add(Reminder(Reminder.idFor(source), at, daily: true));
          }
        }
      }
      reminders.sort((a, b) => a.at.compareTo(b.at));
      if (reminders.where((r) => r.at.isAfter(now)).length > 60) {
        notice = '기록은 저장되었습니다. 가까운 일정부터 최대 60개 알림을 예약했습니다.';
      }
    }
    if (reminders.map((r) => r.id).toSet().length != reminders.length) {
      throw const CareError('알림 식별자가 충돌했습니다. 일정을 확인해 주세요.');
    }
    definitions.sort();
    final state = jsonEncode([
      notificationsEnabled,
      await platform.timeZone(),
      definitions,
      reminders
          .where((r) => r.at.isAfter(now))
          .take(60)
          .map((r) => r.id)
          .toList(),
    ]);
    if (!unlocked || state == _reminderState) return;
    await platform.schedule(reminders);
    _reminderState = state;
  }

  Future<void> addPhoto(String pid, String eid, {bool camera = false}) =>
      _exclusive((epoch) async {
        final data = await _external(() => platform.pickPhoto(camera: camera));
        _checkSession(epoch);
        if (data != null) {
          await vault.addPhoto(
            pid,
            eid,
            data,
            beforeCommit: () => _checkSession(epoch),
          );
          await _refresh();
        }
      });

  Future<Uint8List> photo(String pid, String eid, String id) =>
      _exclusive((epoch) async {
        final data = await vault.photo(pid, eid, id);
        _checkSession(epoch);
        return data;
      });

  Future<void> exportBackup(String password) => _exclusive((epoch) async {
    final data = await vault.backup(password);
    _checkSession(epoch);
    await _external(() => platform.saveBackup(data));
  });

  Future<Uint8List?> chooseBackup() => _exclusive((epoch) async {
    final data = await _external(platform.pickBackup);
    _checkSession(epoch);
    return data;
  });

  Future<void> restoreBackup(Uint8List data, String password) =>
      _exclusive((epoch) async {
        await vault.restore(
          data,
          password,
          beforeCommit: () => _checkSession(epoch),
        );
        _sessionChats.clear();
        selectedId = null;
        _reminderState = null;
        await _refresh();
      });

  // Also available from the explicit forgotten-PIN reset confirmation.
  Future<void> deleteAll() => _exclusive((_) async {
    lock();
    try {
      await platform.schedule([]);
    } catch (_) {
      /* Local erasure must remain available when notification services fail. */
    }
    await vault.wipe();
    _sessionChats.clear();
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
    _reminderState = null;
    notifyListeners();
  }, requireUnlock: false);

  @override
  void dispose() {
    vault.close();
    super.dispose();
  }
}
