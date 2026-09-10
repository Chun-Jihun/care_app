import 'backup_document.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/records.dart';
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
import 'repositories/profiles.dart';
import 'repositories/chat.dart';
import 'repositories/drafts.dart';
import 'repositories/backup.dart';

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
  late final _profiles = SqliteProfiles(_store);
  late final _chat = SqliteChat(_store);
  late final _drafts = SqliteDrafts(_store, this);
  late final _backup = SqliteBackup(_store, this, verifyIntegrity);
  static CareDatabase open(
    String directory, {
    required Uint8List key,
    required Uint8List identityKey,
  }) {
    if (key.length != 32 || identityKey.length != 32) {
      throw CareError(CareErrorCode.invalidStorageKey);
    }
    Directory(directory).createSync(recursive: true);
    final db = sqlite3.open(p.join(directory, 'care.db'));
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
      final store = CareDatabase._(db, directory);
      SchemaMigrations(store._store, store.verifyIntegrity).migrate();
      store.verifyIntegrity();
      for (final name in ['care', 'identity']) {
        for (final version in [1, 2]) {
          final backup = File(
            p.join(directory, '$name.migration-v$version.bak'),
          );
          if (backup.existsSync()) backup.deleteSync();
        }
      }
      store.pruneChats();
      store.pruneDrafts();
      return store;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

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
    int? limit,
    String Function(CareEntry)? displayText,
  }) => _records.entries(
    patientId,
    kind: kind,
    query: query,
    day: day,
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
  List<MedicationPlan> medicationPlans(String pid, String id) =>
      _medications.medicationPlans(pid, id);
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
  List<CareTask> tasks(String pid) => _tasks.tasks(pid);
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
  List<CaregiverCheckin> checkins() => _profiles.checkins();
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
  List<ChatMessage> chatMessages(String pid, {DateTime? now}) =>
      _chat.chatMessages(pid, now: now);
  @override
  ChatMessage addChatMessage(String pid, String text, {DateTime? now}) =>
      _chat.addChatMessage(pid, text, now: now);
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
  void deleteDraft(String? pid, String id) => _drafts.deleteDraft(pid, id);
  @override
  String? draftBase(DraftType type, String? pid, String? targetId) =>
      _drafts.draftBase(type, pid, targetId);
  @override
  void completeDraft(String? pid, String id) => _drafts.completeDraft(pid, id);
  bool hasImportedBackup(String id) => _backup.hasImportedBackup(id);
  Map<String, String> importBackupRows(
    BackupRows rows,
    String backupId,
    Map<String, String> ids,
  ) => _backup.importBackupRows(rows, backupId, ids);
  BackupRows selectBackup(BackupSelection selection) =>
      _backup.selectBackup(selection);
}
