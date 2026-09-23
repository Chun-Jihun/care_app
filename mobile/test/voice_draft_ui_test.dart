import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/ai.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/ai_draft_page.dart';

import 'ai_service_test.dart' show FakeAi;
import 'support.dart';

class TestMicrophone implements MicrophoneCapture {
  Completer<void>? permission;
  int starts = 0;
  bool disposed = false;
  final samples = Float32List.fromList([.1, .2]);
  @override
  Future<void> start(void Function() full) async {
    starts++;
    await permission?.future;
  }

  @override
  Future<Float32List> stop() async => samples;
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  late Directory root;
  late CareController c;
  late List<TestMicrophone> microphones;
  Future<void> open(WidgetTester tester, {TestMicrophone? first}) async {
    microphones = [];
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('care-voice-review-');
      c = CareController(
        VaultStore(root, MemorySecrets()),
        FakePlatform(),
        aiRuntime: FakeAi(),
        microphone: () {
          final mic = microphones.isEmpty && first != null
              ? first
              : TestMicrophone();
          microphones.add(mic);
          return mic;
        },
      );
      await c.initialize();
      await c.setPin('123456');
    });
    addTearDown(() async {
      c.dispose();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(MaterialApp(home: AiDraftPage(c, c.selectedId!)));
    await tester.pumpAndSettle(); // Wait for the model readiness check.
  }

  testWidgets(
    'voice originals remain available and another clip preserves edits',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('녹음 시작'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('녹음 마치기'));
      await tester.pumpAndSettle();
      expect(microphones.single.samples, everyElement(0));
      final body = find.byKey(const ValueKey('aiDraftText'));
      await tester.ensureVisible(body);
      await tester.enterText(body, '복용하지 않음 · 수정한 5 mg');
      await tester.ensureVisible(find.text('이어서 녹음'));
      await tester.tap(find.text('이어서 녹음'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('녹음 마치기'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(body).controller!.text,
        '복용하지 않음 · 수정한 5 mg\npossibly wrong 15 mg',
      );
      await tester.ensureVisible(find.text('수정 전 인식 결과 보기'));
      await tester.tap(find.text('수정 전 인식 결과 보기'));
      await tester.pumpAndSettle();
      expect(
        find.text('possibly wrong 15 mg\npossibly wrong 15 mg'),
        findsOneWidget,
      );
      expect(c.entries, isEmpty);
      expect(c.drafts.list(c.selectedId!), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending microphone permission cannot start twice or resume after backgrounding',
    (tester) async {
      final mic = TestMicrophone()..permission = Completer<void>();
      await open(tester, first: mic);
      final start = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '녹음 시작'))
          .onPressed!;
      start();
      start();
      await tester.pump();
      expect(mic.starts, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      mic.permission!.complete();
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(mic.disposed, true);
      expect(find.text('녹음 마치기'), findsNothing);
      expect(find.text('녹음 시작'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
