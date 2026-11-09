import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:care_notebook/domain/backup.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/care_database.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/application/care_controller.dart';

import 'support.dart';

void main() {
  late Directory root;
  late CareController c;
  late MemorySecrets secrets;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-chat-');
    secrets = MemorySecrets();
    c = testController(VaultStore(root, secrets), FakePlatform());
    await c.initialize();
    await c.setPin('123456');
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });
  test(
    'CHAT-01/02/03 consent, patient scope and session data never persist',
    () async {
      final pid = c.selectedId!, other = testRepository(c).createPatient().id;
      await expectLater(c.addChatMessage(pid, '질문'), throwsA(isA<CareError>()));
      await c.setChatRetention(pid, ChatRetention.session);
      await c.addChatMessage(pid, 'SESSION_SENTINEL');
      expect(c.chatMessages(pid).single.text, 'SESSION_SENTINEL');
      expect(() => c.chatMessages(other), throwsA(isA<CareError>()));
      expect(testRepository(c).chatMessages(pid), isEmpty);
      await expectLater(
        c.deleteChatMessage(other, c.chatMessages(pid).single.id),
        throwsA(isA<CareError>()),
      );
      c.lock();
      await c.unlockPin('123456');
      expect(c.chatMessages(pid), isEmpty);
      await c.setChatRetention(pid, ChatRetention.week);
      await c.addChatMessage(pid, 'LOCAL_SENTINEL');
      final id = c.chatMessages(pid).single.id;
      c.dispose();
      c = testController(VaultStore(root, secrets), FakePlatform());
      await c.initialize();
      await c.unlockPin('123456');
      expect(c.chatMessages(pid).single.id, id);
      await c.setChatRetention(pid, ChatRetention.session);
      expect(c.chatMessages(pid), isEmpty);
    },
  );
  test(
    'CHAT-03/04 expiry, shortened policy, backup restore and deletion cascade',
    () async {
      final pid = c.selectedId!;
      final now = DateTime(2026, 9, 7, 12);
      testRepository(c).setChatRetention(pid, ChatRetention.week, now: now);
      testRepository(c).addChatMessage(
        pid,
        '만료 질문',
        now: now.subtract(const Duration(days: 8)),
      );
      testRepository(c).addChatMessage(pid, '남는 질문', now: now);
      expect(
        testRepository(c).chatMessages(pid, now: now).single.text,
        '남는 질문',
      );
      expect(
        testRepository(c)
            .chatMessages(pid, now: now.add(const Duration(days: 7))),
        isEmpty,
      );
      // Reads filter expired messages without mutating the DB during build.
      testRepository(c).pruneChats(now: now.add(const Duration(days: 7)));
      await c.setChatRetention(pid, ChatRetention.forever);
      await c.addChatMessage(pid, '복원 질문');
      const password = 'chat-backup-password';
      final backup = await testVault(c).backupSelection(
        password,
        BackupSelection(patientIds: {pid}, chats: true),
      );
      await c.clearChatMessages(pid);
      await c.importSelection(backup, password);
      final restored = c.patients.singleWhere((patient) => patient.id != pid);
      await c.selectPatient(restored.id);
      expect(c.chatMessages(restored.id).single.text, '복원 질문');
      testRepository(c).deletePatient(restored.id);
      expect(
        () => testRepository(c).chatMessages(restored.id),
        throwsA(isA<CareError>()),
      );
      testRepository(c).verifyIntegrity();
    },
  );
  test('bounded history filters expiry and scopes before limiting tied rows', () async {
    final repository = testRepository(c), pid = c.selectedId!;
    final other = repository.createPatient().id;
    final now = DateTime.now();
    repository.setChatRetention(pid, ChatRetention.week, now: now);
    repository.setChatRetention(other, ChatRetention.forever, now: now);
    for (var i = 0; i < 8; i++) {
      repository.addChatMessage(pid, 'tied $i', now: now);
    }
    repository.addChatMessage(
      pid,
      'expired',
      now: now.subtract(const Duration(days: 8)),
    );
    repository.addChatMessage(
      other,
      'another notebook',
      now: now.add(const Duration(days: 1)),
    );
    final all = repository.chatMessages(pid, now: now);
    expect(all, hasLength(8));
    final latest = repository.chatMessages(pid, now: now, limit: 3);
    expect(latest.map((e) => e.id), all.skip(5).map((e) => e.id));
    expect(repository.chatMessages(pid, limit: 0), isEmpty);
    expect(() => c.chat.messages(other, limit: 0), throwsA(isA<CareError>()));
    repository.deletePatient(other);
    expect(
      () => repository.chatMessages(other, limit: 0),
      throwsA(isA<CareError>()),
    );
    // The bound also applies to in-memory questions without changing retention.
    await c.chat.setRetention(pid, ChatRetention.session);
    for (var i = 0; i < 55; i++) {
      await c.chat.add(pid, 'session $i');
    }
    expect(c.chat.messages(pid).first.text, 'session 5');
    expect(c.chat.messages(pid, limit: 100), hasLength(55));
    expect(repository.chatMessages(pid), isEmpty);
  });
  test('CHAT-04 v1 migration preserves original records and removes encrypted migration copies', () async {
    final path = '${root.path}/legacy';
    final key = Uint8List(32)..fillRange(0, 32, 15),
        identity = Uint8List(32)..fillRange(0, 32, 71);
    var db = CareDatabase.open(path, key: key, identityKey: identity);
    final pid = db.createPatient(alias: '기존 수첩').id;
    db.saveEntry(
      pid,
      kind: EntryKind.generalNote,
      note: '업데이트 전 기록',
      occurredAt: DateTime.now(),
    );
    db.close();
    String hex(List<int> k) =>
        k.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final old = sqlite3.open('$path/care.db');
    old.execute('PRAGMA key="x\'${hex(key)}\'"');
    old.execute(
      'DROP TRIGGER invalidate_medication_product; DROP TABLE medication_product; DROP TABLE chat_message; DROP TABLE chat_policy; DROP TABLE record_draft; DROP TABLE imported_backup; PRAGMA user_version=1;',
    );
    old.close();
    final oldId = sqlite3.open('$path/identity.db');
    oldId.execute('PRAGMA key="x\'${hex(identity)}\'"');
    oldId.execute('PRAGMA user_version=1');
    oldId.close();
    db = CareDatabase.open(path, key: key, identityKey: identity);
    expect(db.entries(pid).single.note, '업데이트 전 기록');
    expect(db.patients().single.alias, '기존 수첩');
    expect(db.chatRetention(pid), isNull);
    db.close();
    expect(
      await Directory(path).list().any((f) => f.path.endsWith('.bak')),
      false,
    );
  });
}
