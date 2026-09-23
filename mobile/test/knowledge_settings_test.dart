import 'dart:io';
import 'dart:async';

import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/knowledge.dart';
import 'package:care_notebook/domain/knowledge_installation.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/l10n/app_strings.dart';
import 'package:care_notebook/presentation/knowledge_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class UiKnowledgeLibrary implements KnowledgeLibrary {
  UiKnowledgeLibrary(this.release);
  final KnowledgeRelease release;
  bool installed = false, failing = false;
  Completer<void>? pending;
  @override
  Future<KnowledgeInstallation> status() async =>
      KnowledgeInstallation(active: installed ? release : null);
  @override
  Future<String?> pickBundle() async => 'synthetic';
  @override
  Future<void> install(
    String path,
    void Function(double) progress,
    void Function() check,
  ) async {
    check();
    progress(.5);
    await pending?.future;
    check();
    if (failing) throw const KnowledgePackageException('test-only');
    installed = true;
    progress(1);
  }

  @override
  Future<void> rollback() async {}
  @override
  Future<KnowledgeReviewReader?> reader({String? packageHash}) async => null;
}

void main() {
  testWidgets(
    'narrow settings show preview status and preserve install after error',
    (tester) async {
      late Directory dir;
      late CareController c;
      late UiKnowledgeLibrary library;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('care-library-ui-');
        final release = KnowledgeRelease(
          await File(
            'assets/knowledge/releases/caregiver-essentials-v2-20260918.json',
          ).readAsBytes(),
        );
        library = UiKnowledgeLibrary(release);
        c = CareController(
          VaultStore(dir, MemorySecrets()),
          FakePlatform(),
          knowledge: library,
        );
        await c.initialize();
        await c.setPin('123456');
      });
      addTearDown(() async {
        c.dispose();
        await dir.delete(recursive: true);
      });
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppStrings.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('ko')],
          locale: const Locale('ko'),
          home: Scaffold(body: ListView(children: [KnowledgeSettings(c)])),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('설치된 근거 자료가 없습니다.'), findsOneWidget);
      await tester.tap(find.text('근거 자료 파일 선택'));
      await tester.pumpAndSettle();
      expect(find.text('개발용 미검수 자료 · 의료 답변 사용 불가'), findsOneWidget);
      expect(find.textContaining('42.78 MiB'), findsOneWidget);
      library.failing = true;
      await tester.tap(find.text('근거 자료 파일 선택'));
      await tester.pumpAndSettle();
      expect(find.text('자료 작업을 완료하지 못했습니다. 기존 자료는 유지됩니다.'), findsOneWidget);
      expect(library.installed, isTrue);
      library.failing = false;
      library.pending = Completer<void>();
      await tester.tap(find.text('근거 자료 파일 선택'));
      await tester.pump();
      await tester.pump();
      await tester.ensureVisible(find.text('취소'));
      await tester.tap(find.text('취소'));
      library.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('자료 설치를 취소했습니다. 기존 자료는 유지됩니다.'), findsOneWidget);
      expect(find.text('자료 작업을 완료하지 못했습니다. 기존 자료는 유지됩니다.'), findsNothing);
      expect(library.installed, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
