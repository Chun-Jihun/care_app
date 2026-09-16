import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/app.dart';
import 'package:care_notebook/presentation/chat_page.dart';

import 'ai_service_test.dart' show FakeAi;
import 'chat_ui_support.dart';
import 'support.dart';

void main() {
  late Directory root;
  late CareController c;
  late FakeAi ai;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-chat-notice-');
    ai = FakeAi();
    c = CareController(
      VaultStore(root, MemorySecrets()),
      FakePlatform(),
      aiRuntime: ai,
    );
    await c.initialize();
    await c.setPin('123456');
    await c.chat.setRetention(c.selectedId!, ChatRetention.forever);
    await c.addChatMessage(c.selectedId!, '확인 전에는 보이지 않는 합성 대화');
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byTooltip('간병 도우미 대화'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatAiNotice')), findsOneWidget);
    expect(find.byType(ChatBody), findsNothing);
    expect(find.text('확인 전에는 보이지 않는 합성 대화'), findsNothing);
    expect(ai.calls, 0);
  }

  testWidgets(
    'notice gates every entry; outside tap cannot bypass; cancel and back leave chat',
    (tester) async {
      await tester.pumpWidget(CareApp(controller: c));
      await tester.pumpAndSettle();
      await open(tester);
      expect(find.textContaining('틀린 답변'), findsOneWidget);
      expect(find.textContaining('진단·처방·치료 결정'), findsOneWidget);
      expect(find.textContaining('대한민국에서는 119'), findsOneWidget);
      expect(find.textContaining('현재는 수첩 기록 조회'), findsOneWidget);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chatAiNotice')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chatAiNoticeCancel')));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsNothing);

      await open(tester);
      await acknowledgeChatNotice(tester);
      expect(find.byType(ChatBody), findsOneWidget);
      expect(find.byKey(const ValueKey('chat_input')), findsOneWidget);
      await tester.runAsync(c.refresh);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chatAiNotice')), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await open(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsNothing);
      expect(find.byKey(const ValueKey('chatAiNotice')), findsNothing);
      expect(c.chat.messages(c.selectedId!).single.text, '확인 전에는 보이지 않는 합성 대화');
      expect(ai.calls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lock removes pending notice and unlock requires a fresh acknowledgement',
    (tester) async {
      await tester.pumpWidget(CareApp(controller: c));
      await tester.pumpAndSettle();
      await open(tester);
      c.lock();
      await tester.pumpAndSettle();
      expect(find.byType(LockScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('chatAiNotice')), findsNothing);
      expect(find.byType(ChatPage), findsNothing);
      await tester.runAsync(() => c.unlockPin('123456'));
      await tester.pumpAndSettle();
      await open(tester);
      await acknowledgeChatNotice(tester);
      expect(find.byType(ChatBody), findsOneWidget);
      expect(ai.calls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rapid entry taps produce one page and one notice', (
    tester,
  ) async {
    await tester.pumpWidget(CareApp(controller: c));
    await tester.pumpAndSettle();
    final launch = tester
        .widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.chat_bubble_outline),
        )
        .onPressed!;
    // Simulate two already queued activations before the next frame.
    launch();
    launch();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatAiNotice')), findsOneWidget);
    expect(find.byType(ChatPage, skipOffstage: false), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chatAiNoticeCancel')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
