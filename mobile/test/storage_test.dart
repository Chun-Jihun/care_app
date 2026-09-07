import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/care_database.dart';
import 'package:care_notebook/infrastructure/crypto.dart';

void main() {
  late Directory directory;
  late CareDatabase db;
  final key = Uint8List.fromList(List.generate(32, (i) => i + 1));
  final identityKey = Uint8List.fromList(List.generate(32, (i) => 99 - i));
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('care-test-');
    db = CareDatabase.open(directory.path, key: key, identityKey: identityKey);
  });
  tearDown(() async {
    db.close();
    await directory.delete(recursive: true);
  });

  test('LOCAL-01/02 actual SQLCipher persists encrypted records and rejects wrong key', () {
    final patient = db.createPatient(alias: '합성 환자');
    final entry = db.saveEntry(
      patient.id,
      kind: EntryKind.generalNote,
      note: 'SENSITIVE_SENTINEL_0917',
      occurredAt: DateTime(2026, 9, 7, 13),
    );
    db.close();
    final disk = File('${directory.path}/care.db').readAsBytesSync();
    expect(
      String.fromCharCodes(disk),
      isNot(contains('SENSITIVE_SENTINEL_0917')),
    );
    expect(
      String.fromCharCodes(disk.take(16)),
      isNot(startsWith('SQLite format')),
    );
    expect(
      () => CareDatabase.open(
        directory.path,
        key: Uint8List(32),
        identityKey: identityKey,
      ),
      throwsA(anything),
    );
    db = CareDatabase.open(directory.path, key: key, identityKey: identityKey);
    expect(db.entries(patient.id).single.id, entry.id);
    expect(db.entries(patient.id).single.note, 'SENSITIVE_SENTINEL_0917');
  });
  test(
    'LOCAL-03/04 patient boundaries and concurrent edits preserve revisions',
    () {
      final a = db.createPatient();
      final b = db.createPatient();
      final original = db.saveEntry(
        a.id,
        kind: EntryKind.meal,
        fields: {'food': '죽', 'water_ml': '150'},
        occurredAt: DateTime.now(),
      );
      expect(db.entries(b.id), isEmpty);
      expect(
        () => db.deleteEntry(b.id, original.id),
        throwsA(isA<CareError>()),
      );
      final updated = db.saveEntry(
        a.id,
        id: original.id,
        expectedVersion: 1,
        kind: EntryKind.meal,
        fields: {'food': '밥'},
        note: '수정',
        occurredAt: original.occurredAt,
      );
      expect(updated.version, 2);
      expect(db.revisions(a.id, original.id).single['note'], '');
      expect(
        () => db.saveEntry(
          a.id,
          id: original.id,
          expectedVersion: 1,
          kind: EntryKind.meal,
          occurredAt: original.occurredAt,
        ),
        throwsA(isA<CareError>()),
      );
      expect(db.entries(a.id).single.note, '수정');
    },
  );
  test(
    'LOCAL-05/06 medication plans are versioned, intake and tasks are separate',
    () {
      final p = db.createPatient();
      final med = db.saveMedication(
        p.id,
        name: '평가약',
        instruction: '사용자가 옮긴 지시',
        times: ['08:00'],
      );
      db.recordIntake(p.id, med.id, 'refused', DateTime.now(), reason: '거부');
      db.saveMedication(
        p.id,
        id: med.id,
        name: med.name,
        instruction: '새로 옮긴 지시',
        times: ['09:00'],
      );
      final intake = db.entries(p.id).single;
      expect(intake.fields['status'], 'refused');
      expect(intake.fields['instruction'], '사용자가 옮긴 지시');
      expect(db.medicationPlans(p.id, med.id), hasLength(2));
      final task = db.saveTask(p.id, title: '복약 확인', dueAt: DateTime.now());
      db.completeTask(p.id, task.id, true);
      expect(db.entries(p.id), hasLength(1));
    },
  );
  test('LOCAL-07 deletion clears revisions and marks source-linked visit for review', () {
    final p = db.createPatient();
    var e = db.saveEntry(
      p.id,
      kind: EntryKind.generalNote,
      note: '원문',
      occurredAt: DateTime.now(),
    );
    final visit = db.saveVisit(
      p.id,
      title: '진료 준비',
      questions: '질문',
      entryIds: [e.id],
    );
    e = db.saveEntry(
      p.id,
      id: e.id,
      expectedVersion: e.version,
      kind: e.kind,
      note: '수정 원문',
      occurredAt: e.occurredAt,
    );
    expect(db.visits(p.id).single.stale, isTrue);
    db.deleteEntry(p.id, e.id);
    expect(db.revisions(p.id, e.id), isEmpty);
    expect(db.visitEntries(p.id, visit.id), isEmpty);
    db.deletePatient(p.id);
    expect(db.patients(), isEmpty);
  });
  test('LOCAL-12 malformed numeric fields and missing measurement units are rejected', () {
    final p = db.createPatient();
    expect(
      () => db.saveEntry(
        p.id,
        kind: EntryKind.meal,
        fields: {'water_ml': '-1'},
        occurredAt: DateTime.now(),
      ),
      throwsA(isA<CareError>()),
    );
    expect(
      () => db.saveEntry(
        p.id,
        kind: EntryKind.measurement,
        fields: {'value': '36.5'},
        occurredAt: DateTime.now(),
      ),
      throwsA(isA<CareError>()),
    );
  });
  test(
    'LOCAL-08 authenticated encryption rejects tampering and wrong passwords',
    () async {
      final encrypted = await VaultCrypto.passwordSeal(
        Uint8List.fromList([1, 2, 3]),
        'correct-horse-battery',
      );
      expect(
        await VaultCrypto.passwordOpen(encrypted, 'correct-horse-battery'),
        [1, 2, 3],
      );
      expect(
        () => VaultCrypto.passwordOpen(encrypted, 'wrong-password'),
        throwsA(anything),
      );
      encrypted[encrypted.length - 1] ^= 1;
      expect(
        () => VaultCrypto.passwordOpen(encrypted, 'correct-horse-battery'),
        throwsA(anything),
      );
    },
  );
}
