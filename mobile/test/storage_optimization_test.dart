import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:care_notebook/domain/backup.dart';
import 'package:care_notebook/domain/drug_safety.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/care_database.dart';
import 'package:care_notebook/infrastructure/repositories/medications.dart';
import 'package:care_notebook/infrastructure/repositories/records.dart';
import 'package:care_notebook/infrastructure/repositories/visits.dart';
import 'package:care_notebook/infrastructure/sqlite_session.dart';

class CountingDatabase implements Database {
  CountingDatabase(this.delegate);
  final Database delegate;
  int reads = 0;
  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) {
    reads++;
    return delegate.select(sql, parameters);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Before optimizing: preserve patient/version boundaries and exact snapshots;
// reject unrestorable input before committing; bound range queries in storage.
void main() {
  late Directory root;
  late CareDatabase db;
  final key = Uint8List(32)..fillRange(0, 32, 31);
  final identity = Uint8List(32)..fillRange(0, 32, 47);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-storage-optimization-');
    db = CareDatabase.open(root.path, key: key, identityKey: identity);
  });
  tearDown(() async {
    db.close();
    await root.delete(recursive: true);
  });

  test('task pages and counts stay scoped across complete and undo', () {
    final pid = db.createPatient().id, other = db.createPatient().id;
    for (var i = 0; i < 75; i++) {
      final task = db.saveTask(
        pid,
        title: 'task $i',
        dueAt: DateTime(2026, 9, 23),
      );
      if (i < 60) db.completeTask(pid, task.id, true);
    }
    db.saveTask(other, title: 'other notebook', dueAt: DateTime(2026));
    expect(db.taskCount(pid), 75);
    expect(db.taskCount(pid, done: false), 15);
    expect(db.tasks(pid, done: false, limit: 5), hasLength(5));
    expect(db.tasks(pid, done: true, limit: 51), hasLength(51));
    expect(db.tasks(pid, limit: -1), isEmpty);
    final completed = db.tasks(pid, done: true, limit: 1).single;
    db.completeTask(pid, completed.id, false);
    expect(db.taskCount(pid, done: false), 16);
    db.deleteTask(pid, completed.id);
    expect(db.taskCount(pid), 74);
    expect(db.taskCount(other), 1);
  });

  test('caregiver history returns only the requested page in stable order', () {
    for (var i = 0; i < 85; i++) {
      db.addCheckin(fatigue: '', sleep: '', stress: '', note: 'checkin $i');
    }
    final all = db.checkins();
    expect(
      db.checkins(limit: 31).map((r) => r.id),
      all.take(31).map((r) => r.id),
    );
    expect(db.checkins(limit: 61), hasLength(61));
    expect(db.checkins(limit: 0), isEmpty);
    expect(db.checkins(limit: -1), isEmpty);
    db.deleteCheckin(all.first.id);
    expect(db.checkins(limit: 31).first.id, all[1].id);
  });

  test(
    'linked intake rejects unrestorable input and returns committed links',
    () {
      final pid = db.createPatient().id;
      final med = db.saveMedication(
        pid,
        name: 'medicine',
        instruction: 'exact direction',
        times: [],
      );
      for (final action in <void Function()>[
        () => db.recordIntake(pid, med.id, 'taken', DateTime(1899)),
        () => db.recordIntake(
          pid,
          med.id,
          'taken',
          DateTime(2026),
          reason: 'x' * 4001,
        ),
        () => db.recordIntake(
          pid,
          med.id,
          'taken',
          DateTime(2026),
          reaction: 'x' * 4001,
        ),
      ]) {
        expect(action, throwsA(isA<CareError>()));
        expect(db.entries(pid), isEmpty);
      }
      final at = DateTime(2026, 9, 23, 9);
      final entry = db.recordIntake(pid, med.id, 'taken', at, scheduledAt: at);
      expect(entry.toJson(), db.entry(pid, entry.id)!.toJson());
      expect(entry.fields['medication_id'], med.id);
      expect(entry.fields['plan_id'], med.planId);
      expect(entry.fields['instruction'], med.instruction);
      final rows = db.selectBackup(BackupSelection(patientIds: {pid}));
      final ids = <String, String>{
        for (final table in rows.values)
          for (final row in table)
            if (row['id'] is String) row['id'] as String: CareDatabase.newId(),
      };
      final imported = db.importBackupRows(rows, 'optimization-test', ids);
      expect(
        db.entries(imported[pid]!).single.fields['instruction'],
        med.instruction,
      );
    },
  );

  test(
    'a medication cannot introduce fields its future intake cannot restore',
    () {
      final pid = db.createPatient().id;
      for (final fields in [('x' * 4001, ''), ('medicine', 'x' * 4001)]) {
        expect(
          () => db.saveMedication(
            pid,
            name: fields.$1,
            instruction: fields.$2,
            times: [],
          ),
          throwsA(isA<CareError>()),
        );
        expect(db.medications(pid), isEmpty);
      }
    },
  );

  test(
    'range search keeps older matches, stable limits and patient isolation',
    () {
      final pid = db.createPatient().id, other = db.createPatient().id;
      for (var i = 0; i < 450; i++) {
        db.saveEntry(
          pid,
          kind: EntryKind.generalNote,
          note: i < 40 ? 'old match' : 'recent',
          occurredAt: DateTime(2024, 1, 1).add(Duration(days: i)),
        );
      }
      db.saveEntry(
        other,
        kind: EntryKind.generalNote,
        note: 'old match',
        occurredAt: DateTime(2024, 1, 2),
      );
      final from = DateTime(2024, 1, 1), until = DateTime(2024, 2, 1);
      final page = db.entries(
        pid,
        from: from,
        until: until,
        query: 'old match',
        limit: 30,
      );
      expect(page, hasLength(30));
      expect(
        page.every(
          (e) =>
              e.patientId == pid &&
              !e.occurredAt.isBefore(from) &&
              e.occurredAt.isBefore(until),
        ),
        true,
      );
      expect(
        db.entries(pid, from: from, until: until, limit: 31),
        hasLength(31),
      );
      expect(db.entries(pid, query: 'old match', limit: 41), hasLength(40));
      expect(db.entries(pid, from: until, until: from), isEmpty);
    },
  );

  test('medication and intake reads have bounded query counts and preserve confirmation versions', () {
    final pid = db.createPatient().id;
    final meds = [
      for (var i = 0; i < 25; i++)
        db.saveMedication(
          pid,
          name: 'medicine $i',
          instruction: 'direction $i',
          times: [],
        ),
    ];
    db.confirmMedicationProduct(
      pid,
      meds.first.id,
      1,
      MedicationProduct(
        '123456789',
        'confirmed product',
        'a' * 64,
        DateTime(2026),
      ),
    );
    for (var i = 0; i < 25; i++) {
      db.recordIntake(pid, meds.first.id, 'taken', DateTime(2026, 9, 23, 0, i));
    }
    final visit = db.saveVisit(
      pid,
      title: 'review',
      questions: '',
      entryIds: db.entries(pid).map((e) => e.id).toList(),
    );
    final sql = sqlite3.open('${root.path}/care.db');
    final encoded = key.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    sql.execute('PRAGMA key="x\'$encoded\'"');
    try {
      final counted = CountingDatabase(sql);
      final store = SqliteSession(counted, root.path);
      final repository = SqliteMedications(store, SqliteRecords(store));
      final values = repository.medications(pid);
      expect(values, hasLength(25));
      expect(
        values.singleWhere((m) => m.id == meds.first.id).product!.code,
        '123456789',
      );
      expect(counted.reads, lessThanOrEqualTo(3));
      counted.reads = 0;
      expect(
        repository.medicationIntakes(pid, meds.first.id, DateTime(2026, 9, 23)),
        hasLength(25),
      );
      expect(counted.reads, lessThanOrEqualTo(4));
      counted.reads = 0;
      final sources = SqliteVisits(
        store,
        SqliteRecords(store),
      ).visitEntries(pid, visit.id);
      expect(sources, hasLength(25));
      expect(counted.reads, lessThanOrEqualTo(4));
    } finally {
      sql.close();
    }
    db.saveMedication(
      pid,
      id: meds.first.id,
      expectedVersion: 1,
      name: 'updated',
      instruction: '',
      times: [],
    );
    expect(
      db.medications(pid).singleWhere((m) => m.id == meds.first.id).product,
      isNull,
    );
  });
}
