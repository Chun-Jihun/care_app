import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../domain/records.dart';
import '../domain/chat.dart';
import '../domain/backup.dart';
import '../l10n/app_strings.dart';
import 'notebook_repository.dart';
import 'context_tasks.dart';
import 'ports.dart';
import 'session_access.dart';
import 'services/records_service.dart';
import 'services/medications_service.dart';
import 'services/tasks_service.dart';
import 'services/visits_service.dart';
import 'services/profiles_service.dart';
import 'services/checkins_service.dart';
import 'services/drafts_service.dart';
import 'services/chat_service.dart';
import 'services/backup_service.dart';
import 'services/photo_service.dart';
import 'services/reminder_service.dart';

/// Session lifecycle and composition. Feature services own feature operations.
class CareController extends ChangeNotifier {
  CareController(NotebookVault vault, PlatformServices platform)
    : _vault = vault,
      _platform = platform;
  final NotebookVault _vault;
  final PlatformServices _platform;
  bool _ready = false, _unlocked = false, _hasPin = false, _busy = false;
  bool _externalOperation = false, _vaultOpen = false;
  int _epoch = 0;
  String? _selectedId, _notice;
  AppLanguage _language = AppLanguage.korean;
  bool get ready => _ready;
  bool get unlocked => _unlocked;
  bool get hasPin => _hasPin;
  bool get busy => _busy;
  bool get externalOperation => _externalOperation;
  String? get selectedId => _selectedId;
  String? get notice => _notice;
  AppLanguage get language => _language;
  AppStrings get strings => AppStrings(_language);
  NotebookRepository get _repository {
    _check(_epoch);
    return _vault.repository;
  }

  late final _scope = SessionAccess(
    repository: () => _repository,
    patient: () => _selectedId,
    capture: captureSession,
    check: _check,
    run: _exclusive,
    external: _external,
    changed: _refresh,
    newId: () => const Uuid().v7(),
  );
  late final records = RecordsService(_scope);
  late final contextTasks = ContextTasks(_scope);

  void _advanceEpoch() {
    contextTasks.cancelAll();
    _epoch++;
  }

  late final medicationBook = MedicationService(_scope);
  late final taskBook = TaskService(_scope);
  late final visitBook = VisitService(_scope);
  late final profiles = ProfileService(_scope);
  late final checkins = CheckinService(_scope);
  late final drafts = DraftService(
    _scope,
    busy: () => _busy,
    notify: draftsChanged,
  );
  late final chat = ChatService(_scope);
  late final backups = BackupService(
    _scope,
    _vault,
    _platform,
    onReplace: () {
      _advanceEpoch();
      chat.clearSession();
      _selectedId = null;
      _reminders.invalidate();
    },
  );
  late final photos = PhotoService(_scope, _vault, _platform);
  late final _reminders = ReminderService(_platform);

  int captureSession() {
    _check(_epoch);
    return _epoch;
  }

  void requireSession(int session) => _check(session);
  void _check(int epoch, {bool requireUnlock = true}) {
    if (epoch != _epoch || (requireUnlock && !_unlocked)) {
      throw CareError(CareErrorCode.locked);
    }
  }

  Future<T> _exclusive<T>(
    Future<T> Function(int epoch) action, {
    bool requireUnlock = true,
  }) async {
    if (_busy) throw CareError(CareErrorCode.busy);
    final epoch = _epoch;
    _check(epoch, requireUnlock: requireUnlock);
    if (requireUnlock) drafts.flushAll();
    _busy = true;
    notifyListeners();
    try {
      return await action(epoch);
    } finally {
      _busy = false;
      if (!_unlocked) _closeVault();
      notifyListeners();
    }
  }

  Future<T> _external<T>(Future<T> Function() action) async {
    _externalOperation = true;
    try {
      return await action();
    } finally {
      _externalOperation = false;
    }
  }

  void _closeVault() {
    _vault.close();
    _vaultOpen = false;
  }

  void draftsChanged() {
    if (_unlocked) notifyListeners();
  }

  void dismissNotice() {
    _notice = null;
    notifyListeners();
  }

  List<Patient> get patients => _unlocked ? profiles.patients() : const [];
  Patient get patient => patients.firstWhere((p) => p.id == _selectedId);
  List<CareEntry> get entries => _unlocked && _selectedId != null
      ? records.entries(_selectedId!)
      : const [];
  List<Medication> get medications => _unlocked && _selectedId != null
      ? medicationBook.medications(_selectedId!)
      : const [];
  List<CareTask> get tasks => _unlocked && _selectedId != null
      ? taskBook.tasks(_selectedId!)
      : const [];
  List<VisitPreparation> get visits => _unlocked && _selectedId != null
      ? visitBook.visits(_selectedId!)
      : const [];
  bool get notificationsEnabled =>
      _unlocked && _repository.setting('reminders_enabled') == 'true';

