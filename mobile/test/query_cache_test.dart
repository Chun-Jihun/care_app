import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';

import 'support.dart';

// Cached results must change with a confirmed edit/delete, date or patient;
// no data may remain readable through a cache after locking.
void main() {
  test(
    'intake cache reuses reads and invalidates every affected view',
    () async {
      final root = await Directory.systemTemp.createTemp('care-query-cache-');
      final c = testController(
        VaultStore(root, MemorySecrets()),
        FakePlatform(),
      );
      addTearDown(() async {
        c.dispose();
        await root.delete(recursive: true);
      });
      await c.initialize();
      await c.startWithoutLock();
      final pid = c.selectedId!, day = DateTime(2026, 9, 23);
      final med = await c.medicationBook.saveMedication(
        pid,
        name: 'medicine',
        instruction: '',
        times: [],
      );
      final empty = c.medicationBook.intakes(pid, med.id, day);
      expect(
        identical(empty, c.medicationBook.intakes(pid, med.id, day)),
        true,
      );
      final entry = await c.medicationBook.recordIntake(
        pid,
        med.id,
        'taken',
        day,
      );
      final taken = c.medicationBook.intakes(pid, med.id, day);
      expect(taken.single.fields['status'], 'taken');
      expect(
        identical(taken, c.medicationBook.intakes(pid, med.id, day)),
        true,
      );
      await c.records.saveEntry(
        pid,
        id: entry.id,
        expectedVersion: entry.version,
        kind: entry.kind,
        occurredAt: day,
        fields: {...entry.fields, 'status': 'refused'},
      );
      expect(
        c.medicationBook.intakes(pid, med.id, day).single.fields['status'],
        'refused',
      );
      expect(
        c.medicationBook.intakes(pid, med.id, DateTime(2026, 9, 24)),
        isEmpty,
      );
      expect(
        c.records.entries(pid, from: day, until: DateTime(2026, 9, 24)),
        hasLength(1),
      );
      expect(c.records.entries(pid, from: DateTime(2026, 9, 24)), isEmpty);
      await c.records.deleteEntry(pid, entry.id);
      expect(c.medicationBook.intakes(pid, med.id, day), isEmpty);
      expect(c.taskBook.count(pid, done: false), 0);
      final task = await c.taskBook.saveTask(pid, title: 'check', dueAt: day);
      expect(c.taskBook.count(pid, done: false), 1);
      expect(c.taskBook.tasks(pid, done: false, limit: 1).single.id, task.id);
      await c.taskBook.completeTask(pid, task.id, true);
      expect(c.taskBook.count(pid, done: false), 0);
      expect(c.taskBook.tasks(pid, done: false, limit: 1), isEmpty);
      expect(c.taskBook.tasks(pid, done: true, limit: 1).single.id, task.id);
      expect(c.checkins.checkins(limit: 1), isEmpty);
      await c.checkins.addCheckin(fatigue: 'test', sleep: '', stress: '');
      final checkin = c.checkins.checkins(limit: 1).single;
      expect(c.checkins.checkins(limit: 0), isEmpty);
      await c.checkins.deleteCheckin(checkin.id);
      expect(c.checkins.checkins(limit: 1), isEmpty);
      final other = testRepository(c).createPatient().id;
      await c.refresh();
      await c.selectPatient(other);
      expect(
        () => c.medicationBook.intakes(pid, med.id, day),
        throwsA(isA<CareError>()),
      );
      c.lock();
      expect(
        () => c.medicationBook.intakes(other, med.id, day),
        throwsA(isA<CareError>()),
      );
    },
  );
}
