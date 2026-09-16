import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/ai.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/l10n/app_strings.dart';
import 'package:care_notebook/presentation/app.dart';
import 'package:care_notebook/presentation/ai_evidence_page.dart';
import 'package:care_notebook/presentation/ai_reply.dart';
import 'package:care_notebook/presentation/details.dart';

import 'ai_service_test.dart' show FakeAi;
import 'support.dart';
import 'chat_ui_support.dart';

void main() {
  late Directory root;
  late CareController c;
  late String pid;
  late CareEntry entry;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-evidence-');
    c = CareController(
      VaultStore(root, MemorySecrets()),
      FakePlatform(),
      aiRuntime: FakeAi(),
    );
    await c.initialize();
    await c.setPin('123456');
    pid = c.selectedId!;
    await c.chat.setRetention(pid, ChatRetention.forever);
    entry = await c.records.saveEntry(
      pid,
      kind: EntryKind.measurement,
      occurredAt: DateTime(2026, 9, 11, 9, 30),
      fields: {'measurement': '혈압', 'value': '120/80', 'unit': 'mmHg'},
      note: '합성 원본: 재측정하지 않음',
    );
    await c.ai.ask(pid, '2026-09-11 09:30 혈압', AppLanguage.korean);
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });

  Future<void> reveal(
    WidgetTester tester,
    Finder target, {
    double step = 200,
  }) async {
    await tester.scrollUntilVisible(
      target,
      step,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> openEvidence(WidgetTester tester) async {
    await tester.pumpWidget(CareApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('간병 도우미 대화'));
    await tester.pumpAndSettle();
    await acknowledgeChatNotice(tester);
    await reveal(tester, find.text('근거 보기'));
    await tester.tap(find.text('근거 보기'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'source button opens exact notebook content and original; lock removes it',
    (tester) async {
      await openEvidence(tester);
      expect(find.byType(AiEvidencePage), findsOneWidget);
      expect(find.text('답변에서 참고한 버전: 1'), findsOneWidget);
      expect(find.text('측정값 (혈압은 120/80처럼 입력): 120/80'), findsOneWidget);
      expect(find.text('합성 원본: 재측정하지 않음'), findsOneWidget);
      await reveal(tester, find.text('의료 근거 문서'));
      expect(
        find.text('검수된 의료 문서가 아직 연결되지 않았습니다. 의료 문서를 인용한 답변은 제공하지 않습니다.'),
        findsOneWidget,
      );
      await reveal(tester, find.text('원본 기록 보기'), step: -150);
      await tester.tap(find.text('원본 기록 보기'));
      await tester.pumpAndSettle();
      expect(find.byType(EntryDetails), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chatAiNotice')), findsNothing);
      await reveal(tester, find.text('근거 보기'));
      await tester.tap(find.text('근거 보기'));
      await tester.pumpAndSettle();
      c.lock();
      await tester.pumpAndSettle();
      expect(find.byType(LockScreen), findsOneWidget);
      expect(find.byType(AiEvidencePage), findsNothing);
      expect(find.text('합성 원본: 재측정하지 않음'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lookup scope and literal values remain readable with large text',
    (tester) async {
      await tester.runAsync(
        () => c.ai.ask(pid, '2026-09-11 09:30 측정 기록', AppLanguage.korean),
      );
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AiReplyView(c, pid, c.chat.messages(pid).last.reply!),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('조회 기간: 2026-09-11 ~ 2026-09-11'), findsOneWidget);
      expect(find.text('조회 시각: 09:30'), findsOneWidget);
      expect(find.text('조회 항목: 측정'), findsOneWidget);
      expect(find.text('합성 원본: 재측정하지 않음'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changed, deleted and foreign records cannot become answer excerpts',
    (tester) async {
      await openEvidence(tester);
      await tester.runAsync(
        () => c.records.saveEntry(
          pid,
          id: entry.id,
          expectedVersion: entry.version,
          kind: entry.kind,
          occurredAt: entry.occurredAt,
          fields: entry.fields,
          note: '수정된 합성 내용',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('답변 이후 기록이 수정되었어요. 현재 기록을 다시 확인해 주세요.'), findsOneWidget);
      expect(find.text('수정된 합성 내용'), findsNothing);
      expect(find.text('합성 원본: 재측정하지 않음'), findsNothing);
      await tester.runAsync(() => c.records.deleteEntry(pid, entry.id));
      await tester.pumpAndSettle();
      expect(find.text('출처 기록이 삭제되었거나 이번 백업에 포함되지 않았습니다.'), findsOneWidget);
      expect(find.text('원본 기록 보기'), findsNothing);
      await tester.runAsync(() async {
        final other = await c.profiles.createPatient();
        await c.selectPatient(other.id);
      });
      await tester.pumpAndSettle();
      expect(find.text('참고한 내 기록'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing medical evidence has no invented citation at large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [AiReplyView(c, pid, AiReply(AiReplyKind.medicalHold))],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('근거 보기'));
      await tester.pumpAndSettle();
      expect(find.text('이 답변은 수첩 기록을 인용하지 않았습니다.'), findsOneWidget);
      await reveal(
        tester,
        find.text('검수된 의료 문서가 아직 연결되지 않았습니다. 의료 문서를 인용한 답변은 제공하지 않습니다.'),
      );
      expect(find.text('원본 기록 보기'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
