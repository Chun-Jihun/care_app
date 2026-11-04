import 'dart:async';
import 'dart:io';

import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/drafts.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/domain/ui_preferences.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/app.dart';
import 'package:care_notebook/presentation/display_settings_page.dart';
import 'package:care_notebook/presentation/editors.dart';
import 'package:care_notebook/presentation/sections/today.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

// Public screen/controller regression scenarios for phases 1–3:
// - App options preserve larger OS text, readable controls and keyboard access.
// - Switches change actual presentation, remain reversible and retain records.
// - A blank intake status cannot create a fact; duplicate logging needs review.
// - Recent-input suggestions never cross notebooks or copy observation states.
void main() {
  late Directory root;
  late CareController c;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-ui-access-');
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
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(CareApp(controller: c));
    await tester.pumpAndSettle();
    return tester.element(find.byType(NavigationBar));
  }

  Future<void> tapIo(
    WidgetTester tester,
    Finder target, {
    bool settle = true,
  }) async {
    await tester.ensureVisible(target);
    await tester.runAsync(() async {
      await tester.tap(target);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  test('next check follows user-entered times across midnight', () async {
    final med = await c.medicationBook.saveMedication(
      c.selectedId!,
      name: '합성 예정 약',
      instruction: '',
      times: ['09:00', '18:00'],
    );
    expect(
      nextMedicationCheck(med, DateTime(2026, 11, 4, 10)),
      DateTime(2026, 11, 4, 18),
    );
    expect(
      nextMedicationCheck(med, DateTime(2026, 11, 4, 19)),
      DateTime(2026, 11, 5, 9),
    );
  });

  testWidgets(
    'combined display options retain 200 percent OS text and home targets',
    (tester) async {
      for (final option in [
        UiOption.largeText,
        UiOption.boldText,
        UiOption.highContrast,
        UiOption.largeControls,
        UiOption.lowGraphics,
      ]) {
        await c.setUiPreferences(c.uiPreferences.withOption(option, true));
      }
      final semantics = tester.ensureSemantics();
      try {
        final ctx = await home(tester, scale: 2);
        expect(MediaQuery.textScalerOf(ctx).scale(16), 32);
        expect(MediaQuery.boldTextOf(ctx), isTrue);
        expect(MediaQuery.highContrastOf(ctx), isTrue);
        expect(MediaQuery.disableAnimationsOf(ctx), isTrue);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('display switch applies on screen and reset preserves records', (
    tester,
  ) async {
    await tester.runAsync(
      () => c.records.saveEntry(
        c.selectedId!,
        kind: EntryKind.generalNote,
        occurredAt: DateTime.now(),
        note: '합성 보존 기록',
      ),
    );
    final ctx = await home(tester);
    unawaited(
      Navigator.of(
        ctx,
      ).push(MaterialPageRoute<void>(builder: (_) => DisplaySettingsPage(c))),
    );
    await tester.pumpAndSettle();
    await tapIo(tester, find.byKey(const ValueKey('ui-largeText')));
    final settingsContext = tester.element(find.byType(DisplaySettingsPage));
    expect(
      MediaQuery.textScalerOf(settingsContext).scale(16),
      closeTo(19.2, .001),
    );
    await tester.scrollUntilVisible(
      find.text('화면 설정 기본값으로'),
      350,
      maxScrolls: 30,
    );
    await tapIo(tester, find.text('화면 설정 기본값으로'));
    expect(c.uiPreferences.enabled(UiOption.largeText), isFalse);
    expect(c.records.entries(c.selectedId!).single.note, '합성 보존 기록');
    expect(tester.takeException(), isNull);
  });

  testWidgets('intake requires deliberate status and keeps patient context', (
    tester,
  ) async {
    final med = (await tester.runAsync(
      () => c.medicationBook.saveMedication(
        c.selectedId!,
        name: '합성 약',
        instruction: '직접 받은 지시',
        times: [],
      ),
    ))!;
    final ctx = await home(tester, scale: 2);
    final pending = recordIntake(ctx, c, med);
    await tester.pumpAndSettle();
    expect(find.text('돌봄 대상 · 실제 복약'), findsOneWidget);
    await tapIo(tester, find.text('복약 기록 저장'));
    expect(c.entries, isEmpty);
    expect(find.text('복용 상태를 선택해 주세요.'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byType(DropdownButtonFormField<String>),
      250,
      maxScrolls: 20,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('확인 못함').last);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tapIo(tester, find.text('복약 기록 저장'));
    await pending;
    expect(c.entries.single.fields['status'], 'unknown');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancelling duplicate log review keeps only the original intake',
    (tester) async {
      final med = (await tester.runAsync(
        () => c.medicationBook.saveMedication(
          c.selectedId!,
          name: '합성 약',
          instruction: '',
          times: [],
        ),
      ))!;
      await tester.runAsync(
        () => c.medicationBook.recordIntake(
          c.selectedId!,
          med.id,
          'taken',
          DateTime.now(),
        ),
      );
      final ctx = await home(tester);
      unawaited(recordIntake(ctx, c, med));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('복용함').last);
      await tester.pumpAndSettle();
      await tapIo(tester, find.text('복약 기록 저장'), settle: false);
      expect(find.text('같은 시각의 복약 기록이 있어요'), findsOneWidget);
      await tapIo(tester, find.text('취소'));
      expect(c.entries.length, 1);
      expect(find.text('복약 기록 저장'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recent food choices are local to the selected notebook and optional',
    (tester) async {
      await tester.runAsync(() async {
        final first = c.selectedId!;
        await c.records.saveEntry(
          first,
          kind: EntryKind.meal,
          occurredAt: DateTime.now(),
          fields: {'food': '합성 첫 수첩 음식'},
        );
        final other = await c.profiles.createPatient(alias: '다른 합성 수첩');
        await c.selectPatient(other.id);
        await c.records.saveEntry(
          other.id,
          kind: EntryKind.meal,
          occurredAt: DateTime.now(),
          fields: {'food': '합성 다른 수첩 음식'},
        );
      });
      final ctx = await home(tester);
      unawaited(editEntry(ctx, c, EntryKind.meal));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('합성 다른 수첩 음식'),
        250,
        maxScrolls: 20,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('합성 첫 수첩 음식'), findsNothing);
      await c.setUiPreferences(
        c.uiPreferences.withOption(UiOption.inputSuggestions, false),
      );
      await tester.pumpAndSettle();
      expect(find.text('합성 다른 수첩 음식'), findsNothing);
      await c.setUiPreferences(
        c.uiPreferences.withOption(UiOption.inputSuggestions, true),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('합성 다른 수첩 음식'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('entry-field-food')),
            )
            .controller!
            .text,
        '합성 다른 수첩 음식',
      );
      expect(c.entries.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets('hidden home sections remain available in the journal', (
    tester,
  ) async {
    await tester.runAsync(
      () => c.records.saveEntry(
        c.selectedId!,
        kind: EntryKind.generalNote,
        occurredAt: DateTime.now(),
        note: '합성 홈 표시 기록',
      ),
    );
    for (final option in [
      UiOption.recentRecords,
      UiOption.dailySummary,
      UiOption.chatShortcut,
    ]) {
      await c.setUiPreferences(c.uiPreferences.withOption(option, false));
    }
    await home(tester);
    await tester.drag(find.byType(ListView).first, const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(find.text('최근 기록'), findsNothing);
    expect(find.text('차곡차곡, 오늘의 기록'), findsNothing);
    expect(find.text('간병 도우미 대화'), findsNothing);
    await tester.tap(find.text('일기').last);
    await tester.pumpAndSettle();
    expect(find.text('합성 홈 표시 기록'), findsOneWidget);
    expect(c.entries.single.note, '합성 홈 표시 기록');
  });

  testWidgets('system accessibility remains active when app switches are off', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          boldText: true,
          highContrast: true,
          disableAnimations: true,
        );
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final ctx = await home(tester, scale: 2);
    expect(MediaQuery.boldTextOf(ctx), isTrue);
    expect(MediaQuery.highContrastOf(ctx), isTrue);
    expect(MediaQuery.disableAnimationsOf(ctx), isTrue);
    expect(MediaQuery.textScalerOf(ctx).scale(16), 32);
    expect(Theme.of(ctx).colorScheme.onSurface, Colors.black);
    expect(tester.takeException(), isNull);
  });
}
