import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/records.dart';
import 'sqlite_session.dart';

final class SchemaMigrations {
  SchemaMigrations(this._store, this._verify);
  static const version = 3;
  final SqliteSession _store;
  final void Function() _verify;
  String get directory => _store.directory;
  void migrate() {
    final version =
        _store.connection.select('PRAGMA user_version').first.values.first
            as int;
    final identityVersion =
        _store.connection
                .select('PRAGMA identity.user_version')
                .first
                .values
                .first
            as int;
    if (version > SchemaMigrations.version ||
        identityVersion > SchemaMigrations.version) {
      throw CareError(CareErrorCode.newerStorageVersion);
    }
    if (version == SchemaMigrations.version &&
        identityVersion == SchemaMigrations.version) {
      return;
    }
    if (version == 1 && identityVersion == 1) {
      _upgradeChatSchema();
      _upgradeDraftSchema();
      return;
    }
    if (version == 2 && identityVersion == 2) {
      _upgradeDraftSchema();
      return;
    }
    if (version != 0 || identityVersion != 0) {
      throw CareError(CareErrorCode.storageVersionMismatch);
    }
    if (_store.connection
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .isNotEmpty) {
      throw CareError(CareErrorCode.unknownStorageFormat);
    }
    _store.transaction(() {
      _store.connection.execute('''
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
        _store.connection.execute(
          'CREATE TABLE ${kind.table}(patient_id TEXT NOT NULL,entry_id TEXT NOT NULL${columns.isEmpty ? '' : ',$columns'},PRIMARY KEY(patient_id,entry_id),FOREIGN KEY(patient_id,entry_id) REFERENCES care_entry(patient_id,id) ON DELETE CASCADE)',
        );
      }
      _store.connection.execute('''
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
    _upgradeDraftSchema();
  }

  void _upgradeChatSchema() {
    final backups = <File>[];
    try {
      for (final name in ['care', 'identity']) {
        backups.add(
          File(p.join(directory, '$name.db'))
              .copySync(p.join(directory, '$name.migration-v1.bak')),
        );
      }
      _store.transaction(() {
        _store.connection.execute('''
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

  void _upgradeDraftSchema() {
    final backups = <File>[];
    try {
      for (final name in ['care', 'identity']) {
        backups.add(
          File(p.join(directory, '$name.db'))
              .copySync(p.join(directory, '$name.migration-v2.bak')),
        );
      }
      _store.transaction(() {
        _store.connection.execute('''
          CREATE TABLE record_draft(
            id TEXT PRIMARY KEY, patient_id TEXT, type TEXT NOT NULL
              CHECK(type IN ('entry','medication','intake','task','visit','checkin')),
            target_id TEXT, base TEXT, payload TEXT NOT NULL,
            updated_at INTEGER NOT NULL, expires_at INTEGER,
            CHECK((type='checkin' AND patient_id IS NULL) OR (type!='checkin' AND patient_id IS NOT NULL)),
            FOREIGN KEY(patient_id) REFERENCES patient_context(id) ON DELETE CASCADE);
          CREATE INDEX draft_scope ON record_draft(patient_id,updated_at DESC);
          CREATE TABLE imported_backup(id TEXT PRIMARY KEY, imported_at INTEGER NOT NULL, patient_ids TEXT NOT NULL, checkin_ids TEXT NOT NULL);
          PRAGMA user_version=3;
          PRAGMA identity.user_version=3;
        ''');
      });
      _verify();
    } finally {
      for (final file in backups) {
        if (file.existsSync()) file.deleteSync();
      }
    }
  }
}
