import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqlite3/sqlite3.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/application/draft_session.dart';
import 'package:care_notebook/domain/backup.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/domain/drafts.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/care_database.dart';
import 'package:care_notebook/infrastructure/crypto.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';

import 'support.dart';

void main() {
  late Directory root;
  late CareController c;
  late MemorySecrets secrets;
  const password = 'selective-backup-test-password';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-drafts-backup-');
    secrets = MemorySecrets();
    c = CareController(VaultStore(root, secrets), FakePlatform());
    await c.initialize();
    await c.setPin('123456');
    c.db.setDraftRetention(DraftRetention.month);
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });
  Future<Map<String, dynamic>> decode(Uint8List bytes) async =>
      Map<String, dynamic>.from(
        jsonDecode(utf8.decode(await VaultCrypto.passwordOpen(bytes, password)))
            as Map,
      );
  Future<Uint8List> encode(Map<String, dynamic> data) =>
      VaultCrypto.passwordSeal(
        Uint8List.fromList(utf8.encode(jsonEncode(data))),
        password,
      );

  test(
    'DRAFT-01/02 lock flush survives reopen without confirming any record',
    () async {
      final pid = c.selectedId!;
      var text = '';
      final draft = DraftSession(
        c,
        patientId: pid,
        type: DraftType.entry,
        snapshot: () => {'kind': 'generalNote', 'note': text, 'at': 12345},
      );
      text = 'ENCRYPTED_DRAFT_SENTINEL';
      draft.changed();
      c.lock(); // Before the 400ms timer fires.
      draft.dispose();
      c.dispose();
      c = CareController(VaultStore(root, secrets), FakePlatform());
      await c.initialize();
      await c.unlockPin('123456');
      expect(c.db.drafts(pid).single.values['note'], text);
      expect(c.db.entries(pid), isEmpty);
      expect(c.db.tasks(pid), isEmpty);
      for (final file
          in await root
              .list(recursive: true)
              .where((e) => e is File)
              .cast<File>()
              .toList()) {
        expect(latin1.decode(await file.readAsBytes()), isNot(contains(text)));
      }
    },
  );

  test('DRAFT-02 save and draft deletion roll back together, then commit exactly once', () async {
    final pid = c.selectedId!;
    final draft = DraftSession(
      c,
      patientId: pid,
      type: DraftType.entry,
      snapshot: () => {'kind': 'generalNote', 'note': '확인할 내용'},
    );
    addTearDown(draft.dispose);
    await expectLater(
      draft.complete(() {
        c.db.saveEntry(
          pid,
          kind: EntryKind.generalNote,
          note: '실패한 저장',
          occurredAt: DateTime.now(),
        );
        throw const CareError('주입한 저장 실패');
      }),
      throwsA(isA<CareError>()),
    );
    expect(c.entries, isEmpty);
    expect(c.db.drafts(pid), hasLength(1));
    await draft.complete(
      () => c.db.saveEntry(
        pid,
        kind: EntryKind.generalNote,
        note: '확인할 내용',
        occurredAt: DateTime.now(),
      ),
    );
    expect(c.db.drafts(pid), isEmpty);
    expect(c.entries.single.note, '확인할 내용');
    c.lock();
    await c.unlockPin('123456');
    expect(c.entries, hasLength(1));
    expect(c.db.drafts(pid), isEmpty);
  });

  test(
    'DRAFT-02 every valid Korean symptom field also fits in an encrypted draft',
    () async {
      final pid = c.selectedId!;
      final fields = {
        for (final field in EntryKind.symptom.fields) field.key: '가' * 4000,
      };
      final note = '나' * 20000;
      final values = <String, dynamic>{
        'kind': 'symptom',
        'fields': fields,
        'note': note,
      };
      expect(utf8.encode(jsonEncode(values)).length, greaterThan(128 * 1024));
      final draft = DraftSession(
        c,
        patientId: pid,
        type: DraftType.entry,
        snapshot: () => values,
      );
      addTearDown(draft.dispose);
      await draft.complete(
        () => c.db.saveEntry(
          pid,
          kind: EntryKind.symptom,
          fields: fields,
          note: note,
          occurredAt: DateTime.now(),
        ),
      );
      expect(c.entries.single.note, note);
      expect(c.db.drafts(pid), isEmpty);
    },
  );

  test('DRAFT-03 cross-patient access and changed prescriptions cannot be confirmed', () async {
    final pid = c.selectedId!, other = c.db.createPatient().id;
    final med = c.db.saveMedication(
      pid,
      name: '처방 이름',
      instruction: '원래 지시',
      times: [],
    );
    final draft = DraftSession(
      c,
      patientId: pid,
      type: DraftType.intake,
      targetId: med.id,
      snapshot: () => {'status': 'taken'},
    );
    addTearDown(draft.dispose);
    draft.flush(force: true);
    expect(c.db.drafts(other), isEmpty);
    expect(() => c.db.deleteDraft(other, draft.id), throwsA(isA<CareError>()));
    c.db.saveMedication(
      pid,
      id: med.id,
      expectedVersion: med.version,
      name: med.name,
      instruction: '새 지시',
      times: [],
    );
    await expectLater(
      draft.complete(
        () => c.db.recordIntake(pid, med.id, 'taken', DateTime.now()),
      ),
      throwsA(isA<CareError>()),
    );
    expect(c.entries, isEmpty);
    expect(c.db.drafts(pid), hasLength(1));
  });

  test('DRAFT-04 shortened retention, deletion and old sessions cannot resurrect drafts', () async {
    final pid = c.selectedId!, id = CareDatabase.newId(), now = DateTime.now();
    c.db.saveDraft(
      id: id,
      patientId: pid,
      type: DraftType.entry,
      values: {'note': '지난 초안'},
      now: now.subtract(const Duration(days: 8)),
    );
    expect(c.db.drafts(pid), hasLength(1));
    c.db.setDraftRetention(DraftRetention.week);
    expect(c.db.drafts(pid), isEmpty);
    expect(
      () => c.db.saveDraft(
        id: id,
        patientId: pid,
        type: DraftType.entry,
        values: {},
        create: false,
      ),
      throwsA(isA<CareError>()),
    );
    final draft = DraftSession(
      c,
      patientId: pid,
      type: DraftType.entry,
      snapshot: () => {'note': '삭제할 초안'},
    );
    addTearDown(draft.dispose);
    draft.flush(force: true);
    c.db.deleteDraft(pid, draft.id);
    expect(() => draft.flush(force: true), throwsA(isA<CareError>()));
    c.lock();
    await c.unlockPin('123456');
    expect(() => draft.flush(force: true), throwsA(isA<CareError>()));
    c.db.saveDraft(
      id: CareDatabase.newId(),
      patientId: pid,
      type: DraftType.entry,
      values: {'note': '연쇄 삭제'},
    );
    c.db.deletePatient(pid);
    c.db.verifyIntegrity();
    expect(c.db.drafts(null), isEmpty);
  });

  test('BACKUP-01/02 selected rows exclude other patients, dates, drafts, identifiers and optional data', () async {
    final pid = c.selectedId!,
        other = c.db.createPatient(alias: 'OTHER_ALIAS').id;
    c.db.updatePatient(
      pid,
      alias: 'PRIVATE_ALIAS',
      role: 'family',
      context: '필요한 돌봄 배경',
      contact: 'PRIVATE_CONTACT',
    );
    final start = DateTime(2026, 1, 2), end = DateTime(2026, 1, 3);
    final before = c.db.saveEntry(
      pid,
      kind: EntryKind.generalNote,
      note: 'BEFORE_RANGE',
      occurredAt: start.subtract(const Duration(milliseconds: 1)),
    );
    c.db.saveEntry(
      pid,
      kind: EntryKind.generalNote,
      note: 'AFTER_RANGE',
      occurredAt: end,
    );
    c.db.saveEntry(
      other,
      kind: EntryKind.generalNote,
      note: 'OTHER_PATIENT',
      occurredAt: start,
    );
    final med = c.db.saveMedication(
      pid,
      name: '백업 약',
      instruction: '당시 처방',
      times: ['08:00'],
    );
    final intake = c.db.recordIntake(pid, med.id, 'taken', start);
    c.db.saveMedication(
      pid,
      id: med.id,
      expectedVersion: med.version,
      name: med.name,
      instruction: '현재 처방',
      times: ['09:00'],
    );
    c.db.setChatRetention(pid, ChatRetention.forever);
    c.db.addChatMessage(pid, 'PRIVATE_CHAT');
    c.db.addCheckin(fatigue: 'PRIVATE_CHECKIN', sleep: '', stress: '');
    c.db.saveDraft(
      id: CareDatabase.newId(),
      patientId: pid,
      type: DraftType.entry,
      values: {'note': 'PRIVATE_DRAFT'},
    );
    await c.vault.addPhoto(
      pid,
      intake.id,
      Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2))),
    );
    final bytes = await c.vault.backupSelection(
      password,
      BackupSelection(
        patientIds: {pid},
        from: start,
        until: end,
        photos: false,
      ),
    );
    final archive = await decode(bytes), text = jsonEncode(await decode(bytes));
    for (final excluded in [
      'BEFORE_RANGE',
      'AFTER_RANGE',
      'OTHER_PATIENT',
      'OTHER_ALIAS',
      'PRIVATE_ALIAS',
      'PRIVATE_CONTACT',
      'PRIVATE_CHAT',
      'PRIVATE_CHECKIN',
      'PRIVATE_DRAFT',
      'record_draft',
      'reminders_enabled',
    ]) {
      expect(text, isNot(contains(excluded)), reason: excluded);
    }
    expect(archive.containsKey('keys'), false);
    expect(archive['files'], isEmpty);
    final rows = archive['rows'] as Map;
    expect(rows['care_entry'], hasLength(1));
    expect(rows['medication_plan'], hasLength(2));
    expect((rows['medication_intake'] as List).single['plan_id'], med.planId);
    expect(c.db.entries(pid).any((e) => e.id == before.id), true);
    expect(c.db.attachments(pid, intake.id), hasLength(1));

    // A visit created now links to both a current and an out-of-range record.
    final today = DateTime.now(),
        from = DateTime(today.year, today.month, today.day);
    final recent = c.db.saveEntry(
      pid,
      kind: EntryKind.generalNote,
      note: '최근 기록',
      occurredAt: today,
    );
    c.db.saveVisit(
      pid,
      title: '진료 준비',
      questions: '질문',
      entryIds: [before.id, recent.id],
    );
    final selection = c.db.selectBackup(
      BackupSelection(
        patientIds: {pid},
        from: from,
        until: from.add(const Duration(days: 1)),
      ),
    );
    expect(selection['visit_source']!.single['entry_id'], recent.id);
    expect(selection['visit_preparation']!.single['stale'], 1);
  });

  test('BACKUP-03/05 additive restore remaps history/photos, preserves drafts and mutes only imported reminders', () async {
    final pid = c.selectedId!;
    final med = c.db.saveMedication(
      pid,
      name: '합성 약',
      instruction: '원 지시',
      times: ['08:00'],
    );
    final intake = c.db.recordIntake(pid, med.id, 'unknown', DateTime.now());
    final current = c.db.entry(pid, intake.id)!;
    c.db.saveEntry(
      pid,
      id: current.id,
      expectedVersion: current.version,
      kind: current.kind,
      occurredAt: current.occurredAt,
      note: '수정한 관찰',
      fields: {...current.fields, 'status': 'taken'},
    );
    c.db.saveVisit(
      pid,
      title: '원본 연결',
      questions: '합성 질문',
      entryIds: [intake.id],
    );
    c.db.setChatRetention(pid, ChatRetention.month);
    c.db.addChatMessage(pid, '보관한 질문');
    c.db.addCheckin(fatigue: '내 피로', sleep: '내 수면', stress: '내 상태');
    await c.vault.addPhoto(
      pid,
      intake.id,
      Uint8List.fromList(img.encodePng(img.Image(width: 3, height: 3))),
    );
    final originalPhoto = c.db.attachments(pid, intake.id).single;
    final pixels = await c.vault.photo(pid, intake.id, originalPhoto.id);
    final bytes = await c.vault.backupSelection(
      password,
      BackupSelection(
        patientIds: {pid},
        chats: true,
        checkins: true,
        identities: true,
      ),
    );
    c.db.saveDraft(
      id: CareDatabase.newId(),
      patientId: pid,
      type: DraftType.entry,
      values: {'note': '복원 중에도 보존'},
    );
    await c.enableNotifications(true);
    final originalReminders = (c.platform as FakePlatform).reminders
        .map((r) => r.id)
        .toList();
    await c.importSelection(bytes, password);
    expect(c.selectedId, pid);
    expect(c.db.drafts(pid).single.values['note'], '복원 중에도 보존');
    expect(c.db.entries(pid), hasLength(1));
    final restored = c.patients.singleWhere((p) => p.id != pid);
    expect(restored.label, contains('(복원)'));
    final entry = c.db.entries(restored.id).single;
    expect(entry.id, isNot(intake.id));
    final restoredMed = c.db.medications(restored.id).single;
    expect(entry.fields['medication_id'], restoredMed.id);
    expect(entry.fields['plan_id'], restoredMed.planId);
    expect(c.db.revisions(restored.id, entry.id).single['id'], entry.id);
    expect(
      (c.db.revisions(restored.id, entry.id).single['fields']
          as Map)['medication_id'],
      restoredMed.id,
    );
    expect(
      c.db
          .visitEntries(restored.id, c.db.visits(restored.id).single.id)
          .single
          .id,
      entry.id,
    );
    expect(c.db.chatMessages(restored.id).single.text, '보관한 질문');
    expect(c.db.checkins(), hasLength(2));
    expect(
      (c.platform as FakePlatform).reminders.map((r) => r.id),
      originalReminders,
    );
    expect(c.db.setting('imported_muted:${restored.id}'), 'true');
    final photo = c.db.attachments(restored.id, entry.id).single;
    expect(photo.id, isNot(originalPhoto.id));
    expect(await c.vault.photo(restored.id, entry.id, photo.id), pixels);
    c.lock();
    await c.unlockPin('123456');
    expect(await c.vault.photo(restored.id, entry.id, photo.id), pixels);
    await expectLater(
      c.importSelection(bytes, password),
      throwsA(isA<CareError>()),
    );
    expect(c.patients, hasLength(2));
    expect(c.db.checkins(), hasLength(2));
    // A backup may be used again after every copy it added was deleted.
    c.db.deletePatient(restored.id);
    for (final row in c.db.checkins()) {
      c.db.deleteCheckin(row['id'] as String);
    }
    await c.importSelection(bytes, password);
    expect(c.patients, hasLength(2));
    expect(c.db.checkins(), hasLength(1));
  });

  test('BACKUP-04 password, tamper, bad links, missing photos and cancelled commit preserve current generation', () async {
    final pid = c.selectedId!;
    final entry = c.db.saveEntry(
      pid,
      kind: EntryKind.generalNote,
      note: '보존할 원본',
      occurredAt: DateTime.now(),
    );
    await c.vault.addPhoto(
      pid,
      entry.id,
      Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2))),
    );
    final bytes = await c.vault.backupSelection(
      password,
      BackupSelection(patientIds: {pid}),
    );
    final originalKeys = Map<String, String>.from(secrets.values);
    await expectLater(
      c.importSelection(bytes, 'incorrect-password'),
      throwsA(anything),
    );
    final corrupted = Uint8List.fromList(bytes)..[60] ^= 1;
    await expectLater(
      c.importSelection(corrupted, password),
      throwsA(anything),
    );
    final missing = await decode(bytes);
    missing['files'] = {};
    await expectLater(
      c.importSelection(await encode(missing), password),
      throwsA(isA<CareError>()),
    );
    final badLink = await decode(bytes);
    ((badLink['rows'] as Map)['general_note_entry'] as List)
            .single['patient_id'] =
        CareDatabase.newId();
    await expectLater(
      c.importSelection(await encode(badLink), password),
      throwsA(anything),
    );
    final forbidden = await decode(bytes);
    (forbidden['rows'] as Map)['record_draft'] = [];
    await expectLater(
      c.importSelection(await encode(forbidden), password),
      throwsA(isA<CareError>()),
    );
    final wrongType = await decode(bytes);
    ((wrongType['rows'] as Map)['care_entry'] as List).single['occurred_at'] =
        'invalid timestamp';
    await expectLater(
      c.importSelection(await encode(wrongType), password),
      throwsA(isA<CareError>()),
    );
    await expectLater(
      c.vault.importSelection(
        bytes,
        password,
        beforeCommit: () => throw const CareError('잠금 직전 중단'),
      ),
      throwsA(isA<CareError>()),
    );
    expect(c.patients, hasLength(1));
    expect(c.entries.single.note, '보존할 원본');
    expect(secrets.values, originalKeys);
    c.db.verifyIntegrity();
    expect(
      await root
          .list()
          .where((e) => e is Directory && !e.path.endsWith('commits'))
          .length,
      1,
    );
  });

  test(
    'COMPAT-01 encrypted v2 migration preserves records and chat policy',
    () async {
      final dir = '${root.path}/migration',
          key = Uint8List(32)..fillRange(0, 32, 17),
          identity = Uint8List(32)..fillRange(0, 32, 31);
      var db = CareDatabase.open(dir, key: key, identityKey: identity);
      final pid = db.createPatient(alias: '기존 수첩').id;
      db.saveEntry(
        pid,
        kind: EntryKind.generalNote,
        note: 'v2에서 작성',
        occurredAt: DateTime.now(),
      );
      db.setChatRetention(pid, ChatRetention.forever);
      db.addChatMessage(pid, '기존 대화');
      db.close();
      String hex(List<int> bytes) =>
          bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final raw = sqlite3.open('$dir/care.db');
      raw.execute('PRAGMA key="x\'${hex(key)}\'"');
      raw.execute(
        'DROP TABLE record_draft; DROP TABLE imported_backup; PRAGMA user_version=2;',
      );
      raw.close();
      final rawId = sqlite3.open('$dir/identity.db');
      rawId.execute('PRAGMA key="x\'${hex(identity)}\'"');
      rawId.execute('PRAGMA user_version=2');
      rawId.close();
      db = CareDatabase.open(dir, key: key, identityKey: identity);
      expect(db.entries(pid).single.note, 'v2에서 작성');
      expect(db.chatMessages(pid).single.text, '기존 대화');
      expect(db.drafts(pid), isEmpty);
      expect(db.draftRetention, isNull);
      db.verifyIntegrity();
      db.close();
      expect(
        await Directory(dir).list().any((e) => e.path.endsWith('.bak')),
        false,
      );
    },
  );
}
