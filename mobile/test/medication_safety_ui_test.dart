import 'dart:io';

import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/medication_safety_page.dart';
import 'package:care_notebook/l10n/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CareController c;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('drug-ui-test-');
    c = CareController(VaultStore(root, MemorySecrets()), FakePlatform());
    await c.initialize();
    await c.setPin('123456');
    await c.profiles.createPatient();
    await c.medicationBook.saveMedication(
      c.selectedId!,
      name: '합성 제품 이름이 긴 약 기록',
      instruction: '',
      times: [],
    );
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });
  testWidgets(
    'narrow large text UI explains missing catalog and never shows safe status',
    (tester) async {
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
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: MedicationSafetyPage(c, c.selectedId!),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('현재 약 목록으로 확인'));
      await tester.tap(find.text('현재 약 목록으로 확인'));
      await tester.pumpAndSettle();
      expect(find.text('설치된 근거 자료가 없습니다.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('합성 제품 이름이 긴 약 기록'));
      await tester.tap(find.text('합성 제품 이름이 긴 약 기록'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('검색'));
      await tester.pumpAndSettle();
      expect(find.text('설치된 근거 자료가 없습니다.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
