import 'dart:io';
import 'dart:typed_data';

import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/drafts.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/app.dart';
import 'package:care_notebook/presentation/editors.dart';
import 'package:care_notebook/presentation/accessible_image.dart';
import 'package:care_notebook/presentation/medication_times_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support.dart';
import 'chat_ui_support.dart';

// Safety scenarios defined before implementation:
// - Collapsing details must never erase observations or hide restored values.
// - Missing/invalid fields must block saving and lead to the relevant input.
// - Cancelled/duplicate time selections must not silently change a schedule;
//   legacy invalid drafts must remain visible and correctable.
// - At 200% text on a narrow screen, core controls remain reachable.
// - Photo zoom must work without pinching, clamp its range and reset safely.
// - Errors/completion must expose status semantics without reading patient text.
void main() {
  late Directory root;
  late CareController c;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-accessibility-');
    c = testController(VaultStore(root, MemorySecrets()), FakePlatform());
    await c.initialize();
    await c.startWithoutLock();
    await c.drafts.setRetention(DraftRetention.month);
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });

  Future<BuildContext> home(WidgetTester tester, {double scale = 1}) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(CareApp(controller: c));
    await tester.pumpAndSettle();
    return tester.element(find.byType(NavigationBar));
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 30,
    );
    await Scrollable.ensureVisible(tester.element(finder), alignment: .3);
    await tester.pumpAndSettle();
  }

  testWidgets('quick record keeps details across collapsing and saving', (
    tester,
  ) async {
    final ctx = await home(tester);
    final pending = editEntry(ctx, c, EntryKind.symptom);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('entry-field-location')), findsNothing);
    expect(find.text('음성으로 입력').hitTestable(), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('entry-field-symptom')),
      '시험 증상',
    );
    await reveal(tester, find.text('자세히 기록'));
    await tester.tap(find.text('자세히 기록'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('entry-field-location')),
      '시험 부위',
    );
    await reveal(tester, find.text('자세히 기록'));
    await tester.tap(find.text('자세히 기록'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('저장'));
    await tester.runAsync(() async {
      await tester.tap(find.text('저장'));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    await pending;
    expect(c.entries.single.fields['location'], '시험 부위');
    final editing = editEntry(
      ctx,
      c,
      EntryKind.symptom,
      entry: c.entries.single,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('entry-field-location')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await editing;
  });

  testWidgets('invalid required field is focused without saving a record', (
    tester,
  ) async {
    final ctx = await home(tester);
    final pending = editEntry(ctx, c, EntryKind.symptom);
    await tester.pumpAndSettle();
    await reveal(tester, find.text('저장'));
    await tester.runAsync(() async {
      await tester.tap(find.text('저장'));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    final field = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('entry-field-symptom')),
        matching: find.byType(EditableText),
      ),
    );
    expect(field.focusNode.hasFocus, isTrue);
    expect(c.entries, isEmpty);
    expect(find.text('입력 내용을 확인해 주세요.'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await pending;
  });

  testWidgets('home has reachable quick actions and a large notebook switch', (
    tester,
  ) async {
    await home(tester, scale: 2);
    expect(find.text('식사·수분').hitTestable(), findsOneWidget);
    final picker = find.byKey(const ValueKey('notebook-switch'));
    expect(tester.getSize(picker).height, greaterThanOrEqualTo(48));
    final actions = find.byKey(const ValueKey('quick-records'));
    expect(tester.getTopLeft(actions).dy, lessThan(300));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'home touch semantics meet minimum targets at normal and large text',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        for (final scale in [1.0, 2.0]) {
          await home(tester, scale: scale);
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        }
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets('restored optional observations are shown and saved intact', (
    tester,
  ) async {
    c.drafts.saveNow(
      id: c.drafts.newId(),
      patientId: c.selectedId!,
      payload: EntryDraftPayload(
        kind: EntryKind.symptom,
        at: DateTime(2026, 9, 20),
        fields: {'symptom': '합성 증상', 'action': '이미 작성한 관찰'},
      ),
      session: c.captureSession(),
      create: true,
    );
    final ctx = await home(tester);
    final pending = editEntry(
      ctx,
      c,
      EntryKind.symptom,
      restored: c.drafts.list(c.selectedId!).single,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('entry-field-action')), findsOneWidget);
    await reveal(tester, find.text('저장'));
    await tester.runAsync(() async {
      await tester.tap(find.text('저장'));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    await pending;
    expect(c.entries.single.fields['action'], '이미 작성한 관찰');
    expect(c.entries.single.occurredAt, DateTime(2026, 9, 20));
    expect(c.drafts.list(c.selectedId!), isEmpty);
  });

  testWidgets('duplicate selected time leaves the original schedule intact', (
    tester,
  ) async {
    final controller = TextEditingController(text: '08:00, 18:00');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
        home: Scaffold(
          body: MedicationTimesField(controller: controller, onChanged: () {}),
        ),
      ),
    );
    await tester.tap(find.text('18:00'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '08');
    await tester.enterText(find.byType(TextField).last, '00');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(controller.text, '08:00, 18:00');
    expect(find.text('이미 추가한 시각입니다.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'chat completion exposes a brief live status without patient text',
    (tester) async {
      await tester.runAsync(
        () => c.chat.setRetention(c.selectedId!, ChatRetention.week),
      );
      final handle = tester.ensureSemantics();
      try {
        await home(tester);
        await tester.tap(find.byTooltip('간병 도우미 대화'));
        await tester.pumpAndSettle();
        await acknowledgeChatNotice(tester);
        await tester.enterText(
          find.byKey(const ValueKey('chat_input')),
          '오늘 물 마신 기록',
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.byTooltip('질문 남기기'));
          await Future<void>.delayed(const Duration(milliseconds: 250));
        });
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(find.text('답변이 준비되었습니다.')),
          isSemantics(label: '답변이 준비되었습니다.', isLiveRegion: true),
        );
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets('selected times preserve legacy text and cancelled changes', (
    tester,
  ) async {
    final controller = TextEditingController(text: '08:00, bad-time');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MedicationTimesField(controller: controller, onChanged: () {}),
        ),
      ),
    );
    await tester.tap(find.text('시각 추가'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.text, '08:00, bad-time');
    expect(find.textContaining('bad-time'), findsOneWidget);
    await tester.tap(find.byTooltip('bad-time 시각 삭제'));
    await tester.pumpAndSettle();
    expect(controller.text, '08:00');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('image controls zoom and reset without gestures at large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 20, height: 20)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccessibleImage(bytes: bytes, semanticLabel: '시험 사진'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 12; i++) {
      await tester.tap(find.byTooltip('크게 보기'));
      await tester.pump();
    }
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 8);
    await tester.tap(find.byTooltip('작게 보기'));
    await tester.pump();
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      lessThan(8),
    );
    await tester.drag(find.byType(InteractiveViewer), const Offset(-100, -80));
    await tester.pumpAndSettle();
    for (var i = 0; i < 8; i++) {
      await tester.tap(find.byTooltip('작게 보기'));
      await tester.pump();
    }
    expect(viewer.transformationController!.value, Matrix4.identity());
    await tester.tap(find.byTooltip('크게 보기'));
    await tester.pump();
    await tester.tap(find.text('화면에 맞추기'));
    await tester.pump();
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);
    await tester.tap(find.byTooltip('크게 보기'));
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccessibleImage(
            bytes: Uint8List.fromList(
              img.encodePng(img.Image(width: 10, height: 10)),
            ),
            semanticLabel: '다른 사진',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!
          .value
          .getMaxScaleOnAxis(),
      1,
    );
    expect(tester.takeException(), isNull);
  });
}
