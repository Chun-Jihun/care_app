import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/app.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/domain/drafts.dart';
import 'package:care_notebook/infrastructure/care_database.dart';

import 'support.dart';

void main() {
  late Directory root;
  late CareController c;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-ui-');
    c = CareController(VaultStore(root, MemorySecrets()), FakePlatform());
    await c.initialize();
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });
  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => c.setPin('123456'));
    c.db.setDraftRetention(DraftRetention.month);
    await tester.pumpWidget(CareApp(controller: c));
    await tester.pumpAndSettle();
  }

  Future<void> settleIO(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'LOCAL-10/14 record form persists exact text and lock destroys private routes',
    (tester) async {
      await start(tester);
      expect(find.text('오늘의 돌봄'), findsOneWidget);
      await tester.tap(find.text('기록하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('자유 메모'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '합성 기록: 오후에 산책함');
      await tester.runAsync(() async {
        await tester.tap(find.text('저장'));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      expect(c.entries.single.note, '합성 기록: 오후에 산책함');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('일기'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('합성 기록: 오후에 산책함').last);
      await tester.pumpAndSettle();
      expect(find.text('기록 삭제'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('기록 삭제'), findsNothing);
      expect(find.text('돌봄 일기'), findsOneWidget);
      await tester.tap(find.textContaining('합성 기록: 오후에 산책함').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('기록 삭제'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      c.lock();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('수첩 열기'), findsOneWidget);
      expect(find.textContaining('합성 기록'), findsNothing);
      await tester.runAsync(() => c.unlockPin('123456'));
      await tester.pumpAndSettle();
      expect(find.text('오늘의 돌봄'), findsOneWidget);
      expect(find.text('기록 삭제'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'navigation and failed validation remain usable on a small screen',
    (tester) async {
      await start(tester);
      for (final label in ['일기', '약', '진료 준비', '설정', '오늘']) {
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('기록하기'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(of: find.text('측정'), matching: find.byType(ActionChip)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '체온');
      await tester.enterText(find.byType(TextField).at(1), '사용자 측정값');
      await tester.ensureVisible(find.text('저장'));
      await tester.tap(find.text('저장'));
      await settleIO(tester);
      expect(find.text('필수 항목을 입력해 주세요: 단위'), findsOneWidget);
      expect(find.text('사용자 측정값'), findsOneWidget);
      expect(c.entries, isEmpty);
    },
  );
  testWidgets('REVIEW-01 manual lock evicts decoded image cache', (
    tester,
  ) async {
    await start(tester);
    final photo = MemoryImage(
      Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2))),
    );
    await tester.runAsync(
      () => precacheImage(photo, tester.element(find.text('오늘의 돌봄'))),
    );
    expect(PaintingBinding.instance.imageCache.currentSize, greaterThan(0));
    c.lock();
    await tester.pumpAndSettle();
    expect(PaintingBinding.instance.imageCache.currentSize, 0);
    expect(PaintingBinding.instance.imageCache.liveImageCount, 0);
  });
  testWidgets('REVIEW-07 large text and keyboard keep chat usable', (
    tester,
  ) async {
    await start(tester);
    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('간병 도우미 대화'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(
      () => c.setChatRetention(c.selectedId!, ChatRetention.week),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 270);
    addTearDown(tester.view.resetViewInsets);
    await tester.enterText(find.byKey(const ValueKey('chat_input')), '합성 질문');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('질문 남기기').hitTestable(), findsOneWidget);
  });

  testWidgets('REVIEW-08 back confirmation preserves an edited form', (
    tester,
  ) async {
    await start(tester);
    await tester.tap(find.text('기록하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('자유 메모'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '잃으면 안 되는 합성 초안');
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('작성 중인 내용을 어떻게 할까요?'), findsOneWidget);
    await tester.tap(find.text('계속 작성'));
    await tester.pumpAndSettle();
    expect(find.text('잃으면 안 되는 합성 초안'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('초안 삭제'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('오늘의 돌봄'), findsOneWidget);
    expect(c.entries, isEmpty);
    expect(c.db.drafts(c.selectedId), isEmpty);
  });
  testWidgets(
    'CHAT-01/02/05 chat UI needs policy, requires visit confirmation and clears private routes',
    (tester) async {
      await start(tester);
      await tester.tap(find.byTooltip('간병 도우미 대화'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('chat_input')),
        '대화 시험 질문',
      );
      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.arrow_upward),
      );
      expect(button.onPressed, isNull);
      await tester.runAsync(
        () => c.setChatRetention(c.selectedId!, ChatRetention.week),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('질문 남기기'));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pumpAndSettle();
      expect(find.text('대화 시험 질문'), findsOneWidget);
      expect(find.textContaining('답변 없음'), findsOneWidget);
      expect(c.entries, isEmpty);
      await tester.tap(find.byTooltip('질문 메뉴'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('진료 준비로 정리'));
      await tester.pumpAndSettle();
      expect(find.text('대화 시험 질문'), findsOneWidget);
      expect(c.visits, isEmpty);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('작성 중인 내용을 어떻게 할까요?'), findsOneWidget);
      await tester.tap(find.text('초안 보관 후 나가기'));
      await tester.pumpAndSettle();
      expect(find.text('간병 도우미'), findsOneWidget);
      expect(c.visits, isEmpty);
      await tester.tap(find.byType(DropdownButtonFormField<ChatRetention>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('이번 잠금 해제 동안만').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(c.db.chatRetention(c.selectedId!), ChatRetention.week);
      expect(find.text('7일'), findsOneWidget);
      c.lock();
      await tester.pumpAndSettle();
      expect(find.text('대화 시험 질문'), findsNothing);
      expect(find.text('수첩 열기'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('synthetic home preview', (tester) async {
    await start(tester);
    await tester.runAsync(() async {
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      final file = File('C:/Windows/Fonts/malgun.ttf');
      if (await file.exists()) {
        final loader = FontLoader('Roboto')
          ..addFont(file.readAsBytes().then((b) => ByteData.sublistView(b)));
        await loader.load();
      }
      final pid = c.selectedId!;
      c.db.updatePatient(
        pid,
        alias: '엄마의 수첩',
        role: 'family',
        context: '',
        contact: '',
      );
      final now = DateTime.now();
      c.db.saveEntry(
        pid,
        kind: EntryKind.meal,
        occurredAt: now,
        note: '편안하게 식사를 마쳤어요.',
        fields: {'food': '야채죽', 'amount': 'most', 'water_ml': '200'},
      );
      c.db.saveEntry(
        pid,
        kind: EntryKind.activity,
        occurredAt: now.subtract(const Duration(hours: 1)),
        fields: {'activity': '집 앞 산책', 'minutes': '15'},
      );
      c.db.saveTask(
        pid,
        title: '다음 진료 때 물어볼 질문 정리',
        dueAt: now.add(const Duration(hours: 2)),
      );
      await c.refresh();
    });
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: CareApp(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final raster = await boundary.toImage(pixelRatio: 2);
      final bytes = await raster.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/preview').create(recursive: true);
      await File('build/preview/today.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      raster.dispose();
    });
    await tester.tap(find.byTooltip('간병 도우미 대화'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await c.setChatRetention(c.selectedId!, ChatRetention.week);
      await c.addChatMessage(c.selectedId!, '다음 진료 때 식사량이 줄어든 점을 물어보고 싶어요.');
      await c.addChatMessage(c.selectedId!, '산책 후 느낀 불편함도 함께 정리해 둘게요.');
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final raster = await boundary.toImage(pixelRatio: 2);
      final bytes = await raster.toByteData(format: ui.ImageByteFormat.png);
      await File('build/preview/chat.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      raster.dispose();
    });
    debugDisableShadows = true;
  });
}
