import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/l10n/app_strings.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/app.dart';
import 'package:care_notebook/presentation/ai_reply.dart';
import 'package:care_notebook/presentation/task_list.dart';

import 'support.dart';

void main() {
  late Directory root;
  late CareController c;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-refinement-ui-');
    c = testController(VaultStore(root, MemorySecrets()), FakePlatform());
    await c.initialize();
    await c.startWithoutLock();
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });
  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(CareApp(controller: c));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'UX-01 matching records beyond eight are reachable and scope changes hide them',
    (tester) async {
      final pid = c.selectedId!;
      await tester.runAsync(() async {
        for (var i = 0; i < 55; i++) {
          await c.records.saveEntry(
            pid,
            kind: EntryKind.generalNote,
            note: 'note-$i',
            occurredAt: DateTime(2026, 9, 18, 0, i),
          );
        }
        await c.chat.setRetention(pid, ChatRetention.forever);
        await c.ai.ask(pid, '2026-09-18 메모 기록', AppLanguage.korean);
      });
      await show(tester);
      final context = tester.element(find.byType(NavigationBar));
      final reply = c.chat.messages(pid).last.reply!;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: SingleChildScrollView(child: AiReplyView(c, pid, reply)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('같은 조건으로 전체 기록 보기'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('기록 더 보기'),
        500,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('기록 더 보기'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('note-0'),
        500,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.textContaining('note-0'), findsOneWidget);
      await tester.runAsync(() async {
        final old = c.records
            .entries(pid)
            .singleWhere((e) => e.note == 'note-0');
        await c.records.saveEntry(
          pid,
          id: old.id,
          expectedVersion: old.version,
          kind: old.kind,
          occurredAt: old.occurredAt,
          note: 'edited original',
        );
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('note-0'), findsNothing);
      expect(find.textContaining('edited original'), findsOneWidget);
      await tester.runAsync(() async {
        final other = await c.profiles.createPatient();
        await c.selectPatient(other.id);
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('edited original'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('UX-02 completed tasks remain accessible and can be reopened', (
    tester,
  ) async {
    final pid = c.selectedId!;
    await tester.runAsync(() async {
      final task = await c.taskBook.saveTask(
        pid,
        title: '완료한 준비',
        dueAt: DateTime.now(),
      );
      await c.taskBook.completeTask(pid, task.id, true);
    });
    await show(tester);
    expect(find.text('완료한 준비'), findsNothing);
    final context = tester.element(find.byType(NavigationBar));
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => TaskListPage(c, pid)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('완료한 할 일도 보기'));
    await tester.pumpAndSettle();
    expect(find.text('완료한 준비'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byType(Checkbox));
    });
    await tester.pumpAndSettle();
    expect(c.tasks.single.done, isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'UX-03 search reset cancels pending filtering and brings records back',
    (tester) async {
      await tester.runAsync(
        () => c.records.saveEntry(
          c.selectedId!,
          kind: EntryKind.generalNote,
          note: '찾을 수 있는 원문',
          occurredAt: DateTime.now(),
        ),
      );
      await show(tester);
      await tester.tap(find.text('일기').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '없는 내용');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.textContaining('찾을 수 있는 원문'), findsNothing);
      await tester.tap(find.byTooltip('검색어 지우기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('찾을 수 있는 원문'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('UX-04 task controls fit a narrow screen with 200 percent text', (
    tester,
  ) async {
    final pid = c.selectedId!;
    await tester.runAsync(
      () => c.taskBook.saveTask(
        pid,
        title: '오래된 진료 기록과 준비물을 함께 챙기기',
        note: '메모도 큰 글자에서 잘려 사라지지 않아야 합니다.',
        dueAt: DateTime(2020),
        reminder: true,
      ),
    );
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(MaterialApp(home: TaskListPage(c, pid)));
    await tester.pumpAndSettle();
    expect(find.textContaining('예정 시각 지남'), findsOneWidget);
    expect(find.byTooltip('할 일 삭제'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
