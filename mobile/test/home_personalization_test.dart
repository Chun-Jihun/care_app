import 'dart:io';

import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/domain/ui_preferences.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/app.dart';
import 'package:care_notebook/presentation/entrance_transition.dart';
import 'package:care_notebook/presentation/home_customization_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

// Hiding or rearranging home features must preserve records and other entry
// points. Large text must leave the controls usable. Tab animations may never
// retain another notebook's screen or override a request to reduce motion.
void main() {
  late Directory root;
  late CareController c;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-home-');
    c = testController(VaultStore(root, MemorySecrets()), FakePlatform());
    await c.initialize();
    await c.startWithoutLock();
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });

  Future<void> home(WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(CareApp(controller: c));
    await tester.pumpAndSettle();
  }

  Future<void> tapIo(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
  }

  testWidgets(
    'home editor supports large text, visibility, order and quick buttons',
    (tester) async {
      await tester.runAsync(() => c.setPin('123456'));
      await home(tester);
      await tester.tap(find.byTooltip('홈 화면 편집'));
      await tester.pumpAndSettle();
      final semantics = tester.ensureSemantics();
      try {
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        final quickCard = find.byKey(const ValueKey('home-quickRecords'));
        await tapIo(
          tester,
          find.descendant(of: quickCard, matching: find.byType(SwitchListTile)),
        );
        expect(c.uiPreferences.enabled(UiOption.quickRecords), isFalse);
        await tester.scrollUntilVisible(
          find.text('할 일 위로'),
          250,
          maxScrolls: 20,
          scrollable: find.byType(Scrollable).first,
        );
        await tapIo(tester, find.text('할 일 위로'));
        expect(c.uiPreferences.homeOrder.first, HomeSection.tasks);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('quick-generalNote')),
          400,
          maxScrolls: 60,
          scrollable: find.byType(Scrollable).first,
        );
        await tapIo(tester, find.byKey(const ValueKey('quick-generalNote')));
        expect(c.uiPreferences.quickKinds, contains(EntryKind.generalNote));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.byType(HomeCustomizationPage), findsNothing);
        expect(find.widgetWithText(OutlinedButton, '식사'), findsNothing);
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'an empty personalized home remains recoverable and retains the journal',
    (tester) async {
      await tester.runAsync(() async {
        await c.records.saveEntry(
          c.selectedId!,
          kind: EntryKind.generalNote,
          occurredAt: DateTime.now(),
          note: '합성 유지 기록',
        );
        var preferences = c.uiPreferences;
        for (final section in HomeSection.values) {
          preferences = preferences.withOption(section.option, false);
        }
        await c.setUiPreferences(preferences);
      });
      await home(tester);
      expect(find.text('홈 표시 항목이 없어요'), findsOneWidget);
      expect(find.text('기록하기'), findsOneWidget);
      await tester.tap(find.text('일기').last);
      await tester.pumpAndSettle();
      expect(find.text('합성 유지 기록'), findsOneWidget);
      expect(c.entries.single.note, '합성 유지 기록');
      await tester.tap(find.text('오늘').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('홈 화면 편집'));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('home-quickRecords'));
      await tapIo(
        tester,
        find.descendant(of: card, matching: find.byType(SwitchListTile)),
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(c.uiPreferences.enabled(UiOption.quickRecords), isTrue);
      expect(find.text('홈 표시 항목이 없어요'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tab entrance keeps only the current child and stops for reduced motion',
    (tester) async {
      Future<void> screen(int tab, String notebook, {bool enabled = true}) =>
          tester.pumpWidget(
            MaterialApp(
              home: EntranceTransition(
                revision: tab,
                identity: notebook,
                enabled: enabled,
                child: Text('$notebook-$tab'),
              ),
            ),
          );
      double opacity() => tester
          .widget<FadeTransition>(
            find.descendant(
              of: find.byType(EntranceTransition),
              matching: find.byType(FadeTransition),
            ),
          )
          .opacity
          .value;
      await screen(0, 'first');
      expect(opacity(), 1);
      await screen(1, 'first');
      expect(find.text('first-0'), findsNothing);
      expect(opacity(), .82);
      await tester.pump(const Duration(milliseconds: 70));
      expect(opacity(), greaterThan(.82));
      expect(opacity(), lessThan(1));
      await screen(2, 'second');
      expect(find.text('first-1'), findsNothing);
      expect(opacity(), 1);
      await screen(3, 'second');
      await screen(4, 'second', enabled: false);
      expect(opacity(), 1);
      await tester.pump(const Duration(milliseconds: 200));
      expect(opacity(), 1);
      expect(tester.takeException(), isNull);
    },
  );
}
