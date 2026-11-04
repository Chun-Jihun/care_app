import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/daily_widget.dart';
import 'package:care_notebook/domain/ui_preferences.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';

import 'support.dart';

class WidgetPlatform extends FakePlatform {
  final snapshots = <DailyWidgetSnapshot?>[];
  bool fail = false;
  @override
  Future<bool> dailyWidgetAvailable() async => true;
  @override
  Future<void> updateDailyWidget(DailyWidgetSnapshot? snapshot) async {
    if (fail) throw StateError('synthetic widget failure');
    snapshots.add(snapshot);
  }
}

// Failures defined before the native bridge: no implicit sharing; no patient
// mixing; opt-out clears cached details; widget failure must not lose a record;
// opening a widget never bypasses optional app authentication.
void main() {
  late Directory root;
  late WidgetPlatform platform;
  late CareController c;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-widget-');
    platform = WidgetPlatform();
    c = CareController(VaultStore(root, MemorySecrets()), platform);
    await c.initialize();
    await c.startWithoutLock();
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });

  test(
    'widget stays off by default and detailed titles require opt-in',
    () async {
      await c.medicationBook.saveMedication(
        c.selectedId!,
        name: '합성 약 이름',
        instruction: '이 문장은 위젯에 내보내지 않음',
        times: ['09:00'],
      );
      await c.refreshDailyWidget();
      expect(platform.snapshots.whereType<DailyWidgetSnapshot>(), isEmpty);
      await c.setUiPreferences(
        c.uiPreferences.withOption(UiOption.dailyWidget, true),
      );
      await c.refreshDailyWidget();
      final minimal = jsonEncode(platform.snapshots.last!.toJson());
      expect(minimal, isNot(contains('합성 약 이름')));
      expect(minimal, isNot(contains('이 문장은 위젯에 내보내지 않음')));
      await c.setUiPreferences(
        c.uiPreferences.withOption(UiOption.widgetDetails, true),
      );
      await c.refreshDailyWidget();
      expect(
        jsonEncode(platform.snapshots.last!.toJson()),
        contains('합성 약 이름'),
      );
      expect(
        jsonEncode(platform.snapshots.last!.toJson()),
        isNot(contains('이 문장은 위젯에 내보내지 않음')),
      );
      await c.setUiPreferences(
        c.uiPreferences.withOption(UiOption.dailyWidget, false),
      );
      expect(platform.snapshots.last, isNull);
    },
  );

  test('switching notebooks replaces the widget source without copying identifiers', () async {
    await c.medicationBook.saveMedication(
      c.selectedId!,
      name: '합성 첫 약',
      instruction: '',
      times: ['10:00'],
    );
    await c.setUiPreferences(
      c.uiPreferences
          .withOption(UiOption.dailyWidget, true)
          .withOption(UiOption.widgetDetails, true),
    );
    final second = await c.profiles.createPatient(alias: '표시하지 않을 별칭');
    await c.selectPatient(second.id);
    await c.medicationBook.saveMedication(
      second.id,
      name: '합성 둘째 약',
      instruction: '',
      times: ['11:00'],
    );
    await c.refreshDailyWidget();
    final result = jsonEncode(platform.snapshots.last!.toJson());
    expect(result, contains('합성 둘째 약'));
    expect(result, isNot(contains('합성 첫 약')));
    expect(result, isNot(contains(second.id)));
    expect(result, isNot(contains('표시하지 않을 별칭')));
  });

  test('locked display settings cannot enable widget data sharing', () async {
    await c.setPin('123456');
    c.lock();
    await expectLater(
      c.setUiPreferences(
        c.uiPreferences.withOption(UiOption.dailyWidget, true),
      ),
      throwsA(isA<Exception>()),
    );
    expect(c.unlocked, isFalse);
    expect(c.uiPreferences.enabled(UiOption.dailyWidget), isFalse);
  });

  test(
    'malformed stored order and quick buttons retain usable customization',
    () {
      final prefs = UiPreferences.decode(
        '{"homeOrder":["tasks","tasks","future"],"quickKinds":[]}',
      );
      expect(prefs.homeOrder.first, HomeSection.tasks);
      expect(prefs.homeOrder.toSet().length, HomeSection.values.length);
      expect(prefs.quickKinds, isEmpty);
      final moved = prefs.moveHomeSection(HomeSection.totals, -1);
      expect(UiPreferences.decode(moved.encode()).homeOrder, moved.homeOrder);
      expect(UiPreferences.defaults.enabled(UiOption.animations), isTrue);
      expect(
        UiPreferences.defaults
            .withOption(UiOption.animations, false)
            .reduceMotion,
        isTrue,
      );
    },
  );
  test(
    'display reset preserves sharing choice and data erase revokes it',
    () async {
      await c.setUiPreferences(
        c.uiPreferences
            .withOption(UiOption.dailyWidget, true)
            .withOption(UiOption.widgetDetails, true)
            .withOption(UiOption.largeText, true),
      );
      final reset = c.uiPreferences.resetDisplay();
      expect(reset.enabled(UiOption.dailyWidget), isTrue);
      expect(reset.enabled(UiOption.largeText), isFalse);
      await c.deleteAll();
      expect(platform.snapshots.last, isNull);
      expect(c.uiPreferences.enabled(UiOption.dailyWidget), isFalse);
      expect(c.uiPreferences.enabled(UiOption.widgetDetails), isFalse);
      expect(c.uiPreferences.enabled(UiOption.largeText), isTrue);
    },
  );
  test(
    'widget publication failure leaves the committed record available',
    () async {
      await c.setUiPreferences(
        c.uiPreferences.withOption(UiOption.dailyWidget, true),
      );
      platform.fail = true;
      await c.records.saveEntry(
        c.selectedId!,
        kind: EntryKind.generalNote,
        occurredAt: DateTime.now(),
        note: '합성 보존 메모',
      );
      await c.refreshDailyWidget();
      expect(c.widgetUpdateFailed, isTrue);
      expect(c.entries.single.note, '합성 보존 메모');
      platform.fail = false;
      await c.refreshDailyWidget();
      expect(c.widgetUpdateFailed, isFalse);
    },
  );
}
