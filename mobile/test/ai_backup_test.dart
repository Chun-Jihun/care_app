import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/ai.dart';
import 'package:care_notebook/domain/backup.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/domain/record_lookup.dart';
import 'package:care_notebook/infrastructure/crypto.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';

import 'support.dart';

void main() {
  late Directory root;
  late CareController c;
  late String pid;
  const password = 'synthetic-ai-backup-password';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-ai-backup-');
    c = testController(VaultStore(root, MemorySecrets()), FakePlatform());
    await c.initialize();
    await c.setPin('123456');
    pid = c.selectedId!;
    await c.chat.setRetention(pid, ChatRetention.forever);
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });
  Future<CareEntry> source() => c.records.saveEntry(
    pid,
    kind: EntryKind.generalNote,
    occurredAt: DateTime(2020),
    fields: {},
    note: 'synthetic referenced record',
  );
  Future<void> reply(CareEntry entry) async {
    final message = await c.chat.append(pid, 'synthetic question');
    await c.chat.attachReply(
      pid,
      message.id,
      AiReply(
        AiReplyKind.records,
        sources: [AiReference(entry.id, entry.version)],
        lookup: RecordLookup(start: DateTime(2020), end: DateTime(2020, 1, 2)),
      ),
      c.chat.revision,
    );
  }

  test('backup remaps reply source IDs into the restored notebook', () async {
    final entry = await source();
    await reply(entry);
    final bytes = await testVault(c).backupSelection(
      password,
      BackupSelection(patientIds: {pid}, chats: true),
    );
    await c.importSelection(bytes, password);
    final restored = c.patients.singleWhere((p) => p.id != pid).id;
    final message = testRepository(c).chatMessages(restored).single;
    final record = testRepository(c).entries(restored).single;
    expect(message.reply!.sources.single.id, record.id);
    expect(record.id, isNot(entry.id));
    expect(message.reply!.sources.single.version, record.version);
    expect(message.reply!.lookup!.start, DateTime(2020));
  });
  test(
    'selective backup without source retains no dangling record answer',
    () async {
      await reply(await source());
      final bytes = await testVault(c).backupSelection(
        password,
        BackupSelection(patientIds: {pid}, chats: true, from: DateTime(2025)),
      );
      await c.importSelection(bytes, password);
      final restored = c.patients.singleWhere((p) => p.id != pid).id;
      expect(testRepository(c).entries(restored), isEmpty);
      final answer = testRepository(c).chatMessages(restored).single.reply!;
      expect(answer.kind, AiReplyKind.unavailable);
      expect(answer.sources, isEmpty);
      expect(answer.lookup, isNull);
    },
  );
  test('version 1 document without reply remains importable', () async {
    await c.chat.add(pid, 'historic question');
    final bytes = await testVault(c).backupSelection(
      password,
      BackupSelection(patientIds: {pid}, chats: true),
    );
    final data = jsonDecode(
      utf8.decode(await VaultCrypto.passwordOpen(bytes, password)),
    ) as Map;
    data['document_version'] = 1;
    final tables = data['rows'] as Map;
    for (final row in tables['chat_message'] as List) {
      (row as Map).remove('reply');
    }
    final legacy = await VaultCrypto.passwordSeal(
      Uint8List.fromList(utf8.encode(jsonEncode(data))),
      password,
    );
    await c.importSelection(legacy, password);
    final restored = c.patients.singleWhere((p) => p.id != pid).id;
    expect(testRepository(c).chatMessages(restored).single.reply, isNull);
  });
  test('version 3 period metadata remains importable', () async {
    await reply(await source());
    final bytes = await testVault(c).backupSelection(
      password,
      BackupSelection(patientIds: {pid}, chats: true),
    );
    final data = jsonDecode(
      utf8.decode(await VaultCrypto.passwordOpen(bytes, password)),
    ) as Map;
    data['document_version'] = 3;
    final old = await VaultCrypto.passwordSeal(
      Uint8List.fromList(utf8.encode(jsonEncode(data))),
      password,
    );
    await c.importSelection(old, password);
    final restored = c.patients.singleWhere((p) => p.id != pid).id;
    final lookup = testRepository(c)
        .chatMessages(restored)
        .single
        .reply!
        .lookup!;
    expect(lookup.start, DateTime(2020));
    expect(lookup.intakeStatus, isEmpty);
  });
  test(
    'version 4 exact intake status survives selective backup and restore',
    () async {
      final entry = await c.records.saveEntry(
        pid,
        kind: EntryKind.medicationIntake,
        occurredAt: DateTime(2020),
        fields: {'medicine': 'synthetic A', 'status': 'refused'},
      );
      final question = await c.chat.append(pid, 'synthetic status lookup');
      await c.chat.attachReply(
        pid,
        question.id,
        AiReply(
          AiReplyKind.records,
          sources: [AiReference(entry.id, entry.version)],
          lookup: RecordLookup(
            start: DateTime(2020),
            end: DateTime(2020, 1, 2),
            kind: EntryKind.medicationIntake,
            intakeStatus: 'refused',
          ),
        ),
        c.chat.revision,
      );
      final bytes = await testVault(c).backupSelection(
        password,
        BackupSelection(patientIds: {pid}, chats: true),
      );
      await c.importSelection(bytes, password);
      final restored = c.patients.singleWhere((p) => p.id != pid).id;
      final answer = testRepository(c).chatMessages(restored).single.reply!;
      expect(answer.lookup!.intakeStatus, 'refused');
      expect(
        answer.lookup!.matches(
          testRepository(c).entry(restored, answer.sources.single.id)!,
        ),
        isTrue,
      );
    },
  );
  test('version 2 reply without query metadata remains importable', () async {
    await reply(await source());
    final bytes = await testVault(c).backupSelection(
      password,
      BackupSelection(patientIds: {pid}, chats: true),
    );
    final data = jsonDecode(
      utf8.decode(await VaultCrypto.passwordOpen(bytes, password)),
    ) as Map;
    expect(data['document_version'], 4);
    data['document_version'] = 2;
    for (final row in (data['rows'] as Map)['chat_message'] as List) {
      final value = jsonDecode(row['reply'] as String) as Map;
      value.remove('lookup');
      value.remove('hasMore');
      row['reply'] = jsonEncode(value);
    }
    final old = await VaultCrypto.passwordSeal(
      Uint8List.fromList(utf8.encode(jsonEncode(data))),
      password,
    );
    await c.importSelection(old, password);
    final restored = c.patients.singleWhere((p) => p.id != pid).id;
    final answer = testRepository(c).chatMessages(restored).single.reply!;
    expect(answer.sources, hasLength(1));
    expect(answer.lookup, isNull);
  });
}
