import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/domain/record_lookup.dart';
import 'package:care_notebook/infrastructure/care_database.dart';
import 'package:care_notebook/infrastructure/schema_migrations.dart';
import 'package:care_notebook/infrastructure/sqlite_session.dart';

void main() {
  late Directory root;
  late CareDatabase db;
  final key = Uint8List(32)..fillRange(0, 32, 19);
  final identity = Uint8List(32)..fillRange(0, 32, 37);
  String hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  Database raw() {
    final sql = sqlite3.open('${root.path}/care.db');
    sql.execute('PRAGMA key="x\'${hex(key)}\'"');
    sql.execute('ATTACH DATABASE ? AS identity KEY "x\'${hex(identity)}\'"', [
      '${root.path}/identity.db',
    ]);
    sql.execute('PRAGMA foreign_keys=ON');
    return sql;
  }

  void reopen() =>
      db = CareDatabase.open(root.path, key: key, identityKey: identity);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-longevity-');
    reopen();
  });
  tearDown(() async {
    db.close();
    await root.delete(recursive: true);
  });

  test('DATA-06 deployed v4 upgrades preserve histories, tasks, chats and identities', () {
    final pid = db.createPatient(alias: 'kept alias').id;
    final entry = db.saveEntry(
      pid,
      kind: EntryKind.generalNote,
      note: 'original',
      occurredAt: DateTime(2020),
    );
    db.saveEntry(
      pid,
      id: entry.id,
      expectedVersion: 1,
      kind: entry.kind,
      note: 'revision two',
      occurredAt: entry.occurredAt,
    );
    final task = db.saveTask(pid, title: 'kept task', dueAt: DateTime(2026));
    db.completeTask(pid, task.id, true);
    db.setChatRetention(pid, ChatRetention.forever);
    db.addChatMessage(pid, 'kept question');
    db.close();
    final sql = raw();
    sql.execute('''
      DROP INDEX entry_timeline; DROP INDEX entry_kind;
      DROP INDEX chat_expiration; DROP INDEX draft_expiration; DROP INDEX task_schedule;
      CREATE INDEX entry_timeline ON care_entry(patient_id,occurred_at DESC);
      CREATE INDEX entry_kind ON care_entry(patient_id,kind,occurred_at DESC);
      PRAGMA user_version=4; PRAGMA identity.user_version=4;
    ''');
    sql.close();
    reopen();
    expect(db.entries(pid).single.note, 'revision two');
    expect(db.entries(pid).single.version, 2);
    expect(db.revisions(pid, entry.id).single.note, 'original');
    expect(db.tasks(pid).single.done, isTrue);
    expect(db.chatMessages(pid).single.text, 'kept question');
    expect(db.patients().single.alias, 'kept alias');
    expect(root.listSync().where((f) => f.path.endsWith('.bak')), isEmpty);
    final check = raw();
    try {
      expect(check.select('PRAGMA user_version').single.values.single, 5);
      expect(
        check.select('PRAGMA identity.user_version').single.values.single,
        5,
      );
    } finally {
      check.close();
    }
  });

  test('DATA-05 SQLite full preserves the original error and rolls back both stores', () {
    final pid = db.createPatient(alias: 'committed identity').id;
    db.saveEntry(
      pid,
      kind: EntryKind.generalNote,
      note: 'committed record',
      occurredAt: DateTime(2020),
    );
    db.close();
    final sql = raw();
    try {
      sql.execute('CREATE TABLE capacity_probe(payload BLOB)');
      final pages = sql.select('PRAGMA page_count').single.values.single as int;
      sql.execute('PRAGMA max_page_count=$pages');
      final session = SqliteSession(sql, root.path);
      expect(
        () => session.transaction(() {
          sql.execute(
            "UPDATE identity.patient_identity SET alias='uncommitted identity' WHERE patient_id=?",
            [pid],
          );
          sql.execute(
            "UPDATE care_entry SET note='uncommitted record' WHERE patient_id=?",
            [pid],
          );
          // Limit this DB's page budget instead of filling the real device disk.
          sql.execute('INSERT INTO capacity_probe VALUES(zeroblob(2097152))');
        }),
        throwsA(
          isA<SqliteException>().having((e) => e.resultCode, 'SQLITE_FULL', 13),
        ),
      );
      expect(
        sql.select('SELECT note FROM care_entry').single['note'],
        'committed record',
      );
      expect(
        sql
            .select('SELECT alias FROM identity.patient_identity')
            .single['alias'],
        'committed identity',
      );
      session.transaction(() => sql.execute('DROP TABLE capacity_probe'));
    } finally {
      sql.close();
    }
    reopen();
    expect(db.entries(pid).single.note, 'committed record');
    expect(db.patients().single.alias, 'committed identity');
    db.verifyIntegrity();
  });

  test(
    'DATA-04 failed write and invalid task date preserve the saved task',
    () {
      final pid = db.createPatient().id;
      final task = db.saveTask(pid, title: 'keep task', dueAt: DateTime(2026));
      expect(
        () => db.saveTask(
          pid,
          id: task.id,
          title: 'invalid',
          dueAt: DateTime(2500),
        ),
        throwsA(isA<CareError>()),
      );
      db.close();
      final sql = raw();
      sql.execute(
        "CREATE TRIGGER fail_task BEFORE UPDATE ON care_task BEGIN SELECT RAISE(ABORT,'simulated write failure'); END;",
      );
      sql.close();
      reopen();
      expect(
        () => db.completeTask(pid, task.id, true),
        throwsA(isA<SqliteException>()),
      );
      expect(db.tasks(pid).single.title, 'keep task');
      expect(db.tasks(pid).single.done, isFalse);
    },
  );

  test('DATA-01 failed verification rolls back both databases and retains encrypted recovery copies', () {
    final pid = db.createPatient(alias: 'PRIVATE_IDENTITY_SENTINEL').id;
    db.saveEntry(
      pid,
      kind: EntryKind.generalNote,
      note: 'PRIVATE_RECORD_SENTINEL',
      occurredAt: DateTime(2020),
    );
    db.close();
    final sql = raw();
    try {
      sql.execute(
        'ALTER TABLE chat_message DROP COLUMN reply; PRAGMA user_version=3; PRAGMA identity.user_version=3;',
      );
      expect(
        () => SchemaMigrations(
          SqliteSession(sql, root.path),
          () => throw StateError('injected verification failure'),
        ).migrate(),
        throwsStateError,
      );
      expect(sql.select('PRAGMA user_version').single.values.single, 3);
      expect(
        sql.select('PRAGMA identity.user_version').single.values.single,
        3,
      );
      expect(
        sql
            .select('PRAGMA table_info(chat_message)')
            .any((r) => r['name'] == 'reply'),
        isFalse,
      );
      expect(
        sql.select('SELECT note FROM care_entry').single['note'],
        'PRIVATE_RECORD_SENTINEL',
      );
    } finally {
      sql.close();
    }
    final copies = root
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.bak'))
        .toList();
    expect(copies, hasLength(2));
    for (final f in copies) {
      final bytes = latin1.decode(f.readAsBytesSync());
      expect(bytes, isNot(contains('PRIVATE_RECORD_SENTINEL')));
      expect(bytes, isNot(contains('PRIVATE_IDENTITY_SENTINEL')));
    }
    reopen();
    expect(db.entries(pid).single.note, 'PRIVATE_RECORD_SENTINEL');
    expect(db.patients().single.alias, 'PRIVATE_IDENTITY_SENTINEL');
    expect(root.listSync().where((f) => f.path.endsWith('.bak')), isEmpty);
  });

  test('DATA-02 future or mismatched versions cannot initialize over existing records', () {
    final pid = db.createPatient().id;
    db.saveEntry(
      pid,
      kind: EntryKind.generalNote,
      note: 'keep across rejected update',
      occurredAt: DateTime(2020),
    );
    db.close();
    for (final versions in [(999, 999), (3, 4)]) {
      final sql = raw();
      sql.execute(
        'PRAGMA user_version=${versions.$1}; PRAGMA identity.user_version=${versions.$2};',
      );
      sql.close();
      expect(reopen, throwsA(isA<CareError>()));
      final check = raw();
      expect(
        check.select('SELECT note FROM care_entry').single['note'],
        'keep across rejected update',
      );
      check.close();
    }
    final sql = raw();
    sql.execute(
      'PRAGMA user_version=${SchemaMigrations.version}; PRAGMA identity.user_version=${SchemaMigrations.version};',
    );
    sql.close();
    reopen();
    expect(db.entries(pid), hasLength(1));
  });

  test('DATA-03 five years and 12000 entries preserve search limits, ties, revisions, expiration and patient isolation', () {
    final pid = db.createPatient().id, other = db.createPatient().id;
    db.setChatRetention(pid, ChatRetention.week);
    db.addChatMessage(pid, 'expired secret', now: DateTime(2020));
    db.close();
    final sql = raw();
    try {
      sql.execute('BEGIN IMMEDIATE');
      final insert = sql.prepare(
        'INSERT INTO care_entry(id,patient_id,kind,occurred_at,offset_minutes,note,created_at) VALUES(?,?,?,?,?,?,?)',
      );
      final detail = sql.prepare(
        'INSERT INTO general_note_entry(patient_id,entry_id) VALUES(?,?)',
      );
      for (var i = 0; i < 12000; i++) {
        final id = 'record-${i.toString().padLeft(6, '0')}';
        final owner = i % 5 == 0 ? other : pid;
        final at = DateTime(2020, 1, 1).add(Duration(days: i ~/ 7));
        insert.execute([
          id,
          owner,
          'generalNote',
          at.millisecondsSinceEpoch,
          0,
          i % 499 == 0 ? 'needle' : 'plain',
          at.millisecondsSinceEpoch,
        ]);
        detail.execute([owner, id]);
      }
      insert.close();
      detail.close();
      sql.execute('COMMIT');
      final plan = sql.select(
        'EXPLAIN QUERY PLAN SELECT * FROM care_entry WHERE patient_id=? ORDER BY occurred_at DESC,id DESC LIMIT 51',
        [pid],
      );
      expect(
        plan.any((r) => (r['detail'] as String).contains('TEMP B-TREE')),
        isFalse,
      );
    } finally {
      sql.close();
    }
    reopen();
    expect(db.chatMessages(pid), isEmpty);
    final all = db.entries(pid);
    expect(all, hasLength(9600));
    expect(
      db.entries(pid, limit: 51).map((e) => e.id),
      all.take(51).map((e) => e.id),
    );
    expect(
      db.entries(pid, query: 'needle', limit: 9).map((e) => e.id),
      all.where((e) => e.note == 'needle').take(9).map((e) => e.id),
    );
    final scope = RecordLookup(
      start: DateTime(2024, 8, 1),
      end: DateTime(2024, 9, 1),
    );
    expect(
      db.entries(pid, lookup: scope, limit: 9).map((e) => e.id),
      all.where(scope.matches).take(9).map((e) => e.id),
    );
    final original = all.first;
    db.saveEntry(
      pid,
      id: original.id,
      expectedVersion: original.version,
      kind: original.kind,
      occurredAt: original.occurredAt,
      note: 'updated',
    );
    db.close();
    reopen();
    expect(db.revisions(pid, original.id).single.note, original.note);
    expect(db.entry(other, original.id), isNull);
    db.verifyIntegrity();
  });
}
