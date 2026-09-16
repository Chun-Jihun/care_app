import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/ai.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/domain/reviewed_input.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/ai_draft_page.dart';

import 'ai_service_test.dart' show FakeAi;
import 'support.dart';

class FieldAi extends FakeAi {
  @override
  Future<OcrDraft> recognize(Uint8List image, String language) async =>
      OcrDraft([
        const OcrLine('음식: 죽', .9, [0, 0, 1, .5]),
        const OcrLine('수분 (mL): 100', .7, [0, .5, 1, 1]),
      ]);
}

void main() {
  testWidgets(
    'fields require selection; edited candidates need confirmation and existing fields stay unchanged',
    (tester) async {
      late Directory root;
      late CareController c;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('care-input-fields-');
        c = CareController(
          VaultStore(root, MemorySecrets()),
          FakePlatform(),
          aiRuntime: FieldAi(),
        );
        await c.initialize();
        await c.setPin('123456');
      });
      addTearDown(() async {
        c.dispose();
        await root.delete(recursive: true);
      });
      ReviewedInput? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await reviewRecordInput(
                    context,
                    c,
                    c.selectedId!,
                    kind: EntryKind.meal,
                    currentFields: {'food': '기존 음식'},
                    photo: Uint8List.fromList(
                      img.encodePng(img.Image(width: 10, height: 10)),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('글자 읽기'));
      await tester.pumpAndSettle();
      Future<void> reveal(Finder finder) async {
        await tester.scrollUntilVisible(
          finder,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
      }

      final water = find.byKey(const ValueKey('aiField-water_ml'));
      await reveal(water);
      expect(tester.widget<CheckboxListTile>(water).value, false);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('aiField-food')),
            )
            .onChanged,
        isNull,
      );
      expect(result, isNull);
      await tester.tap(water);
      await tester.pumpAndSettle();
      final body = find.byKey(const ValueKey('aiDraftText'));
      await tester.ensureVisible(body);
      await tester.enterText(body, '음식: 죽\n수분 (mL): 150');
      await reveal(water);
      expect(tester.widget<CheckboxListTile>(water).value, false);
      await tester.tap(water);
      await tester.pumpAndSettle();
      await reveal(find.text('확인한 내용을 입력란에 반영'));
      await tester.tap(find.text('확인한 내용을 입력란에 반영'));
      await tester.pumpAndSettle();
      expect(result!.fields, {'water_ml': '150'});
      expect(result!.text, '음식: 죽\n수분 (mL): 150');
      expect(c.entries, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
