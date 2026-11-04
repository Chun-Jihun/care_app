import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../domain/records.dart';
import '../domain/chat.dart';
import '../domain/backup.dart';
import '../domain/ui_preferences.dart';
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

import 'dart:async';

import '../domain/ai.dart';
import 'services/ai_service.dart';
import 'medical_answer_service.dart';
import '../domain/knowledge_installation.dart';
import '../domain/drug_safety.dart';
import 'services/medication_safety_service.dart';

/// Session lifecycle and composition. Feature services own feature operations.
class CareController extends ChangeNotifier {
  CareController(
    NotebookVault vault,
    PlatformServices platform, {
    this._aiRuntime = const UnavailableAiRuntime(),
    this.microphone,
    this.knowledge,
    this.medicalAnswers,
    this.drugCatalog,
  }) : _vault = vault,
       _platform = platform;
  final LocalAiRuntime _aiRuntime;
  final MicrophoneCapture Function()? microphone;
  final KnowledgeLibrary? knowledge;
  final MedicalAnswerService? medicalAnswers;
  final Future<DrugCatalog> Function()? drugCatalog;
  late final medicationSafety = MedicationSafetyService(_scope, drugCatalog);
  final NotebookVault _vault;
  final PlatformServices _platform;
  bool _ready = false, _unlocked = false, _hasPin = false, _busy = false;
  bool _vaultOpen = false, _backupOperation = false;
  bool _backupCommitting = false;
  int _externalOperations = 0;
  String _backupContact = '';
  int _epoch = 0;
  int _backgroundRevision = 0;
  String? _selectedId, _notice;
  AppLanguage _language = AppLanguage.korean;
  UiPreferences _uiPreferences = UiPreferences.defaults;
  UiPreferences get uiPreferences => _uiPreferences;
  bool get ready => _ready;
  bool get unlocked => _unlocked;
  bool get hasPin => _hasPin;
  bool get busy => _busy;
  bool get externalOperation => _externalOperations > 0;
  bool get backingUp => _unlocked && _busy && _backupOperation;
  bool get backupCommitting => backingUp && _backupCommitting;
  String get backupContact => backingUp ? _backupContact : '';
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
    _aiRuntime.cancel();
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
    _vault,
    busy: () => _busy,
    notify: draftsChanged,
  );
  late final chat = ChatService(_scope);
  late final ai = AiService(
    _scope,
    contextTasks,
    chat,
    _aiRuntime,
    medical: medicalAnswers,
  );

  Future<void> installKnowledge(
    void Function(double) progress, {
    void Function()? checkCancelled,
  }) async {
    final library = knowledge;
    if (library == null) return;
    final epoch = captureSession();
    final path = await _external(library.pickBundle);
    _check(epoch);
    if (path == null) return;
    await library.install(path, progress, () {
      _check(epoch);
      checkCancelled?.call();
    });
    _check(epoch);
  }

  late final backups = BackupService(
    _scope,
    _vault,
    _platform,
    run: _backupExclusive,
    beforeCommit: _beginBackupCommit,
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
    bool backup = false,
  }) async {
    if (_busy) throw CareError(CareErrorCode.busy);
    final epoch = _epoch;
    _check(epoch, requireUnlock: requireUnlock);
    if (requireUnlock) drafts.flushAll();
    // Keep only the already selected contact available across replacement;
    // the repository/selected patient may change during a restore commit.
    _backupContact = backup && _selectedId != null ? patient.contact : '';
    _backupOperation = backup;
    _backupCommitting = false;
    _busy = true;
    notifyListeners();
    try {
      return await action(epoch);
    } finally {
      _busy = false;
      _backupOperation = false;
      _backupCommitting = false;
      _backupContact = '';
      if (!_unlocked) _closeVault();
      notifyListeners();
    }
  }

  Future<T> _backupExclusive<T>(Future<T> Function(int epoch) action) =>
      _exclusive((epoch) async {
        try {
          final result = await action(epoch);
          if (_backupCommitting) {
            _notice ??= '백업 복원이 끝났어요. 수첩과 기록을 확인해 주세요.';
          }
          return result;
        } catch (_) {
          if (_backupCommitting) {
            _notice = '백업 복원을 완료하지 못했어요. 현재 수첩을 확인해 주세요.';
          }
          rethrow;
        }
      }, backup: true);

  void _beginBackupCommit(int epoch) {
    _check(epoch);
    _backupCommitting = true;
    // Reading is allowed during preparation; discard old routes before the
    // active database generation changes, even if no frame occurs meanwhile.
    notifyListeners();
  }

  Future<T> _external<T>(Future<T> Function() action) async {
    _externalOperations++;
    try {
      return await action();
    } finally {
      _externalOperations--;
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

  void showSavedNotice() {
    if (!_unlocked) return;
    _notice ??= '저장했어요.';
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
    _uiPreferences = await _vault.preferences.load();
    _language = AppLanguage.fromCode(await _vault.credentials.language());
    _platform.strings = strings;
    _hasPin = await _vault.credentials.hasPin();
    if (!_hasPin && await _vault.credentials.notebookStarted()) {
      await _open(_epoch);
    }
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

  Future<void> setUiPreferences(UiPreferences value) => _exclusive((_) async {
    try {
      await _vault.preferences.save(value);
    } catch (_) {
      throw CareError(CareErrorCode.preferencesSaveFailed);
    }
    _uiPreferences = value;
    notifyListeners();
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

  Future<void> startWithoutLock() => _exclusive((epoch) async {
    if (_hasPin) throw CareError(CareErrorCode.existingPinRequired);
    await _vault.credentials.markNotebookStarted();
    _check(epoch, requireUnlock: false);
    await _open(epoch);
  }, requireUnlock: false);

  Future<void> disableAppLock(String pin) => _exclusive((epoch) async {
    await _vault.credentials.verifyPin(pin);
    _check(epoch);
    await _vault.credentials.removePin(beforeCommit: () => _check(epoch));
    _hasPin = false;
  });

  Future<void> setPin(String pin) => _exclusive((epoch) async {
    if (_hasPin && !_unlocked) {
      throw CareError(CareErrorCode.existingPinRequired);
    }
    final backgroundRevision = _backgroundRevision;
    await _vault.credentials.setPin(
      pin,
      beforeCommit: () => _check(epoch, requireUnlock: _hasPin),
    );
    _hasPin = true;
    // Activation may finish after a pause handled while PIN was still off.
    // Keep no-PIN editor sessions intact, but require the newly enabled PIN.
    if (backgroundRevision != _backgroundRevision) {
      lock();
      return;
    }
    await _open(epoch);
  }, requireUnlock: _hasPin);
  Future<void> unlockPin(String pin) => _exclusive((epoch) async {
    await _vault.credentials.verifyPin(pin);
    await _open(epoch);
  }, requireUnlock: false);
  Future<void> unlockDevice() => _exclusive((epoch) async {
    if (!_hasPin || !await _vault.credentials.deviceEnabled()) {
      throw CareError(CareErrorCode.deviceAuthDisabled);
    }
    if (await _external(_platform.authenticate)) {
      await _open(epoch);
    } else {
      throw CareError(CareErrorCode.deviceAuthFallback);
    }
  }, requireUnlock: false);
  Future<bool> get deviceAuthEnabled async =>
      _hasPin && await _vault.credentials.deviceEnabled();
  Future<void> enableDeviceAuth(bool value) => _exclusive((epoch) async {
    if (!_hasPin) throw CareError(CareErrorCode.deviceAuthDisabled);
    if (value && !await _external(_platform.authenticate)) {
      throw CareError(CareErrorCode.deviceAuthIncomplete);
    }
    _check(epoch);
    await _vault.credentials.setDeviceEnabled(value);
  });

  void handleBackground() {
    _backgroundRevision++;
    if (_hasPin) {
      lock();
      return;
    }
    if (!_unlocked) return;
    drafts.flushAll(locking: true);
    _aiRuntime.cancel();
    contextTasks.cancelAll();
    chat.clearSession();
    // Keep the editor session valid when authentication is not requested.
    notifyListeners();
  }

  void lock() {
    if (_unlocked) drafts.flushAll(locking: true);
    chat.clearSession();
    _advanceEpoch();
    _unlocked = false;
    _backupContact = '';
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
    if (all ||
        impact == ChangeImpact.medications ||
        impact == ChangeImpact.records) {
      medicationBook.invalidate();
    }
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
      _notice = '초안 저장에 실패했습니다. 마지막으로 저장된 초안부터 확인해 주세요.';
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
    unawaited(_aiRuntime.dispose());
    contextTasks.cancelAll();
    _vault.close();
    super.dispose();
  }
}
