import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/ai.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/l10n/app_strings.dart';

import 'support.dart';

class FakeAi implements LocalAiRuntime {
  Completer<String>? pending;
  String? question;
  int calls = 0;
  @override
  Future<String> extractQuery(String value, String language) {
    calls++;
    question = value;
    return pending?.future ??
        Future.value(
          '{"kind":"lookup","day":"2026-09-11","time":"09:30","item":"혈압"}',
        );
  }

  @override
  Future<AiModelStatus> status() async => const AiModelStatus(installed: true);
  @override
  Future<String?> pickBundle() async => null;
  @override
  Future<void> removeModels() async {}
  @override
  Future<void> installBundle(
    String path,
    void Function(double) progress,
  ) async {}
  @override
  Future<OcrDraft> recognize(Uint8List image, String language) async =>
      OcrDraft([
        const OcrLine('possibly wrong 15 mg', .5, [0, 0, 1, 1]),
      ]);
  @override
  Future<String> transcribe(Float32List samples, String language) async =>
      'possibly wrong 15 mg';
  @override
  void cancel() {}
  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory root;
  late CareController c;
  late FakeAi ai;
  late String pid;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-ai-');
    ai = FakeAi();
    c = CareController(
      VaultStore(root, MemorySecrets()),
      FakePlatform(),
      aiRuntime: ai,
    );
    await c.initialize();
    await c.setPin('123456');
    pid = c.selectedId!;
    await c.chat.setRetention(pid, ChatRetention.forever);
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });
  test('follow-up filters expire after deletion, background, patient changes or a non-lookup turn', () async {
    Future<void> ask(String text) =>
        c.ai.ask(c.selectedId!, text, AppLanguage.korean);
    await ask('오늘 복용 거부 기록');
    await ask('그럼 어제는?');
    expect(c.chat.messages(pid).last.reply!.lookup!.intakeStatus, 'refused');
    await ask('그럼 수분은?');
    expect(c.chat.messages(pid).last.reply!.lookup!.requiredField, 'water_ml');
    expect(c.chat.messages(pid).last.reply!.lookup!.intakeStatus, isEmpty);
    await c.chat.add(pid, 'a manual question starts a different context');
    await ask('그럼 어제는?');
    expect(c.chat.messages(pid).last.reply!.kind, AiReplyKind.clarify);
    await ask('오늘 복약 기록');
    await c.chat.delete(pid, c.chat.messages(pid).last.id);
    await ask('그럼 어제는?');
    expect(c.chat.messages(pid).last.reply!.kind, AiReplyKind.clarify);
    await ask('오늘 복약 기록');
    final other = await c.profiles.createPatient();
    await c.selectPatient(other.id);
    await c.chat.setRetention(other.id, ChatRetention.forever);
    await ask('그럼 어제는?');
    expect(c.chat.messages(other.id).last.reply!.kind, AiReplyKind.clarify);
    await c.selectPatient(pid);
    await ask('오늘 복약 기록');
    await ask('약 추천해줘');
    expect(c.chat.messages(pid).last.reply!.kind, AiReplyKind.medicalHold);
    await ask('그럼 어제는?');
    expect(c.chat.messages(pid).last.reply!.kind, AiReplyKind.clarify);
    await c.disableAppLock('123456');
    await ask('오늘 복약 기록');
    c.handleBackground();
    await ask('그럼 어제는?');
    expect(c.chat.messages(pid).last.reply!.kind, AiReplyKind.clarify);
    expect(ai.calls, 0);
  });
  test('only selected records are returned; identifiers masked; reply retention follows question', () async {
    await c.profiles.updatePatient(
      pid,
      alias: 'PRIVATE_ALIAS',
      role: 'family',
      context: '',
      contact: 'PRIVATE_CONTACT',
    );
    final entry = await c.records.saveEntry(
      pid,
      kind: EntryKind.measurement,
      occurredAt: DateTime(2026, 9, 11, 9, 30),
      fields: {'measurement': '혈압', 'value': '120/80', 'unit': 'mmHg'},
    );
    await c.ai.ask(
      pid,
      'PRIVATE_ALIAS 2026-09-11 09:30 혈압',
      AppLanguage.korean,
    );
    expect(ai.question, isNot(contains('PRIVATE_ALIAS')));
    expect(ai.question, isNot(contains('120/80')));
    expect(c.chat.messages(pid).single.reply!.sources.single.id, entry.id);
    c.lock();
    await c.unlockPin('123456');
    expect(c.chat.messages(pid).single.reply!.sources.single.id, entry.id);
    await c.chat.setRetention(pid, ChatRetention.session);
    await c.ai.ask(pid, '2026-09-11 09:30에 측정한 혈압을 찾아줘', AppLanguage.korean);
    c.lock();
    await c.unlockPin('123456');
    expect(c.chat.messages(pid), isEmpty);
  });
  test(
    'medical and urgent requests bypass model; OCR and speech never auto-save',
    () async {
      await c.ai.ask(pid, '약을 같이 먹어도 안전해?', AppLanguage.korean);
      expect(c.chat.messages(pid).last.reply!.kind, AiReplyKind.medicalHold);
      await c.ai.ask(pid, '응급 상황이에요', AppLanguage.korean);
      expect(c.chat.messages(pid).last.reply!.kind, AiReplyKind.urgent);
      expect(ai.calls, 0);
      await c.ai.recognize(pid, Uint8List(1), AppLanguage.korean);
      await c.ai.transcribe(pid, Float32List(10), AppLanguage.korean);
      expect(c.entries, isEmpty);
      expect(c.drafts.list(pid), isEmpty);
      await c.ai.ask(pid, '오늘 2026-09-11 09:30 혈압', AppLanguage.korean);
      expect(c.chat.messages(pid).last.reply!.kind, AiReplyKind.clarify);
      expect(ai.calls, 0);
    },
  );
  test(
    'period lookup preserves refusal, caps sources and never loads model',
    () async {
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day - 1);
      for (var i = 0; i < 10; i++) {
        await c.records.saveEntry(
          pid,
          kind: EntryKind.medicationIntake,
          occurredAt: day.add(Duration(hours: i)),
          fields: {'medicine': '약 A', 'status': 'refused', 'reason': '기록 그대로'},
        );
      }
      await c.ai.ask(pid, '어제 복약 기록 보여줘', AppLanguage.korean);
      final answer = c.chat.messages(pid).last.reply!;
      expect(answer.kind, AiReplyKind.records);
      expect(answer.sources, hasLength(8));
      expect(answer.hasMore, true);
      expect(answer.lookup!.start, day);
      expect(
        c.records.entry(pid, answer.sources.first.id)!.fields['status'],
        'refused',
      );
      expect(ai.calls, 0);
      c.lock();
      await c.unlockPin('123456');
      expect(c.chat.messages(pid).last.reply!.lookup!.start, day);
      expect(c.chat.messages(pid).last.reply!.hasMore, true);
      await c.ai.ask(pid, '어제 식사 기록', AppLanguage.korean);
      expect(c.chat.messages(pid).last.reply!.kind, AiReplyKind.noRecords);
      await c.ai.ask(pid, '어제 다른 환자 복약 기록', AppLanguage.korean);
      expect(c.chat.messages(pid).last.reply!.kind, AiReplyKind.notebookScope);
      await c.ai.ask(pid, '어제 복약 기록 보고 약 추천해줘', AppLanguage.korean);
      expect(c.chat.messages(pid).last.reply!.kind, AiReplyKind.medicalHold);
      expect(ai.calls, 0);
    },
  );

  test(
    'period lookup is scoped and filters water before limiting results',
    () async {
      final at = DateTime.now();
      final wanted = await c.records.saveEntry(
        pid,
        kind: EntryKind.meal,
        occurredAt: at,
        fields: {'water_ml': '0'},
      );
      for (var i = 0; i < 10; i++) {
        await c.records.saveEntry(
          pid,
          kind: EntryKind.meal,
          occurredAt: at.add(Duration(milliseconds: i + 1)),
          fields: {'food': '죽'},
        );
      }
      final other = await c.profiles.createPatient();
      await c.selectPatient(other.id);
      await c.records.saveEntry(
        other.id,
        kind: EntryKind.meal,
        occurredAt: at,
        fields: {'water_ml': '999'},
      );
      await c.selectPatient(pid);
      await c.ai.ask(pid, '오늘 수분 기록', AppLanguage.korean);
      expect(c.chat.messages(pid).last.reply!.sources.single.id, wanted.id);
      expect(c.chat.messages(pid).last.reply!.hasMore, false);
      expect(ai.calls, 0);
    },
  );
  test(
    'background without app lock cancels both queued and running AI replies',
    () async {
      await c.disableAppLock('123456');
      final queued = c.ai.ask(
        pid,
        '2026-09-11 09:30에 측정한 혈압을 찾아줘',
        AppLanguage.korean,
      );
      c.handleBackground();
      await queued;
      expect(c.unlocked, isTrue);
      expect(ai.calls, 0);
      expect(c.chat.messages(pid).single.reply, isNull);

      ai.pending = Completer<String>();
      final running = c.ai.ask(
        pid,
        '2026-09-11 09:30에 측정한 혈압을 찾아줘',
        AppLanguage.korean,
      );
      final assertion = expectLater(running, throwsA(isA<CareError>()));
      while (ai.calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      c.handleBackground();
      await assertion;
      ai.pending!.complete(
        '{"kind":"lookup","day":"2026-09-11","time":"09:30","item":"혈압"}',
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.unlocked, isTrue);
      expect(c.chat.messages(pid).every((m) => m.reply == null), isTrue);
    },
  );

  test('late reply is discarded when locked or question is deleted', () async {
    ai.pending = Completer<String>();
    final operation = c.ai.ask(
      pid,
      '2026-09-11 09:30에 측정한 혈압을 찾아줘',
      AppLanguage.korean,
    );
    final assertion = expectLater(operation, throwsA(isA<CareError>()));
    while (ai.calls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    c.lock();
    await assertion;
    ai.pending!.complete(
      '{"kind":"lookup","day":"2026-09-11","time":"09:30","item":"혈압"}',
    );
    await Future<void>.delayed(Duration.zero);
    await c.unlockPin('123456');
    expect(c.chat.messages(pid).single.reply, isNull);
    ai.pending = Completer<String>();
    final second = c.ai.ask(
      pid,
      '2026-09-11 09:30에 측정한 혈압을 찾아줘',
      AppLanguage.korean,
    );
    while (ai.calls < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    await c.chat.clear(pid);
    ai.pending!.complete(
      '{"kind":"lookup","day":"2026-09-11","time":"09:30","item":"혈압"}',
    );
    await second;
    expect(c.chat.messages(pid), isEmpty);
  });
}
