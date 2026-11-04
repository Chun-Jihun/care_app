import 'dart:io';

import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/ui_preferences.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

// Safety scenarios: display changes never unlock a notebook or change records;
// failed writes retain the previous options; corrupt/older options remain usable.
// Observe the existing controller and restart seam, not raw database internals.
void main() {
  test(
    'display preferences survive restart without opening a locked notebook',
    () async {
      final root = await Directory.systemTemp.createTemp('care-ui-options-');
      final secrets = MemorySecrets();
      final first = CareController(VaultStore(root, secrets), FakePlatform());
      CareController? second;
      try {
        await first.initialize();
        await first.setUiPreferences(
          first.uiPreferences.withOption(UiOption.largeText, true),
        );
        await first.setUiPreferences(
          first.uiPreferences.withOption(UiOption.lowGraphics, true),
        );
        expect(first.unlocked, isFalse);
        first.dispose();
        second = CareController(VaultStore(root, secrets), FakePlatform());
        await second.initialize();
        expect(second.uiPreferences.enabled(UiOption.largeText), isTrue);
        expect(second.uiPreferences.reduceMotion, isTrue);
        expect(second.uiPreferences.photoPreviews, isFalse);
        expect(second.unlocked, isFalse);
      } finally {
        second?.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test('failed preference write preserves the displayed options', () async {
    final root = await Directory.systemTemp.createTemp('care-ui-failure-');
    final secrets = MemorySecrets()..rejectKey = 'app.ui_preferences';
    final c = CareController(VaultStore(root, secrets), FakePlatform());
    try {
      await c.initialize();
      await expectLater(
        c.setUiPreferences(
          c.uiPreferences.withOption(UiOption.highContrast, true),
        ),
        throwsA(isA<Exception>()),
      );
      expect(c.uiPreferences.enabled(UiOption.highContrast), isFalse);
      expect(c.busy, isFalse);
    } finally {
      c.dispose();
      await root.delete(recursive: true);
    }
  });

  test('corrupt and future preference values use safe defaults', () {
    expect(UiPreferences.decode('{broken').photoPreviews, isTrue);
    final options = UiPreferences.decode(
      '{"largeText":true,"highContrast":"false","future":true}',
    );
    expect(options.enabled(UiOption.largeText), isTrue);
    expect(options.enabled(UiOption.highContrast), isFalse);
    expect(options.enabled(UiOption.recentRecords), isTrue);
  });
}
