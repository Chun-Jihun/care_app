import '../domain/drug_safety.dart';
import 'backup_document.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/records.dart';
import '../domain/visit_recording.dart';
import '../domain/record_lookup.dart';
import '../domain/chat.dart';
import '../domain/drafts.dart';
import '../domain/backup.dart';
import '../application/notebook_repository.dart';
import 'sqlite_session.dart';
import 'schema_migrations.dart';
import 'repositories/records.dart';
import 'repositories/medications.dart';
import 'repositories/tasks.dart';
import 'repositories/visits.dart';
import 'repositories/visit_recordings.dart';
import 'repositories/profiles.dart';
import 'repositories/chat.dart';
import 'repositories/drafts.dart';
import 'repositories/backup.dart';
import '../domain/ai.dart';

/// Coordinates one encrypted connection; feature repositories own their SQL.
class CareDatabase implements NotebookRepository {
  CareDatabase._(Database db, String directory)
    : _store = SqliteSession(db, directory);
  final SqliteSession _store;
  Database get _db => _store.connection;
  String get directory => _store.directory;
  bool _closed = false;
  static const schemaVersion = SchemaMigrations.version;
  static String newId() => RecordIds.next();
  late final _records = SqliteRecords(_store);
  late final _medications = SqliteMedications(_store, _records);
  late final _tasks = SqliteTasks(_store);
  late final _visits = SqliteVisits(_store, _records);
  late final _visitRecordings = SqliteVisitRecordings(_store);
  late final _profiles = SqliteProfiles(_store);
  late final _chat = SqliteChat(_store);
  late final _drafts = SqliteDrafts(_store, this);
  late final _backup = SqliteBackup(_store, this, verifyIntegrity);
  static CareDatabase open(
    String directory, {
    required Uint8List key,
    required Uint8List identityKey,
  }) {
    final store = _connect(directory, key, identityKey);
    try {
      SchemaMigrations(store._store, store.verifyIntegrity).migrate();
      store.verifyIntegrity();
      for (final name in ['care', 'identity']) {
        for (var version = 1; version < schemaVersion; version++) {
          final backup = File(
            p.join(directory, '$name.migration-v$version.bak'),
          );
          // A cleanup failure cannot make a verified database unavailable.
          try {
            if (backup.existsSync()) backup.deleteSync();
          } on FileSystemException {
            // Retry after the next successful open, never restore over new data.
          }
        }
      }
      store.pruneChats();
      store.pruneDrafts();
      return store;
    } catch (_) {
      store.close();
      rethrow;
    }
  }

