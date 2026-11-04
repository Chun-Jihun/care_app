import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/ai.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/domain/record_lookup.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/domain/ui_preferences.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/l10n/app_strings.dart';
import 'package:care_notebook/presentation/app.dart';
import 'package:care_notebook/presentation/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'ai_service_test.dart' show FakeAi;
import 'support.dart';

class AuditAi extends FakeAi {
  final speech = Completer<String>();
  String item = '복약';
  @override
  Future<String> transcribe(Float32List samples, String language) =>
      speech.future;
  @override
  Future<String> extractQuery(String question, String language) async =>
      jsonEncode({
        'kind': 'lookup',
        'day': '2026-09-11',
        'time': '09:00',
        'item': item,
      });
}

// Failure contracts: a read-only tick must not cancel inference; both lookup
// paths expose all matches; history stays bounded without deleting data;
// hiding other home sections must not hide the empty medication setup action.
void main() {
  setUpAll(() => initializeDateFormatting('ko'));
  late Directory root;
  late CareController c;
  late AuditAi ai;
  late VaultStore vault;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-audit-fixes-');
    ai = AuditAi();
    vault = VaultStore(root, MemorySecrets());
    c = CareController(vault, FakePlatform(), aiRuntime: ai);
    await c.initialize();
    await c.startWithoutLock();
    await c.chat.setRetention(c.selectedId!, ChatRetention.forever);
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('chat expiry refresh preserves pending transcription', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBody(c: c, pid: c.selectedId!),
        ),
      ),
    );
    Object? error;
    String? value;
    final pending = c.ai
        .transcribe(
          c.selectedId!,
          Float32List.fromList([.1]),
          AppLanguage.korean,
        )
        .then<void>(
          (text) => value = text,
          onError: (Object e) {
            error = e;
          },
        );
    await tester.pump(const Duration(minutes: 1));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(error, isNull);
    ai.speech.complete('합성 인식 결과');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(value, '합성 인식 결과');
    await pending;
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'model lookup retains its filter and exposes the ninth matching intake',
    () async {
      final pid = c.selectedId!;
      await c.profiles.updatePatient(
        pid,
        alias: '엄마',
        role: 'family',
        context: '',
        contact: '',
      );
      for (var i = 0; i < 9; i++) {
        await c.records.saveEntry(
          pid,
          kind: EntryKind.medicationIntake,
          occurredAt: DateTime(2026, 9, 11, 9),
          fields: {'medicine': '합성 $i', 'status': 'taken'},
        );
      }
      await c.ai.ask(pid, '엄마의 2026-09-11 09:00 복약 기록 알려줘', AppLanguage.korean);
      final reply = c.chat.messages(pid).last.reply!;
      expect(reply.sources, hasLength(8));
      expect(reply.hasMore, isTrue);
      expect(reply.lookup, isNotNull);
      expect(c.records.lookup(pid, reply.lookup!), hasLength(9));
      final restored = AiReply.decode(reply.encode());
      expect(c.records.lookup(pid, restored.lookup!), hasLength(9));
    },
  );

  test(
    'model label matching preserves both categories and literal item names',
    () async {
      final pid = c.selectedId!;
      ai.item = '이후 상태';
      await c.records.saveEntry(
        pid,
        kind: EntryKind.dailyLiving,
        occurredAt: DateTime(2026, 9, 11, 9),
        fields: {'category': 'sleep'},
      );
      await c.records.saveEntry(
        pid,
        kind: EntryKind.incident,
        occurredAt: DateTime(2026, 9, 11, 9),
        fields: {'event': '합성 사건'},
      );
      await c.records.saveEntry(
        pid,
        kind: EntryKind.medicationIntake,
        occurredAt: DateTime(2026, 9, 11, 9),
        fields: {'medicine': '이후 상태', 'status': 'unknown'},
      );
      await c.ai.ask(pid, '2026-09-11 09:00 이후 상태 원문 부탁해', AppLanguage.korean);
      final reply = c.chat.messages(pid).last.reply!;
      expect(reply.sources, hasLength(3));
      expect(reply.lookup, isNotNull);
      final filter = RecordLookup.fromJson(reply.lookup!.toJson());
      expect(c.records.lookup(pid, filter), hasLength(3));
    },
  );

  test(
    'default chat history reads the latest fifty without deleting old messages',
    () async {
      for (var i = 0; i < 80; i++) {
        await c.chat.add(c.selectedId!, '합성 질문 $i');
      }
      final messages = c.chat.messages(c.selectedId!);
      expect(messages, hasLength(50));
      expect(messages.first.text, '합성 질문 30');
      expect(messages.last.text, '합성 질문 79');
      expect(vault.repository.chatMessages(c.selectedId!), hasLength(80));
    },
  );

  testWidgets('older chat messages remain reachable in batches', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 55; i++) {
        await c.chat.add(c.selectedId!, '합성 질문 $i');
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBody(c: c, pid: c.selectedId!),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('이전 질문 더 보기'),
      200,
      maxScrolls: 15,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('이전 질문 더 보기'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('합성 질문 0'),
      200,
      maxScrolls: 15,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('합성 질문 0'), findsOneWidget);
    expect(find.text('이전 질문 더 보기'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('medication-only home provides an empty state and add action', (
    tester,
  ) async {
    var preferences = c.uiPreferences;
    for (final section in HomeSection.values) {
      preferences = preferences.withOption(
        section.option,
        section == HomeSection.medications,
      );
    }
    await c.setUiPreferences(preferences);
    await tester.pumpWidget(CareApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('약 목록을 만들어 보세요'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '약 추가'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
