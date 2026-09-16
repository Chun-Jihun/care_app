import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/ai.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/ai_settings.dart';

import 'ai_service_test.dart' show FakeAi;
import 'support.dart';

class ManagedAi extends FakeAi {
  bool installed = true;
  int removals = 0;
  @override
  Future<AiModelStatus> status() async => AiModelStatus(
    installed: installed,
    version: 'test-v1',
    bytes: 1720000000,
  );
  @override
  Future<void> removeModels() async {
    removals++;
    installed = false;
  }
}

void main() {
  testWidgets(
    'model removal requires confirmation, refreshes status and preserves records',
    (tester) async {
      late Directory root;
      late CareController c;
      final ai = ManagedAi();
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('care-model-settings-');
        c = CareController(
          VaultStore(root, MemorySecrets()),
          FakePlatform(),
          aiRuntime: ai,
        );
        await c.initialize();
        await c.setPin('123456');
        await c.records.saveEntry(
          c.selectedId!,
          kind: EntryKind.generalNote,
          occurredAt: DateTime.now(),
          note: 'retained',
        );
      });
      addTearDown(() async {
        c.dispose();
        await root.delete(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: AiSettings(c))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('모델 버전: test-v1'), findsOneWidget);
      await tester.ensureVisible(find.text('AI 모델 삭제'));
      await tester.tap(find.text('AI 모델 삭제'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '취소'));
      await tester.pumpAndSettle();
      expect(ai.removals, 0);
      await tester.tap(find.text('AI 모델 삭제'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '삭제'));
      await tester.pumpAndSettle();
      expect(ai.removals, 1);
      expect(find.text('모델 설치 필요'), findsOneWidget);
      expect(find.text('AI 모델 삭제'), findsNothing);
      expect(c.entries.single.note, 'retained');
      expect(tester.takeException(), isNull);
    },
  );
}
