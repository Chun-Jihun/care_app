import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../domain/records.dart';
import '../domain/chat.dart';

/// Encrypted persistence only. UI/application decide patient scope explicitly.
class CareDatabase {
  CareDatabase._(this._db, this.directory);
  final Database _db;
  final String directory;
  bool _closed = false;
  static const schemaVersion = 2;
  static String newId() => const Uuid().v7();

  static CareDatabase open(
    String directory, {
    required Uint8List key,
    required Uint8List identityKey,
  }) {
    if (key.length != 32 || identityKey.length != 32) {
      throw const CareError('저장소 키가 올바르지 않습니다.');
    }
    Directory(directory).createSync(recursive: true);
    final db = sqlite3.open(p.join(directory, 'care.db'));
    try {
      if (db.select('PRAGMA cipher_version').isEmpty) {
        throw const CareError('암호화 저장소를 사용할 수 없습니다.');
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
      store._migrate();
      store.verifyIntegrity();
      for (final name in ['care', 'identity']) {
        final backup = File(p.join(directory, '$name.migration-v1.bak'));
        if (backup.existsSync()) {
          backup.deleteSync();
        }
      }
      store.pruneChats();
      return store;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  T _transaction<T>(T Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _migrate() {
    final version = _db.select('PRAGMA user_version').first.values.first as int;
    final identityVersion =
        _db.select('PRAGMA identity.user_version').first.values.first as int;
    if (version > schemaVersion || identityVersion > schemaVersion) {
      throw const CareError('이 백업은 더 새 버전의 앱에서 만들어졌습니다. 앱을 업데이트해 주세요.');
    }
    if (version == schemaVersion && identityVersion == schemaVersion) {
      return;
    }
    if (version == 1 && identityVersion == 1) {
      _upgradeChatSchema();
      return;
    }
    if (version != 0 || identityVersion != 0) {
      throw const CareError('저장소 버전이 일치하지 않습니다. 원본을 보존했습니다.');
    }
    if (_db
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .isNotEmpty) {
      throw const CareError('알 수 없는 저장소 형식입니다. 원본을 보존했습니다.');
    }
    _transaction(() {
      _db.execute('''
        CREATE TABLE patient_context(id TEXT PRIMARY KEY, role TEXT NOT NULL, context TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL);
        CREATE TABLE identity.patient_identity(patient_id TEXT PRIMARY KEY, alias TEXT NOT NULL DEFAULT '', contact TEXT NOT NULL DEFAULT '');
        CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE care_entry(id TEXT PRIMARY KEY,patient_id TEXT NOT NULL,kind TEXT NOT NULL,occurred_at INTEGER NOT NULL,offset_minutes INTEGER NOT NULL,note TEXT NOT NULL DEFAULT '',version INTEGER NOT NULL DEFAULT 1 CHECK(version>0),source_type TEXT NOT NULL DEFAULT 'manual' CHECK(source_type='manual'),confirmation_status TEXT NOT NULL DEFAULT 'confirmed' CHECK(confirmation_status='confirmed'),created_at INTEGER NOT NULL,UNIQUE(patient_id,id),FOREIGN KEY(patient_id) REFERENCES patient_context(id) ON DELETE CASCADE);
        CREATE INDEX entry_timeline ON care_entry(patient_id,occurred_at DESC);
        CREATE INDEX entry_kind ON care_entry(patient_id,kind,occurred_at DESC);
        CREATE TABLE care_entry_revision(patient_id TEXT NOT NULL,entry_id TEXT NOT NULL,revision INTEGER NOT NULL,snapshot TEXT NOT NULL,changed_at INTEGER NOT NULL,PRIMARY KEY(patient_id,entry_id,revision),FOREIGN KEY(patient_id,entry_id) REFERENCES care_entry(patient_id,id) ON DELETE CASCADE);
        CREATE TABLE medication(id TEXT PRIMARY KEY,patient_id TEXT NOT NULL,name TEXT NOT NULL,active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1)),version INTEGER NOT NULL DEFAULT 1,UNIQUE(patient_id,id),FOREIGN KEY(patient_id) REFERENCES patient_context(id) ON DELETE CASCADE);
        CREATE TABLE medication_plan(id TEXT PRIMARY KEY,patient_id TEXT NOT NULL,medication_id TEXT NOT NULL,name TEXT NOT NULL,instruction TEXT NOT NULL,times TEXT NOT NULL,status TEXT NOT NULL CHECK(status IN ('active','superseded')),created_at INTEGER NOT NULL,UNIQUE(patient_id,id),FOREIGN KEY(patient_id,medication_id) REFERENCES medication(patient_id,id) ON DELETE CASCADE);
        CREATE UNIQUE INDEX one_active_plan ON medication_plan(patient_id,medication_id) WHERE status='active';
        CREATE TABLE care_task(id TEXT PRIMARY KEY,patient_id TEXT NOT NULL,title TEXT NOT NULL,note TEXT NOT NULL DEFAULT '',due_at INTEGER NOT NULL,done INTEGER NOT NULL DEFAULT 0 CHECK(done IN(0,1)),reminder INTEGER NOT NULL DEFAULT 0 CHECK(reminder IN(0,1)),UNIQUE(patient_id,id),FOREIGN KEY(patient_id) REFERENCES patient_context(id) ON DELETE CASCADE);
        CREATE TABLE visit_preparation(id TEXT PRIMARY KEY,patient_id TEXT NOT NULL,title TEXT NOT NULL,questions TEXT NOT NULL,stale INTEGER NOT NULL DEFAULT 0 CHECK(stale IN(0,1)),created_at INTEGER NOT NULL,UNIQUE(patient_id,id),FOREIGN KEY(patient_id) REFERENCES patient_context(id) ON DELETE CASCADE);
        CREATE TABLE visit_source(patient_id TEXT NOT NULL,visit_id TEXT NOT NULL,entry_id TEXT NOT NULL,entry_version INTEGER NOT NULL,PRIMARY KEY(patient_id,visit_id,entry_id),FOREIGN KEY(patient_id,visit_id) REFERENCES visit_preparation(patient_id,id) ON DELETE CASCADE,FOREIGN KEY(patient_id,entry_id) REFERENCES care_entry(patient_id,id) ON DELETE CASCADE);
        CREATE TABLE attachment(id TEXT PRIMARY KEY,patient_id TEXT NOT NULL,entry_id TEXT NOT NULL,wrapped_key TEXT NOT NULL,size INTEGER NOT NULL CHECK(size>0),FOREIGN KEY(patient_id,entry_id) REFERENCES care_entry(patient_id,id) ON DELETE CASCADE);
        CREATE TABLE pending_file_delete(id TEXT PRIMARY KEY);
        CREATE TABLE caregiver_checkin(id TEXT PRIMARY KEY,occurred_at INTEGER NOT NULL,fatigue TEXT NOT NULL,sleep TEXT NOT NULL,stress TEXT NOT NULL,note TEXT NOT NULL);
      ''');
      for (final kind in EntryKind.values) {
        final columns = kind.fields
            .map((f) => '${f.key} TEXT NOT NULL DEFAULT \'\'')
            .join(',');
        _db.execute(
          'CREATE TABLE ${kind.table}(patient_id TEXT NOT NULL,entry_id TEXT NOT NULL${columns.isEmpty ? '' : ',$columns'},PRIMARY KEY(patient_id,entry_id),FOREIGN KEY(patient_id,entry_id) REFERENCES care_entry(patient_id,id) ON DELETE CASCADE)',
        );
      }
      _db.execute('''
        ALTER TABLE medication_intake ADD COLUMN medication_id TEXT;
        ALTER TABLE medication_intake ADD COLUMN plan_id TEXT;
        ALTER TABLE medication_intake ADD COLUMN scheduled_at TEXT;
        CREATE UNIQUE INDEX one_scheduled_intake ON medication_intake(patient_id,plan_id,scheduled_at) WHERE scheduled_at IS NOT NULL;
        CREATE TRIGGER intake_med_scope BEFORE INSERT ON medication_intake WHEN NEW.medication_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM medication WHERE id=NEW.medication_id AND patient_id=NEW.patient_id) BEGIN SELECT RAISE(ABORT,'patient scope'); END;
        CREATE TRIGGER intake_plan_scope BEFORE INSERT ON medication_intake WHEN NEW.plan_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM medication_plan WHERE id=NEW.plan_id AND patient_id=NEW.patient_id AND medication_id=NEW.medication_id) BEGIN SELECT RAISE(ABORT,'plan scope'); END;
        CREATE TRIGGER intake_med_scope_update BEFORE UPDATE ON medication_intake WHEN NEW.medication_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM medication WHERE id=NEW.medication_id AND patient_id=NEW.patient_id) BEGIN SELECT RAISE(ABORT,'patient scope'); END;
        CREATE TRIGGER intake_plan_scope_update BEFORE UPDATE ON medication_intake WHEN NEW.plan_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM medication_plan WHERE id=NEW.plan_id AND patient_id=NEW.patient_id AND medication_id=NEW.medication_id) BEGIN SELECT RAISE(ABORT,'plan scope'); END;
        PRAGMA user_version=1;
        PRAGMA identity.user_version=1;
      ''');
    });
    _upgradeChatSchema();
  }

  void _upgradeChatSchema() {
    // Both copies remain encrypted with their existing keys. Atomic schema edits
    // keep v1 usable after a failed migration; remove copies before normal use.
    final backups = <File>[];
    try {
      for (final name in ['care', 'identity']) {
        backups.add(
          File(p.join(directory, '$name.db'))
              .copySync(p.join(directory, '$name.migration-v1.bak')),
        );
      }
      _transaction(() {
        _db.execute('''
          CREATE TABLE chat_policy(patient_id TEXT PRIMARY KEY,retention TEXT NOT NULL CHECK(retention IN ('session','7d','30d','forever')),FOREIGN KEY(patient_id) REFERENCES patient_context(id) ON DELETE CASCADE);
          CREATE TABLE chat_message(id TEXT PRIMARY KEY,patient_id TEXT NOT NULL,text TEXT NOT NULL CHECK(length(text)>0 AND length(text)<=20000),created_at INTEGER NOT NULL,expires_at INTEGER,FOREIGN KEY(patient_id) REFERENCES patient_context(id) ON DELETE CASCADE);
          CREATE INDEX chat_timeline ON chat_message(patient_id,created_at,id);
          PRAGMA user_version=2;
          PRAGMA identity.user_version=2;
        ''');
      });
    } finally {
      for (final file in backups) {
        if (file.existsSync()) {
          file.deleteSync();
        }
      }
    }
  }

  ChatRetention? chatRetention(String pid) {
    _patient(pid);
    final value = _db.select(
      'SELECT retention FROM chat_policy WHERE patient_id=?',
      [pid],
    ).firstOrNull?['retention'];
    return value == null
        ? null
        : ChatRetention.values.firstWhere((r) => r.code == value);
  }

  void setChatRetention(String pid, ChatRetention policy, {DateTime? now}) {
    _patient(pid);
    pruneChats(now: now);
    _transaction(() {
      _db.execute(
        'INSERT INTO chat_policy VALUES(?,?) ON CONFLICT(patient_id) DO UPDATE SET retention=excluded.retention',
        [pid, policy.code],
      );
      if (policy == ChatRetention.session) {
        _db.execute('DELETE FROM chat_message WHERE patient_id=?', [pid]);
      } else if (policy.days == null) {
        _db.execute(
          'UPDATE chat_message SET expires_at=NULL WHERE patient_id=?',
          [pid],
        );
      } else {
        _db.execute(
          'UPDATE chat_message SET expires_at=created_at+? WHERE patient_id=?',
          [Duration(days: policy.days!).inMilliseconds, pid],
        );
      }
    });
    pruneChats(now: now);
  }

  void pruneChats({DateTime? now}) => _db.execute(
    'DELETE FROM chat_message WHERE expires_at IS NOT NULL AND expires_at<=?',
    [(now ?? DateTime.now()).millisecondsSinceEpoch],
  );
  List<ChatMessage> chatMessages(String pid, {DateTime? now}) {
    _patient(pid);
    pruneChats(now: now);
    return _db
        .select(
          'SELECT * FROM chat_message WHERE patient_id=? ORDER BY created_at,id',
          [pid],
        )
        .map(
          (r) => ChatMessage(
            id: r['id'] as String,
            patientId: pid,
            text: r['text'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              r['created_at'] as int,
            ),
          ),
        )
        .toList();
  }

  ChatMessage addChatMessage(String pid, String text, {DateTime? now}) {
    final policy = chatRetention(pid);
    if (policy == null || policy == ChatRetention.session) {
      throw const CareError('기기에 보관할 대화 기간을 먼저 선택해 주세요.');
    }
    if (text.trim().isEmpty || text.length > 20000) {
      throw const CareError('질문을 1~20,000자로 입력해 주세요.');
    }
    final at = now ?? DateTime.now(), id = newId();
    _db.execute('INSERT INTO chat_message VALUES(?,?,?,?,?)', [
      id,
      pid,
      text.trim(),
      at.millisecondsSinceEpoch,
      policy.days == null
          ? null
          : at.add(Duration(days: policy.days!)).millisecondsSinceEpoch,
    ]);
    return ChatMessage(
      id: id,
      patientId: pid,
      text: text.trim(),
      createdAt: at,
    );
  }

  void deleteChatMessage(String pid, String id) {
    _scoped('chat_message', pid, id);
    _db.execute('DELETE FROM chat_message WHERE patient_id=? AND id=?', [
      pid,
      id,
    ]);
  }

  void clearChatMessages(String pid) {
    _patient(pid);
    _db.execute('DELETE FROM chat_message WHERE patient_id=?', [pid]);
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
      throw const CareError('기록의 수첩 연결이 일치하지 않습니다.');
    }
    for (final schema in ['main', 'identity']) {
      if (_db
              .select('PRAGMA $schema.integrity_check')
              .any((r) => r.values.first != 'ok') ||
          _db.select('PRAGMA $schema.foreign_key_check').isNotEmpty) {
        throw const CareError('저장소 무결성을 확인하지 못했습니다. 원본을 보존했습니다.');
      }
    }
    for (final kind in EntryKind.values) {
      if (_db.select(
        'SELECT e.id FROM care_entry e LEFT JOIN ${kind.table} d ON d.patient_id=e.patient_id AND d.entry_id=e.id WHERE e.kind=? AND d.entry_id IS NULL',
        [kind.name],
      ).isNotEmpty) {
        throw const CareError('기록의 상세 정보가 누락되어 있습니다.');
      }
    }
  }

  void close() {
    if (!_closed) {
      _db.close();
      _closed = true;
    }
  }

  void _patient(String id) {
    if (_db.select('SELECT id FROM patient_context WHERE id=?', [id]).isEmpty) {
      throw const CareError('선택한 돌봄 대상을 찾을 수 없습니다.');
    }
  }

  void _scoped(String table, String patientId, String id) {
    _patient(patientId);
    if (_db.select('SELECT id FROM $table WHERE patient_id=? AND id=?', [
      patientId,
      id,
    ]).isEmpty) {
      throw const CareError('현재 수첩의 항목을 찾을 수 없습니다.');
    }
  }

  String? setting(String key) =>
      _db.select('SELECT value FROM settings WHERE key=?', [
            key,
          ]).firstOrNull?['value']
          as String?;
  void setSetting(String key, String value) => _db.execute(
    'INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );

  List<Patient> patients() => _db
      .select(
        'SELECT c.*,i.alias,i.contact FROM patient_context c LEFT JOIN identity.patient_identity i ON i.patient_id=c.id ORDER BY c.created_at,c.id',
      )
      .map(
        (r) => Patient(
          r['id'] as String,
          (r['alias'] ?? '') as String,
          r['role'] as String,
          r['context'] as String,
          (r['contact'] ?? '') as String,
        ),
      )
      .toList();
  Patient createPatient({
    String alias = '',
    String role = 'family',
    String context = '',
    String contact = '',
  }) {
    if (!['self', 'family', 'cohabitant', 'caregiver'].contains(role)) {
      throw const CareError('작성자 역할을 다시 선택해 주세요.');
    }
    final id = newId();
    _transaction(() {
      _db.execute('INSERT INTO patient_context VALUES(?,?,?,?)', [
        id,
        role,
        context,
        DateTime.now().millisecondsSinceEpoch,
      ]);
      _db.execute('INSERT INTO identity.patient_identity VALUES(?,?,?)', [
        id,
        alias.trim(),
        contact.trim(),
      ]);
    });
    return patients().firstWhere((p) => p.id == id);
  }

  void updatePatient(
    String id, {
    required String alias,
    required String role,
    required String context,
    required String contact,
  }) {
    _patient(id);
    if (!['self', 'family', 'cohabitant', 'caregiver'].contains(role)) {
      throw const CareError('작성자 역할을 다시 선택해 주세요.');
    }
    _transaction(() {
      _db.execute('UPDATE patient_context SET role=?,context=? WHERE id=?', [
        role,
        context,
        id,
      ]);
      _db.execute(
        'UPDATE identity.patient_identity SET alias=?,contact=? WHERE patient_id=?',
        [alias.trim(), contact.trim(), id],
      );
    });
  }

  void deletePatient(String id) {
    _patient(id);
    _transaction(() {
      _db.execute(
        'INSERT OR IGNORE INTO pending_file_delete SELECT id FROM attachment WHERE patient_id=?',
        [id],
      );
      _db.execute('DELETE FROM patient_context WHERE id=?', [id]);
      _db.execute('DELETE FROM identity.patient_identity WHERE patient_id=?', [
        id,
      ]);
      _db.execute(
        "DELETE FROM settings WHERE key='selected_patient' AND value=?",
        [id],
      );
    });
  }

  CareEntry _entry(Row r) {
    final kind = EntryKind.values.byName(r['kind'] as String);
    final detail = _db.select(
      'SELECT * FROM ${kind.table} WHERE patient_id=? AND entry_id=?',
      [r['patient_id'], r['id']],
    ).single;
    return CareEntry(
      id: r['id'] as String,
      patientId: r['patient_id'] as String,
      kind: kind,
      occurredAt: DateTime.fromMillisecondsSinceEpoch(
        r['occurred_at'] as int,
        isUtc: true,
      ).toLocal(),
      offsetMinutes: r['offset_minutes'] as int,
      note: r['note'] as String,
      fields: {
        for (final field in detail.keys.where(
          (k) => k != 'patient_id' && k != 'entry_id',
        ))
          field: detail[field]?.toString() ?? '',
      },
      version: r['version'] as int,
    );
  }

  List<CareEntry> entries(
    String patientId, {
    EntryKind? kind,
    String query = '',
    DateTime? day,
    int? limit,
  }) {
    _patient(patientId);
    final args = <Object?>[patientId];
    var where = 'patient_id=?';
    if (kind != null) {
      where += ' AND kind=?';
      args.add(kind.name);
    }
    if (day != null) {
      final start = DateTime(day.year, day.month, day.day);
      where += ' AND occurred_at>=? AND occurred_at<?';
      args.addAll([
        start.millisecondsSinceEpoch,
        DateTime(day.year, day.month, day.day + 1).millisecondsSinceEpoch,
      ]);
    }
    // Search inside the encrypted store's scoped result; no plaintext search index.
    var result = _db
        .select(
          'SELECT * FROM care_entry WHERE $where ORDER BY occurred_at DESC,id DESC',
          args,
        )
        .map(_entry)
        .where(
          (e) =>
              query.trim().isEmpty ||
              e.summary.toLowerCase().contains(query.trim().toLowerCase()),
        )
        .toList();
    if (limit != null) {
      result = result.take(limit).toList();
    }
    return result;
  }

  CareEntry saveEntry(
    String patientId, {
    String? id,
    int? expectedVersion,
    required EntryKind kind,
    required DateTime occurredAt,
    String note = '',
    Map<String, String> fields = const {},
  }) {
    _patient(patientId);
    validateEntry(kind, fields, note);
    if (occurredAt.year < 1900 || occurredAt.year > 2200) {
      throw const CareError('기록 시각을 확인해 주세요.');
    }
    final entryId = id ?? newId();
    return _transaction(
      () => _writeEntry(
        patientId,
        id: entryId,
        isNew: id == null,
        expectedVersion: expectedVersion,
        kind: kind,
        occurredAt: occurredAt,
        note: note.trim(),
        fields: fields,
      ),
    );
  }

  CareEntry _writeEntry(
    String patientId, {
    required String id,
    required bool isNew,
    int? expectedVersion,
    required EntryKind kind,
    required DateTime occurredAt,
    required String note,
    required Map<String, String> fields,
  }) {
    if (!isNew) {
      _scoped('care_entry', patientId, id);
      final old = _entry(
        _db.select('SELECT * FROM care_entry WHERE patient_id=? AND id=?', [
          patientId,
          id,
        ]).single,
      );
      if (old.version != expectedVersion) {
        throw const CareError('다른 화면에서 수정된 기록입니다. 다시 열어 확인해 주세요.');
      }
      if (old.kind != kind) {
        throw const CareError('기록 종류는 변경할 수 없습니다.');
      }
      _db.execute('INSERT INTO care_entry_revision VALUES(?,?,?,?,?)', [
        patientId,
        id,
        old.version,
        jsonEncode(old.toJson()),
        DateTime.now().millisecondsSinceEpoch,
      ]);
      _markVisitsStale(patientId, id);
      _db.execute(
        'UPDATE care_entry SET occurred_at=?,offset_minutes=?,note=?,version=version+1 WHERE patient_id=? AND id=?',
        [
          occurredAt.millisecondsSinceEpoch,
          occurredAt.timeZoneOffset.inMinutes,
          note,
          patientId,
          id,
        ],
      );
      final columns = kind.fields.map((f) => f.key).toList();
      if (columns.isNotEmpty) {
        _db.execute(
          'UPDATE ${kind.table} SET ${columns.map((c) => '$c=?').join(',')} WHERE patient_id=? AND entry_id=?',
          [...columns.map((c) => fields[c]?.trim() ?? ''), patientId, id],
        );
      }
    } else {
      _db.execute(
        'INSERT INTO care_entry(id,patient_id,kind,occurred_at,offset_minutes,note,created_at) VALUES(?,?,?,?,?,?,?)',
        [
          id,
          patientId,
          kind.name,
          occurredAt.millisecondsSinceEpoch,
          occurredAt.timeZoneOffset.inMinutes,
          note,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
      final keys = kind.fields.map((f) => f.key).toList();
      _db.execute(
        'INSERT INTO ${kind.table}(patient_id,entry_id${keys.isEmpty ? '' : ',${keys.join(',')}'}) VALUES(${List.filled(2 + keys.length, '?').join(',')})',
        [patientId, id, ...keys.map((k) => fields[k]?.trim() ?? '')],
      );
    }
    return _entry(
      _db.select('SELECT * FROM care_entry WHERE patient_id=? AND id=?', [
        patientId,
        id,
      ]).single,
    );
  }

  void _markVisitsStale(String pid, String eid) => _db.execute(
    'UPDATE visit_preparation SET stale=1 WHERE patient_id=? AND id IN(SELECT visit_id FROM visit_source WHERE patient_id=? AND entry_id=?)',
    [pid, pid, eid],
  );
  List<Map<String, dynamic>> revisions(String pid, String id) {
    _patient(pid);
    return _db
        .select(
          'SELECT snapshot FROM care_entry_revision WHERE patient_id=? AND entry_id=? ORDER BY revision DESC',
          [pid, id],
        )
        .map((r) => jsonDecode(r['snapshot'] as String) as Map<String, dynamic>)
        .toList();
  }

  void deleteEntry(String pid, String id) {
    _scoped('care_entry', pid, id);
    _transaction(() {
      _markVisitsStale(pid, id);
      _db.execute(
        'INSERT OR IGNORE INTO pending_file_delete SELECT id FROM attachment WHERE patient_id=? AND entry_id=?',
        [pid, id],
      );
      _db.execute('DELETE FROM care_entry WHERE patient_id=? AND id=?', [
        pid,
        id,
      ]);
    });
  }

  List<Medication> medications(String pid, {bool includeArchived = false}) {
    _patient(pid);
    return _db
        .select(
          "SELECT m.*,p.id AS plan_id,p.instruction,p.times FROM medication m JOIN medication_plan p ON p.patient_id=m.patient_id AND p.medication_id=m.id AND p.status='active' WHERE m.patient_id=? ${includeArchived ? '' : 'AND m.active=1'} ORDER BY m.name",
          [pid],
        )
        .map(
          (r) => Medication(
            r['id'] as String,
            r['name'] as String,
            r['instruction'] as String,
            List<String>.from(jsonDecode(r['times'] as String)),
            r['active'] == 1,
            r['plan_id'] as String,
            r['version'] as int,
          ),
        )
        .toList();
  }

  Medication saveMedication(
    String pid, {
    String? id,
    int? expectedVersion,
    required String name,
    required String instruction,
    required List<String> times,
  }) {
    _patient(pid);
    if (name.trim().isEmpty) {
      throw const CareError('약 이름을 입력해 주세요.');
    }
    final normalized =
        times.map((t) => t.trim()).where((t) => t.isNotEmpty).toSet().toList()
          ..sort();
    if (normalized.any(
      (t) => !RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(t),
    )) {
      throw const CareError('복약 시각은 08:00처럼 입력해 주세요.');
    }
    final medId = id ?? newId();
    _transaction(() {
      if (id == null) {
        _db.execute(
          'INSERT INTO medication(id,patient_id,name) VALUES(?,?,?)',
          [medId, pid, name.trim()],
        );
      } else {
        _scoped('medication', pid, id);
        final old = medications(
          pid,
          includeArchived: true,
        ).firstWhere((m) => m.id == id);
        if (expectedVersion != null && old.version != expectedVersion) {
          throw const CareError('약 정보가 변경되었습니다. 다시 열어 주세요.');
        }
        _db.execute(
          'UPDATE medication SET name=?,version=version+1 WHERE patient_id=? AND id=?',
          [name.trim(), pid, id],
        );
        _db.execute(
          "UPDATE medication_plan SET status='superseded' WHERE patient_id=? AND medication_id=? AND status='active'",
          [pid, id],
        );
      }
      _db.execute(
        "INSERT INTO medication_plan VALUES(?,?,?,?,?,?,'active',?)",
        [
          newId(),
          pid,
          medId,
          name.trim(),
          instruction.trim(),
          jsonEncode(normalized),
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    });
    return medications(
      pid,
      includeArchived: true,
    ).firstWhere((m) => m.id == medId);
  }

  List<Map<String, Object?>> medicationPlans(String pid, String id) {
    _scoped('medication', pid, id);
    return _db
        .select(
          'SELECT * FROM medication_plan WHERE patient_id=? AND medication_id=? ORDER BY created_at DESC,id DESC',
          [pid, id],
        )
        .map((r) => Map<String, Object?>.from(r))
        .toList();
  }

  void archiveMedication(String pid, String id, bool archive) {
    _scoped('medication', pid, id);
    _db.execute(
      'UPDATE medication SET active=?,version=version+1 WHERE patient_id=? AND id=?',
      [archive ? 0 : 1, pid, id],
    );
  }

  CareEntry recordIntake(
    String pid,
    String medId,
    String status,
    DateTime at, {
    String reason = '',
    String reaction = '',
    DateTime? scheduledAt,
  }) {
    _scoped('medication', pid, medId);
    final med = medications(
      pid,
      includeArchived: true,
    ).firstWhere((m) => m.id == medId);
    if (!intakeLabels.containsKey(status)) {
      throw const CareError('복용 상태를 선택해 주세요.');
    }
    final scheduled = scheduledAt?.toUtc().toIso8601String();
    if (scheduled != null &&
        _db.select(
          'SELECT entry_id FROM medication_intake WHERE patient_id=? AND plan_id=? AND scheduled_at=?',
          [pid, med.planId, scheduled],
        ).isNotEmpty) {
      throw const CareError('이미 기록한 예정 시각입니다. 기존 기록을 수정해 주세요.');
    }
    return _transaction(() {
      final result = _writeEntry(
        pid,
        id: newId(),
        isNew: true,
        kind: EntryKind.medicationIntake,
        occurredAt: at,
        note: '',
        fields: {
          'medicine': med.name,
          'status': status,
          'reason': reason,
          'reaction': reaction,
          'instruction': med.instruction,
        },
      );
      _db.execute(
        'UPDATE medication_intake SET medication_id=?,plan_id=?,scheduled_at=? WHERE patient_id=? AND entry_id=?',
        [med.id, med.planId, scheduled, pid, result.id],
      );
      return result;
    });
  }

  List<CareTask> tasks(String pid) {
    _patient(pid);
    return _db
        .select(
          'SELECT * FROM care_task WHERE patient_id=? ORDER BY done,due_at',
          [pid],
        )
        .map(
          (r) => CareTask(
            r['id'] as String,
            r['title'] as String,
            r['note'] as String,
            DateTime.fromMillisecondsSinceEpoch(r['due_at'] as int),
            r['done'] == 1,
            r['reminder'] == 1,
          ),
        )
        .toList();
  }

  CareTask saveTask(
    String pid, {
    String? id,
    required String title,
    String note = '',
    required DateTime dueAt,
    bool reminder = false,
  }) {
    _patient(pid);
    if (title.trim().isEmpty) {
      throw const CareError('할 일을 입력해 주세요.');
    }
    final taskId = id ?? newId();
    if (id != null) {
      _scoped('care_task', pid, id);
      _db.execute(
        'UPDATE care_task SET title=?,note=?,due_at=?,reminder=? WHERE patient_id=? AND id=?',
        [
          title.trim(),
          note.trim(),
          dueAt.millisecondsSinceEpoch,
          reminder ? 1 : 0,
          pid,
          id,
        ],
      );
    } else {
      _db.execute(
        'INSERT INTO care_task(id,patient_id,title,note,due_at,reminder) VALUES(?,?,?,?,?,?)',
        [
          taskId,
          pid,
          title.trim(),
          note.trim(),
          dueAt.millisecondsSinceEpoch,
          reminder ? 1 : 0,
        ],
      );
    }
    return tasks(pid).firstWhere((t) => t.id == taskId);
  }

  void completeTask(String pid, String id, bool done) {
    _scoped('care_task', pid, id);
    _db.execute('UPDATE care_task SET done=? WHERE patient_id=? AND id=?', [
      done ? 1 : 0,
      pid,
      id,
    ]);
  }

  void deleteTask(String pid, String id) {
    _scoped('care_task', pid, id);
    _db.execute('DELETE FROM care_task WHERE patient_id=? AND id=?', [pid, id]);
  }

  List<VisitPreparation> visits(String pid) {
    _patient(pid);
    return _db
        .select(
          'SELECT * FROM visit_preparation WHERE patient_id=? ORDER BY created_at DESC',
          [pid],
        )
        .map(
          (r) => VisitPreparation(
            r['id'] as String,
            r['title'] as String,
            r['questions'] as String,
            r['stale'] == 1,
            DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
          ),
        )
        .toList();
  }

  VisitPreparation saveVisit(
    String pid, {
    String? id,
    required String title,
    required String questions,
    required List<String> entryIds,
  }) {
    _patient(pid);
    if (title.trim().isEmpty) {
      throw const CareError('진료 준비 제목을 입력해 주세요.');
    }
    final vid = id ?? newId();
    _transaction(() {
      for (final eid in entryIds) {
        _scoped('care_entry', pid, eid);
      }
      if (id != null) {
        _scoped('visit_preparation', pid, id);
        _db.execute(
          'UPDATE visit_preparation SET title=?,questions=?,stale=0 WHERE patient_id=? AND id=?',
          [title.trim(), questions.trim(), pid, id],
        );
        _db.execute(
          'DELETE FROM visit_source WHERE patient_id=? AND visit_id=?',
          [pid, id],
        );
      } else {
        _db.execute(
          'INSERT INTO visit_preparation(id,patient_id,title,questions,created_at) VALUES(?,?,?,?,?)',
          [
            vid,
            pid,
            title.trim(),
            questions.trim(),
            DateTime.now().millisecondsSinceEpoch,
          ],
        );
      }
      for (final eid in entryIds.toSet()) {
        _db.execute(
          'INSERT INTO visit_source SELECT patient_id,?,id,version FROM care_entry WHERE patient_id=? AND id=?',
          [vid, pid, eid],
        );
      }
    });
    return visits(pid).firstWhere((v) => v.id == vid);
  }

  List<CareEntry> visitEntries(String pid, String id) {
    _scoped('visit_preparation', pid, id);
    return _db
        .select(
          'SELECT e.* FROM care_entry e JOIN visit_source s ON s.patient_id=e.patient_id AND s.entry_id=e.id WHERE s.patient_id=? AND s.visit_id=? ORDER BY e.occurred_at',
          [pid, id],
        )
        .map(_entry)
        .toList();
  }

  void deleteVisit(String pid, String id) {
    _scoped('visit_preparation', pid, id);
    _db.execute('DELETE FROM visit_preparation WHERE patient_id=? AND id=?', [
      pid,
      id,
    ]);
  }

  String visitText(String pid, String id) {
    final v = visits(pid).firstWhere((v) => v.id == id);
    return [
      '${v.title}${v.stale ? ' (원본 변경 — 재검토 필요)' : ''}',
      '질문\n${v.questions}',
      '선택한 기록',
      ...visitEntries(pid, id).map(
        (e) =>
            '${e.occurredAt.toString().substring(0, 16)} ${e.kind.label}\n${e.summary}',
      ),
    ].join('\n\n');
  }

  List<Attachment> attachments(String pid, String eid) {
    _scoped('care_entry', pid, eid);
    return _db
        .select('SELECT * FROM attachment WHERE patient_id=? AND entry_id=?', [
          pid,
          eid,
        ])
        .map(
          (r) => Attachment(
            r['id'] as String,
            eid,
            r['wrapped_key'] as String,
            r['size'] as int,
          ),
        )
        .toList();
  }

  void addAttachment(
    String pid,
    String eid,
    String id,
    String wrappedKey,
    int size,
  ) {
    _scoped('care_entry', pid, eid);
    _db.execute('INSERT INTO attachment VALUES(?,?,?,?,?)', [
      id,
      pid,
      eid,
      wrappedKey,
      size,
    ]);
  }

  void deleteAttachment(String pid, String id) {
    _scoped('attachment', pid, id);
    _transaction(() {
      _db.execute('INSERT OR IGNORE INTO pending_file_delete VALUES(?)', [id]);
      _db.execute('DELETE FROM attachment WHERE patient_id=? AND id=?', [
        pid,
        id,
      ]);
    });
  }

  List<String> get pendingFileDeletes => _db
      .select('SELECT id FROM pending_file_delete')
      .map((r) => r['id'] as String)
      .toList();
  void finishFileDelete(String id) =>
      _db.execute('DELETE FROM pending_file_delete WHERE id=?', [id]);
  List<String> get allAttachmentIds => _db
      .select('SELECT id FROM attachment')
      .map((r) => r['id'] as String)
      .toList();

  void addCheckin({
    required String fatigue,
    required String sleep,
    required String stress,
    String note = '',
  }) {
    _db.execute('INSERT INTO caregiver_checkin VALUES(?,?,?,?,?,?)', [
      newId(),
      DateTime.now().millisecondsSinceEpoch,
      fatigue,
      sleep,
      stress,
      note,
    ]);
  }

  List<Map<String, Object?>> checkins() => _db
      .select('SELECT * FROM caregiver_checkin ORDER BY occurred_at DESC')
      .map((r) => Map<String, Object?>.from(r))
      .toList();
  void deleteCheckin(String id) =>
      _db.execute('DELETE FROM caregiver_checkin WHERE id=?', [id]);
}