  Future<void> initialize() async {
    _language = AppLanguage.fromCode(await _vault.credentials.language());
    _platform.strings = strings;
    _hasPin = await _vault.credentials.hasPin();
    _ready = true;
    notifyListeners();
  }

  Future<void> setLanguage(AppLanguage value) => _exclusive((_) async {
    if (value == _language) return;
    try {
      await _vault.credentials.setLanguage(value.code);
    } catch (_) {
      throw CareError(CareErrorCode.languageSaveFailed);
    }
    _language = value;
    _platform.strings = strings;
    _reminders.invalidate();
    records.invalidate();
    notifyListeners();
    if (_unlocked) await _syncReminders();
  }, requireUnlock: false);
  Future<void> _open(int epoch) async {
    if (epoch != _epoch) return;
    if (!_vaultOpen) {
      await _vault.open();
      _vaultOpen = true;
    }
    if (epoch != _epoch) return;
    final repository = _vault.repository;
    if (repository.patients().isEmpty) repository.createPatient();
    _selectedId = repository.setting('selected_patient');
    if (!repository.patients().any((p) => p.id == _selectedId)) {
      _selectedId = repository.patients().first.id;
    }
    repository.setSetting('selected_patient', _selectedId!);
    _unlocked = true;
    await _refresh(ChangeImpact.all);
  }

  Future<void> setPin(String pin) => _exclusive((epoch) async {
    if (_hasPin && !_unlocked) {
      throw CareError(CareErrorCode.existingPinRequired);
    }
    await _vault.credentials.setPin(
      pin,
      beforeCommit: () => _check(epoch, requireUnlock: _hasPin),
    );
    _hasPin = true;
    await _open(epoch);
  }, requireUnlock: _hasPin);
  Future<void> unlockPin(String pin) => _exclusive((epoch) async {
    await _vault.credentials.verifyPin(pin);
    await _open(epoch);
  }, requireUnlock: false);
  Future<void> unlockDevice() => _exclusive((epoch) async {
    if (!await _vault.credentials.deviceEnabled()) {
      throw CareError(CareErrorCode.deviceAuthDisabled);
    }
    if (await _external(_platform.authenticate)) {
      await _open(epoch);
    } else {
      throw CareError(CareErrorCode.deviceAuthFallback);
    }
  }, requireUnlock: false);
  Future<bool> get deviceAuthEnabled => _vault.credentials.deviceEnabled();
  Future<void> enableDeviceAuth(bool value) => _exclusive((epoch) async {
    if (value && !await _external(_platform.authenticate)) {
      throw CareError(CareErrorCode.deviceAuthIncomplete);
    }
    _check(epoch);
    await _vault.credentials.setDeviceEnabled(value);
  });
  void lock() {
    if (_unlocked) drafts.flushAll(locking: true);
    chat.clearSession();
    _advanceEpoch();
    _unlocked = false;
    _invalidate(ChangeImpact.all);
    if (!_busy) _closeVault();
    notifyListeners();
  }

  Future<void> selectPatient(String id) => _exclusive((_) async {
    if (!patients.any((p) => p.id == id)) {
      throw CareError(CareErrorCode.patientNotFound);
    }
    _repository.setSetting('selected_patient', id);
    if (_selectedId != id) _advanceEpoch();
    _selectedId = id;
    await _refresh(ChangeImpact.all);
  });
  Future<void> refresh() async {
    if (_busy || !_unlocked) return;
    await _exclusive((_) => _refresh(ChangeImpact.all));
  }

  void _invalidate(ChangeImpact impact) {
    final all = impact == ChangeImpact.all || impact == ChangeImpact.profiles;
    if (all) profiles.invalidate();
    if (all ||
        impact == ChangeImpact.records ||
        impact == ChangeImpact.photos) {
      records.invalidate();
    }
    if (all || impact == ChangeImpact.medications) medicationBook.invalidate();
    if (all || impact == ChangeImpact.tasks) taskBook.invalidate();
    if (all ||
        impact == ChangeImpact.visits ||
        impact == ChangeImpact.records) {
      visitBook.invalidate();
    }
    if (all || impact == ChangeImpact.checkins) checkins.invalidate();
  }

