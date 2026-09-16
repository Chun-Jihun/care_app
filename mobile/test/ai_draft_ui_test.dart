import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/ai_draft_page.dart';

import 'ai_service_test.dart' show FakeAi;
import 'support.dart';

void main() {
  testWidgets(
    'OCR requires editing and explicit acceptance; cancel preserves input',
    (tester) async {
      late Directory root;
      late CareController c;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('care-ai-review-');
        c = CareController(
          VaultStore(root, MemorySecrets()),
          FakePlatform(),
          aiRuntime: FakeAi(),
        );
        await c.initialize();
        await c.setPin('123456');
      });
      addTearDown(() async {
        c.dispose();
        await root.delete(recursive: true);
      });
      final photo = Uint8List.fromList(
        img.encodePng(img.Image(width: 10, height: 10)),
      );
      String value = 'existing input';
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  final draft = await reviewAiInput(
                    context,
                    c,
                    c.selectedId!,
                    photo: photo,
                  );
                  if (draft != null) value = draft;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('possibly wrong 15 mg'), findsNothing);
      await tester.tap(find.text('글자 읽기'));
      await tester.pumpAndSettle();
      expect(find.text('possibly wrong 15 mg'), findsOneWidget);
      expect(value, 'existing input');
      expect(c.entries, isEmpty);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('aiDraftText')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const ValueKey('aiDraftText')),
        'discarded correction',
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('ocrMemo')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const ValueKey('ocrMemo')),
        'discarded memo',
      );
      await tester.scrollUntilVisible(
        find.text('취소'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(value, 'existing input');
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('글자 읽기'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('aiDraftText')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const ValueKey('aiDraftText')),
        'corrected 5 mg',
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('ocrOriginal')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('수정 전 인식 결과 보기'));
      await tester.pumpAndSettle();
      expect(find.text('possibly wrong 15 mg'), findsOneWidget);
      await tester.tap(find.text('수정 전 인식 결과 보기'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('ocrMemo')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const ValueKey('ocrMemo')),
        '  원본 사진과 대조함  ',
      );
      await tester.scrollUntilVisible(
        find.text('확인한 내용을 입력란에 반영'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('확인한 내용을 입력란에 반영'));
      await tester.pumpAndSettle();
      expect(value, 'corrected 5 mg\n\n추가 메모:\n원본 사진과 대조함');
      expect(c.entries, isEmpty);
    },
  );

  testWidgets(
    'OCR empty body and combined length are blocked; large text stays usable',
    (tester) async {
      late Directory root;
      late CareController c;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('care-ai-review-limits-');
        c = CareController(
          VaultStore(root, MemorySecrets()),
          FakePlatform(),
          aiRuntime: FakeAi(),
        );
        await c.initialize();
        await c.setPin('123456');
      });
      addTearDown(() async {
        c.dispose();
        await root.delete(recursive: true);
      });
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: AiDraftPage(
            c,
            c.selectedId!,
            photo: Uint8List.fromList(
              img.encodePng(img.Image(width: 10, height: 10)),
            ),
          ),
        ),
      );
      Future<void> reveal(Finder target, double step) async {
        // Drag outside text fields: a long editable body has its own scroll area.
        for (var i = 0; target.evaluate().isEmpty && i < 40; i++) {
          await tester.dragFrom(const Offset(5, 320), Offset(0, -step));
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
      }

      final body = find.byKey(const ValueKey('aiDraftText'));
      final memo = find.byKey(const ValueKey('ocrMemo'));
      final apply = find.widgetWithText(FilledButton, '확인한 내용을 입력란에 반영');
      await reveal(find.text('글자 읽기'), 200);
      await tester.tap(find.text('글자 읽기'));
      await tester.pumpAndSettle();
      await reveal(body, 200);
      await tester.enterText(body, '   ');
      await reveal(memo, 200);
      await tester.enterText(memo, 'a note without reviewed text');
      await reveal(apply, 200);
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);
      await reveal(body, -200);
      await tester.enterText(body, 'a' * 19990);
      await reveal(apply, 200);
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);
      expect(find.text('본문과 메모를 합쳐 20,000자까지 반영할 수 있어요.'), findsOneWidget);
      await reveal(memo, -200);
      await tester.enterText(memo, '');
      await reveal(apply, 200);
      expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
      expect(c.entries, isEmpty);
      expect(c.drafts.list(c.selectedId!), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
