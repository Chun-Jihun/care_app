import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
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
    c = CareController(VaultStore(root, secrets), FakePlatform());
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
      final pid = c.selectedId!, other = c.db.createPatient().id;
      await expectLater(c.addChatMessage(pid, '질문'), throwsA(isA<CareError>()));
      await c.setChatRetention(pid, ChatRetention.session);
      await c.addChatMessage(pid, 'SESSION_SENTINEL');
      expect(c.chatMessages(pid).single.text, 'SESSION_SENTINEL');
      expect(c.chatMessages(other), isEmpty);
      expect(c.db.chatMessages(pid), isEmpty);
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
      c = CareController(VaultStore(root, secrets), FakePlatform());
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
      c.db.setChatRetention(pid, ChatRetention.week, now: now);
      c.db.addChatMessage(
        pid,
        '만료 질문',
        now: now.subtract(const Duration(days: 8)),
      );
      c.db.addChatMessage(pid, '남는 질문', now: now);
      expect(c.db.chatMessages(pid, now: now).single.text, '남는 질문');
      expect(
        c.db.chatMessages(pid, now: now.add(const Duration(days: 7))),
        isEmpty,
      );
      // Reads filter expired messages without mutating the DB during build.
      c.db.pruneChats(now: now.add(const Duration(days: 7)));
      await c.setChatRetention(pid, ChatRetention.forever);
      await c.addChatMessage(pid, '복원 질문');
      final backup = await c.vault.backup('chat-backup-password');
      await c.clearChatMessages(pid);
      await c.restoreBackup(backup, 'chat-backup-password');
      expect(c.chatMessages(pid).single.text, '복원 질문');
      c.db.deletePatient(pid);
      expect(() => c.db.chatMessages(pid), throwsA(isA<CareError>()));
      c.db.verifyIntegrity();
    },
  );
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
      'DROP TABLE chat_message; DROP TABLE chat_policy; DROP TABLE record_draft; DROP TABLE imported_backup; PRAGMA user_version=1;',
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
