import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/domain/drafts.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/l10n/app_strings.dart';
import 'package:care_notebook/l10n/catalogs.g.dart';
import 'package:care_notebook/presentation/app.dart';
import 'package:care_notebook/presentation/backup_page.dart';
import 'package:care_notebook/presentation/common.dart';
import 'package:care_notebook/presentation/editors.dart';

import 'support.dart';

void main() {
  test('L10N-01 catalogs cover metadata and preserve every placeholder', () {
    final source = translationCatalogs['ko']!;
    final pattern = RegExp(r'\{\d+\}');
    for (final language in AppLanguage.values) {
      final catalog = translationCatalogs[language.code]!;
      expect(catalog.keys.toSet(), source.keys.toSet());
      expect(
        jsonDecode(
          File('lib/l10n/catalogs/${language.code}.json').readAsStringSync(),
        ),
        catalog,
      );
      for (final key in source.keys) {
        expect(catalog[key], isNotEmpty);
        expect(
          pattern.allMatches(catalog[key]!).map((m) => m[0]).toSet(),
          pattern.allMatches(key).map((m) => m[0]).toSet(),
          reason: '${language.code}: $key',
        );
        if (language != AppLanguage.korean) {
          expect(
            RegExp(r'[가-힣]').hasMatch(catalog[key]!),
            isFalse,
            reason: key,
          );
        }
      }
      for (final label in [
        ...EntryKind.values.map((v) => v.label),
        ...ChatRetention.values.map((v) => v.label),
        ...DraftRetention.values.map((v) => v.label),
        ...DraftType.values.map((v) => v.label),
        for (final kind in EntryKind.values)
          for (final field in kind.fields) ...[
            field.label,
            ...field.choices.values,
          ],
      ]) {
        expect(catalog.containsKey(label), isTrue, reason: label);
      }
    }
  });

  test('L10N-02 input matching UI copy and braces remain verbatim', () {
    const person = Patient('p', '돌봄 대상', 'family', '', '');
    final entry = CareEntry(
      id: 'e',
      patientId: 'p',
      kind: EntryKind.meal,
      occurredAt: DateTime(2026),
      offsetMinutes: 0,
      note: '저장 {0} 日本語 简体 繁體',
      fields: const {'food': '전부', 'amount': 'all'},
      version: 1,
    );
    for (final language in AppLanguage.values) {
      final s = AppStrings(language);
      expect(s.patient(person), '돌봄 대상');
      expect(s.summary(entry), contains('전부'));
      expect(s.summary(entry), contains(s.text('전부')));
      expect(s.summary(entry), contains(entry.note));
      expect(s.text('{0} {1}개', ['{1}', 5]), contains('{1}'));
      expect(
        s.error(StateError('sensitive diagnostic')),
        isNot(contains('sensitive')),
      );
      expect(
        s.error(CareError(CareErrorCode.requiredField, labels: ['단위'])),
        contains(s.text('단위')),
      );
    }
    expect(
      AppLanguage.fromLocale(const Locale('zh', 'TW')),
      AppLanguage.traditionalChinese,
    );
    expect(
      AppLanguage.fromLocale(const Locale('zh', 'HK')),
      AppLanguage.traditionalChinese,
    );
    expect(
      AppLanguage.fromLocale(
        const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hans',
          countryCode: 'TW',
        ),
      ),
      AppLanguage.simplifiedChinese,
    );
    expect(AppLanguage.fromCode('unsupported'), AppLanguage.korean);
  });

  late Directory root;
  late MemorySecrets secrets;
  late CareController c;
  late FakePlatform platform;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-l10n-');
    secrets = MemorySecrets();
    platform = FakePlatform();
    c = testController(VaultStore(root, secrets), platform);
    await c.initialize();
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });

  test(
    'L10N-03 preference persists before unlock and failed writes do not apply',
    () async {
      await c.setLanguage(AppLanguage.traditionalChinese);
      expect(c.unlocked, isFalse);
      expect(c.hasPin, isFalse);
      secrets.rejectKey = 'app.language';
      await expectLater(
        c.setLanguage(AppLanguage.english),
        throwsA(isA<CareError>()),
      );
      expect(c.language, AppLanguage.traditionalChinese);
      expect(platform.strings.language, AppLanguage.traditionalChinese);
      c.dispose();
      c = testController(VaultStore(root, secrets), FakePlatform());
      await c.initialize();
      expect(c.language, AppLanguage.traditionalChinese);
      expect(c.unlocked, isFalse);
    },
  );

  test('L10N-04 language changes preserve encrypted records, plans, drafts and authentication', () async {
    await c.setPin('123456');
    testRepository(c).setDraftRetention(DraftRetention.month);
    final pid = c.selectedId!;
    final record = testRepository(c).saveEntry(
      pid,
      kind: EntryKind.meal,
      occurredAt: DateTime.now(),
      fields: {'food': '食사 简体 繁體', 'amount': 'all'},
      note: '저장',
    );
    await c.enableNotifications(true);
    testRepository(c).saveTask(
      pid,
      title: 'private task',
      note: 'private note',
      dueAt: DateTime.now().add(const Duration(hours: 1)),
      reminder: true,
    );
    await c.refresh();
    final reminders = platform.reminders
        .map((r) => '${r.id}:${r.at.millisecondsSinceEpoch}')
        .toList();
    final auth = Map.of(secrets.values)..remove('app.language');
    final recordsBefore = jsonEncode(c.entries.map((e) => e.toJson()).toList());
    for (final language in AppLanguage.values) {
      await c.setLanguage(language);
      expect(c.unlocked, isTrue);
      expect(c.selectedId, pid);
      expect(testRepository(c).draftRetention, DraftRetention.month);
      expect(
        jsonEncode(c.entries.map((e) => e.toJson()).toList()),
        recordsBefore,
      );
      expect(Map.of(secrets.values)..remove('app.language'), auth);
      expect(
        platform.reminders
            .map((r) => '${r.id}:${r.at.millisecondsSinceEpoch}')
            .toList(),
        reminders,
      );
      expect(
        testRepository(c)
            .entries(
              pid,
              query: c.strings.text('전부'),
              displayText: c.strings.summary,
            )
            .single
            .id,
        record.id,
      );
    }
    c.lock();
    await c.setLanguage(AppLanguage.english);
    expect(c.unlocked, isFalse);
    await c.unlockPin('123456');
    expect(c.entries.single.note, '저장');
  });

  Future<void> smallScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(CareApp(controller: c));
    await tester.pumpAndSettle();
  }

  testWidgets('L10N-05 language picker works before PIN setup in all locales', (
    tester,
  ) async {
    await smallScreen(tester);
    for (final language in AppLanguage.values) {
      await tester.ensureVisible(find.byKey(const ValueKey('languagePicker')));
      await tester.tap(find.byKey(const ValueKey('languagePicker')));
      await tester.pumpAndSettle();
      final option = find.byKey(ValueKey('language-${language.code}'));
      await tester.ensureVisible(option);
      await tester.runAsync(() => tester.tap(option));
      await tester.pumpAndSettle();
      expect(c.language, language);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
        language.locale,
      );
      expect(find.byType(LockScreen), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('L10N-07 English record forms keep long choices usable', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await c.setPin('123456');
      testRepository(c).setDraftRetention(DraftRetention.month);
      await c.setLanguage(AppLanguage.english);
    });
    await smallScreen(tester);
    for (final kind in [
      EntryKind.meal,
      EntryKind.medicationIntake,
      EntryKind.activity,
      EntryKind.dailyLiving,
    ]) {
      final context = tester.element(find.byType(NavigationBar));
      editEntry(context, c, kind);
      await tester.pumpAndSettle();
      final selected = find.byType(DropdownButtonFormField<String>);
      await tester.scrollUntilVisible(
        selected,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(tester.element(selected), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(selected);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: kind.name);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }
  });

  for (final language in AppLanguage.values) {
    testWidgets(
      'L10N-06 ${language.code} navigation, chat, backup and open draft at large text',
      (tester) async {
        await tester.runAsync(() async {
          await c.setPin('123456');
          testRepository(c).setDraftRetention(DraftRetention.month);
          await c.setLanguage(language);
        });
        await smallScreen(tester);
        for (var i = 1; i < 5; i++) {
          await tester.tap(find.byType(NavigationDestination).at(i));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'tab $i');
        }
        await tester.tap(find.byTooltip(c.strings.text('간병 도우미 대화')));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => c.setChatRetention(c.selectedId!, ChatRetention.forever),
        );
        await tester.pumpAndSettle();
        expect(find.text(c.strings.text('직접 삭제할 때까지')), findsWidgets);
        expect(tester.takeException(), isNull, reason: 'chat');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        // Backups remain reviewable in every locale, including their count labels.
        final context = tester.element(find.byType(NavigationBar));
        backupFlow(context, c);
        await tester.pumpAndSettle();
        expect(find.text(c.strings.text('암호화 백업 저장')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'backup');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.tap(find.byType(NavigationDestination).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text(c.strings.text('기록하기')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(c.strings.text('자유 메모')));
        await tester.tap(find.text(c.strings.text('자유 메모')));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byType(TextField),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(
          find.byType(TextField).first,
          '저장 {0} 日本語 简体 繁體',
        );
        await tester.pump(const Duration(milliseconds: 500));
        final draftBefore = jsonEncode(
          testRepository(c).drafts(c.selectedId!).single.values,
        );
        await tester.runAsync(() => c.setLanguage(AppLanguage.english));
        await tester.pumpAndSettle();
        expect(find.byType(EditorPage), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byType(TextField),
          150,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text('저장 {0} 日本語 简体 繁體'), findsOneWidget);
        expect(
          jsonEncode(testRepository(c).drafts(c.selectedId!).single.values),
          draftBefore,
        );
        await tester.scrollUntilVisible(
          find.text('Save'),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Save'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'open editor');
        c.lock();
        await tester.pumpAndSettle();
        expect(find.text('저장 {0} 日本語 简体 繁體'), findsNothing);
        expect(find.byType(LockScreen), findsOneWidget);
      },
    );
  }
}