  static CareDatabase _connect(
    String directory,
    Uint8List key,
    Uint8List identityKey, {
    String? carePath,
  }) {
    if (key.length != 32 || identityKey.length != 32) {
      throw CareError(CareErrorCode.invalidStorageKey);
    }
    Directory(directory).createSync(recursive: true);
    final db = sqlite3.open(carePath ?? p.join(directory, 'care.db'));
    try {
      if (db.select('PRAGMA cipher_version').isEmpty) {
        throw CareError(CareErrorCode.encryptedStorageUnavailable);
      }
      String hex(List<int> bytes) =>
          bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      db.execute('PRAGMA key = "x\'${hex(key)}\'"');
      db.select('SELECT count(*) FROM sqlite_master');
      db.execute('PRAGMA temp_store=MEMORY');
      db.execute('PRAGMA journal_mode=DELETE');
      db.execute('PRAGMA synchronous=FULL');
      db.execute('PRAGMA foreign_keys=ON');
      db.execute('PRAGMA secure_delete=ON');
      db.execute('PRAGMA cipher_memory_security=ON');
      db.execute(
        'ATTACH DATABASE ? AS identity KEY "x\'${hex(identityKey)}\'"',
        [p.join(directory, 'identity.db')],
      );
      db.select('SELECT count(*) FROM identity.sqlite_master');
      db.execute('PRAGMA identity.journal_mode=DELETE');
      db.execute('PRAGMA identity.synchronous=FULL');
      db.execute('PRAGMA identity.secure_delete=ON');
      return CareDatabase._(db, directory);
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  int _pragma(String name) =>
      int.parse(_db.select('PRAGMA $name').single.values.single.toString());

  int get changeCount =>
      _db.select('SELECT total_changes()').single.values.single as int;

  int? get compactedCareBytes {
    final free = _pragma('main.freelist_count');
    if (free == 0) return null;
    return (_pragma('main.page_count') - free) * _pragma('main.page_size');
  }

  static void writeCompactedCopy(
    String directory,
    String stagedPath,
    Uint8List key,
    Uint8List identityKey,
  ) {
    final source = _connect(directory, key, identityKey);
    try {
      // SQLCipher keys the VACUUM target with the main database's key.
      source._db.execute('VACUUM main INTO ?', [stagedPath]);
    } finally {
      source.close();
    }
    final candidate = _connect(
      directory,
      key,
      identityKey,
      carePath: stagedPath,
    );
    try {
      candidate.verifyIntegrity();
    } finally {
      candidate.close();
    }
  }

  // Both the current and compacted files have already passed integrity checks.
  CareDatabase reopenAfterCompaction(Uint8List key, Uint8List identityKey) =>
      _connect(directory, key, identityKey);

  void verifyIntegrity() {
    if (_db
            .select(
              'SELECT c.id FROM patient_context c LEFT JOIN identity.patient_identity i ON i.patient_id=c.id WHERE i.patient_id IS NULL',
            )
            .isNotEmpty ||
        _db
            .select(
              'SELECT i.patient_id FROM identity.patient_identity i LEFT JOIN patient_context c ON c.id=i.patient_id WHERE c.id IS NULL',
            )
            .isNotEmpty ||
        _db
            .select(
              'SELECT entry_id FROM medication_intake i WHERE (medication_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM medication m WHERE m.id=i.medication_id AND m.patient_id=i.patient_id)) OR (plan_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM medication_plan p WHERE p.id=i.plan_id AND p.patient_id=i.patient_id AND p.medication_id=i.medication_id))',
            )
            .isNotEmpty) {
      throw CareError(CareErrorCode.recordPatientMismatch);
    }
    for (final schema in ['main', 'identity']) {
      if (_db
              .select('PRAGMA $schema.integrity_check')
              .any((r) => r.values.first != 'ok') ||
          _db.select('PRAGMA $schema.foreign_key_check').isNotEmpty) {
        throw CareError(CareErrorCode.storageIntegrityFailed);
      }
    }
    for (final kind in EntryKind.values) {
      if (_db.select(
        'SELECT e.id FROM care_entry e LEFT JOIN ${kind.table} d ON d.patient_id=e.patient_id AND d.entry_id=e.id WHERE e.kind=? AND d.entry_id IS NULL',
        [kind.name],
      ).isNotEmpty) {
        throw CareError(CareErrorCode.recordDetailMissing);
      }
    }
  }

  void close() {
    if (!_closed) {
      _db.close();
      _closed = true;
    }
  }

  @override
  CareEntry? entry(String pid, String id) => _records.entry(pid, id);
  @override
  List<CareEntry> entries(
    String patientId, {
    EntryKind? kind,
    String query = '',
    DateTime? day,
    DateTime? from,
    DateTime? until,
    RecordLookup? lookup,
    int? limit,
    String Function(CareEntry)? displayText,
  }) => _records.entries(
    patientId,
    kind: kind,
    query: query,
    day: day,
    from: from,
    until: until,
    lookup: lookup,
    limit: limit,
    displayText: displayText,
  );
  @override
  CareEntry saveEntry(
    String patientId, {
    String? id,
    int? expectedVersion,
    required EntryKind kind,
    required DateTime occurredAt,
    String note = '',
    Map<String, String> fields = const {},
  }) => _records.saveEntry(
    patientId,
    id: id,
    expectedVersion: expectedVersion,
    kind: kind,
    occurredAt: occurredAt,
    note: note,
    fields: fields,
  );
  @override
  List<CareEntry> revisions(String pid, String id) =>
      _records.revisions(pid, id);
  @override
  void deleteEntry(String pid, String id) => _records.deleteEntry(pid, id);
  @override
  List<Attachment> attachments(String pid, String eid) =>
      _records.attachments(pid, eid);
  void addAttachment(
    String pid,
    String eid,
    String id,
    String wrappedKey,
    int size,
  ) => _records.addAttachment(pid, eid, id, wrappedKey, size);
  @override
  void deleteAttachment(String pid, String id) =>
      _records.deleteAttachment(pid, id);
  List<String> get pendingFileDeletes => _records.pendingFileDeletes;
  void finishFileDelete(String id) => _records.finishFileDelete(id);
  List<String> get allAttachmentIds => _records.allAttachmentIds;
  bool get hasVisitAudio => _db
      .select('SELECT 1 FROM visit_recording WHERE byte_count>0 LIMIT 1')
      .isNotEmpty;
  @override
  List<Medication> medications(String pid, {bool includeArchived = false}) =>
      _medications.medications(pid, includeArchived: includeArchived);
  @override
  Medication saveMedication(
    String pid, {
    String? id,
    int? expectedVersion,
    required String name,
    required String instruction,
    required List<String> times,
  }) => _medications.saveMedication(
    pid,
    id: id,
    expectedVersion: expectedVersion,
    name: name,
    instruction: instruction,
    times: times,
  );
  @override
  List<CareEntry> medicationIntakes(String pid, String medId, DateTime day) =>
      _medications.medicationIntakes(pid, medId, day);
  @override
  List<MedicationPlan> medicationPlans(String pid, String id) =>
      _medications.medicationPlans(pid, id);
  @override
  void confirmMedicationProduct(
    String pid,
    String id,
    int version,
    MedicationProduct? product,
  ) => _medications.confirmProduct(pid, id, version, product);
  @override
  void archiveMedication(String pid, String id, bool archive) =>
      _medications.archiveMedication(pid, id, archive);
  @override
  CareEntry recordIntake(
    String pid,
    String medId,
    String status,
    DateTime at, {
    String reason = '',
    String reaction = '',
    DateTime? scheduledAt,
  }) => _medications.recordIntake(
    pid,
    medId,
    status,
    at,
    reason: reason,
    reaction: reaction,
    scheduledAt: scheduledAt,
  );
  @override
  List<CareTask> tasks(String pid, {bool? done, int? limit}) =>
      _tasks.tasks(pid, done: done, limit: limit);
  @override
  int taskCount(String pid, {bool? done}) => _tasks.taskCount(pid, done: done);
  @override
  CareTask saveTask(
    String pid, {
    String? id,
    required String title,
    String note = '',
    required DateTime dueAt,
    bool reminder = false,
  }) => _tasks.saveTask(
    pid,
    id: id,
    title: title,
    note: note,
    dueAt: dueAt,
    reminder: reminder,
  );
  @override
  void completeTask(String pid, String id, bool done) =>
      _tasks.completeTask(pid, id, done);
  @override
  void deleteTask(String pid, String id) => _tasks.deleteTask(pid, id);
  @override
  List<VisitPreparation> visits(String pid) => _visits.visits(pid);
  @override
  List<VisitRecording> visitRecordings(String pid) =>
      _visitRecordings.list(pid);
  @override
  VisitRecording beginVisitRecording(String pid) => _visitRecordings.begin(pid);
  @override
  void appendVisitAudio(String pid, String id, Uint8List pcm) =>
      _visitRecordings.append(pid, id, pcm);
  @override
  Uint8List? readVisitAudio(String pid, String id, int offset) =>
      _visitRecordings.read(pid, id, offset);
  @override
  void keepVisitRecording(String pid, String id) =>
      _visitRecordings.keep(pid, id);
  @override
  void deleteVisitRecording(String pid, String id) =>
      _visitRecordings.delete(pid, id);
  @override
  VisitPreparation saveVisit(
    String pid, {
    String? id,
    required String title,
    required String questions,
    required List<String> entryIds,
  }) => _visits.saveVisit(
    pid,
    id: id,
    title: title,
    questions: questions,
    entryIds: entryIds,
  );
  @override
  List<CareEntry> visitEntries(String pid, String id) =>
      _visits.visitEntries(pid, id);
  @override
  void deleteVisit(String pid, String id) => _visits.deleteVisit(pid, id);
  @override
  String? setting(String key) => _profiles.setting(key);
  @override
  void setSetting(String key, String value) => _profiles.setSetting(key, value);
  @override
  List<Patient> patients() => _profiles.patients();
  @override
  Patient createPatient({
    String alias = '',
    String role = 'family',
    String context = '',
    String contact = '',
  }) => _profiles.createPatient(
    alias: alias,
    role: role,
    context: context,
    contact: contact,
  );
  @override
  void updatePatient(
    String id, {
    required String alias,
    required String role,
    required String context,
    required String contact,
  }) => _profiles.updatePatient(
    id,
    alias: alias,
    role: role,
    context: context,
    contact: contact,
  );
  @override
  void deletePatient(String id) => _profiles.deletePatient(id);
  @override
  void addCheckin({
    required String fatigue,
    required String sleep,
    required String stress,
    String note = '',
  }) => _profiles.addCheckin(
    fatigue: fatigue,
    sleep: sleep,
    stress: stress,
    note: note,
  );
  @override
  List<CaregiverCheckin> checkins({int? limit}) =>
      _profiles.checkins(limit: limit);
  @override
  void deleteCheckin(String id) => _profiles.deleteCheckin(id);
  @override
  ChatRetention? chatRetention(String pid) => _chat.chatRetention(pid);
  @override
  void setChatRetention(String pid, ChatRetention policy, {DateTime? now}) =>
      _chat.setChatRetention(pid, policy, now: now);
  @override
  void pruneChats({DateTime? now}) => _chat.pruneChats(now: now);
  @override
  List<ChatMessage> chatMessages(String pid, {DateTime? now, int? limit}) =>
      _chat.chatMessages(pid, now: now, limit: limit);
  @override
  ChatMessage addChatMessage(String pid, String text, {DateTime? now}) =>
      _chat.addChatMessage(pid, text, now: now);
  @override
  void setChatReply(String pid, String id, AiReply reply) =>
      _chat.setChatReply(pid, id, reply);
  @override
  void deleteChatMessage(String pid, String id) =>
      _chat.deleteChatMessage(pid, id);
  @override
  void clearChatMessages(String pid) => _chat.clearChatMessages(pid);
  @override
  DraftRetention? get draftRetention => _drafts.draftRetention;
  @override
  void setDraftRetention(DraftRetention value, {DateTime? now}) =>
      _drafts.setDraftRetention(value, now: now);
  @override
  void pruneDrafts({DateTime? now}) => _drafts.pruneDrafts(now: now);
  @override
  List<CareDraft> drafts(String? pid, {DateTime? now}) =>
      _drafts.drafts(pid, now: now);
  @override
  int draftCount(String? pid) => _drafts.draftCount(pid);
  @override
  void saveDraft({
    required String id,
    required String? patientId,
    required DraftType type,
    required DraftPayload payload,
    String? targetId,
    String? base,
    bool create = true,
    DateTime? now,
  }) => _drafts.saveDraft(
    id: id,
    patientId: patientId,
    type: type,
    payload: payload,
    targetId: targetId,
    base: base,
    create: create,
    now: now,
  );
  @override
  List<String> addEntryDrafts(String pid, List<EntryDraftPayload> entries) =>
      _store.transaction(() {
        final ids = <String>[];
        for (final entry in entries) {
          final id = newId();
          saveDraft(
            id: id,
            patientId: pid,
            type: DraftType.entry,
            payload: entry,
          );
          ids.add(id);
        }
        return ids;
      });
  @override
  void deleteDraft(String? pid, String id) => _drafts.deleteDraft(pid, id);
  @override
  String? draftBase(DraftType type, String? pid, String? targetId) =>
      _drafts.draftBase(type, pid, targetId);
  @override
  void completeDraft(String? pid, String id) {
    _drafts.completeDraft(pid, id);
  }

  /// Text, medication changes, source record, attachment and draft removal commit together.
  void completeDraftWithPhoto(
    String pid,
    String draftId,
    String photoId,
    String wrappedKey,
    int bytes,
  ) => _store.transaction(() {
    final entryId = _drafts.completeDraft(pid, draftId, photo: true);
    if (entryId == null) throw CareError(CareErrorCode.draftSourceMismatch);
    addAttachment(pid, entryId, photoId, wrappedKey, bytes);
  });
  bool hasImportedBackup(String id) => _backup.hasImportedBackup(id);
  Map<String, String> importBackupRows(
    BackupRows rows,
    String backupId,
    Map<String, String> ids,
  ) => _backup.importBackupRows(rows, backupId, ids);
  BackupRows selectBackup(BackupSelection selection) =>
      _backup.selectBackup(selection);
  Map<BackupCategory, int> countBackup(BackupSelection selection) =>
      _backup.countBackup(selection);
}