  Future<void> _refresh(ChangeImpact impact) async {
    if (!_vaultOpen || !_unlocked) return;
    if ({
      ChangeImpact.all,
      ChangeImpact.profiles,
      ChangeImpact.records,
      ChangeImpact.medications,
    }.contains(impact)) {
      contextTasks.cancelAll();
    }
    _invalidate(impact);
    if (impact == ChangeImpact.all) {
      _repository.pruneChats();
      _repository.pruneDrafts();
    }
    var current = patients;
    chat.retainPatients(current.map((p) => p.id).toSet());
    if (!current.any((p) => p.id == _selectedId)) {
      if (current.isEmpty) {
        _repository.createPatient();
        profiles.invalidate();
        current = patients;
      }
      _advanceEpoch();
      _selectedId = current.first.id;
      _repository.setSetting('selected_patient', _selectedId!);
    }
    _notice = _vault.maintenancePending
        ? '기록은 열렸습니다. 저장소 정리는 다음 실행 때 다시 시도합니다.'
        : null;
    if (drafts.takeFlushFailure()) {
      _notice = '잠금 전 초안 저장에 실패했습니다. 마지막으로 저장된 초안부터 확인해 주세요.';
    }
    if ({
      ChangeImpact.all,
      ChangeImpact.profiles,
      ChangeImpact.records,
      ChangeImpact.photos,
    }.contains(impact)) {
      try {
        await _vault.cleanup(removeOrphans: false);
      } catch (_) {
        _notice = '기록은 저장되었습니다. 첨부파일 정리는 다음 실행 때 다시 시도합니다.';
      }
    }
    if (!_unlocked) return;
    if ({
      ChangeImpact.all,
      ChangeImpact.profiles,
      ChangeImpact.medications,
      ChangeImpact.tasks,
    }.contains(impact)) {
      await _syncReminders();
    }
    notifyListeners();
  }

  Future<void> _syncReminders() async {
    try {
      _notice = await _reminders.sync(_repository, () => _unlocked) ?? _notice;
    } catch (_) {
      _notice = '기록은 저장되었습니다. 알림 권한과 기기 설정을 확인해 주세요.';
    }
  }

  Future<void> enableNotifications(bool enabled) => _exclusive((epoch) async {
    if (enabled && !await _external(_platform.requestNotifications)) {
      throw CareError(CareErrorCode.notificationPermissionDenied);
    }
    _check(epoch);
    _repository.setSetting('reminders_enabled', enabled.toString());
    await _syncReminders();
  });
  bool hasImportedReminderPolicy(String pid) {
    _scope.requirePatient(pid);
    return _repository.setting('imported_muted:$pid') != null;
  }

  bool importedRemindersEnabled(String pid) {
    _scope.requirePatient(pid);
    return _repository.setting('imported_muted:$pid') != 'true';
  }

  Future<void> setImportedRemindersEnabled(String pid, bool value) =>
      _scope.write(
        pid,
        ChangeImpact.tasks,
        (repository) =>
            repository.setSetting('imported_muted:$pid', (!value).toString()),
      );
  Future<void> openDialer(String number) =>
      _external(() => _platform.dial(number));

  // Small navigation facade. All operations delegate to feature services.
  List<ChatMessage> chatMessages(String pid) =>
      _unlocked ? chat.messages(pid) : const [];
  Future<void> setChatRetention(String pid, ChatRetention value) =>
      chat.setRetention(pid, value);
  Future<void> addChatMessage(String pid, String text) => chat.add(pid, text);
  Future<void> deleteChatMessage(String pid, String id) => chat.delete(pid, id);
  Future<void> clearChatMessages(String pid) => chat.clear(pid);
  Future<void> addPhoto(String pid, String eid, {bool camera = false}) =>
      photos.add(pid, eid, camera: camera);
  Future<Uint8List> photo(String pid, String eid, String id) =>
      photos.open(pid, eid, id);
  Future<void> exportBackup(String password) => backups.exportLegacy(password);
  Future<void> exportSelection(String password, BackupSelection selection) =>
      backups.export(password, selection);
  Future<BackupPreview> inspectBackup(Uint8List data, String password) =>
      backups.inspect(data, password);
  Future<void> importSelection(Uint8List data, String password) =>
      backups.importSelection(data, password);
  Future<Uint8List?> chooseBackup() => backups.choose();
  Future<void> restoreBackup(Uint8List data, String password) =>
      backups.restore(data, password);
  Future<void> deleteAll() => _exclusive((_) async {
    lock();
    try {
      await _platform.schedule([]);
    } catch (_) {
      /* Erasure remains available. */
    }
    await _vault.wipe();
    _vaultOpen = false;
    await _vault.credentials.clearAuthentication();
    _hasPin = false;
    _selectedId = null;
    _reminders.invalidate();
  }, requireUnlock: false);
  @override
  void dispose() {
    contextTasks.cancelAll();
    _vault.close();
    super.dispose();
  }
}
