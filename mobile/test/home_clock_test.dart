import 'dart:async';
import 'dart:io';

import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/domain/notebook_context.dart';
import 'package:care_notebook/domain/ui_preferences.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'support.dart';

// A local date/check-time boundary refreshes visible facts without invalidating
// patient context, losing an editor or treating scheduled medication as taken.
void main() {
  setUpAll(() => initializeDateFormatting('ko'));
  late Directory root;
  late CareController c;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-home-clock-');
    c = testController(VaultStore(root, MemorySecrets()), FakePlatform());
    await c.initialize();
    await c.startWithoutLock();
    var prefs = c.uiPreferences;
    for (final section in HomeSection.values) {
      prefs = prefs.withOption(
        section.option,
        section == HomeSection.medications || section == HomeSection.totals,
      );
    }
    await c.setUiPreferences(prefs);
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('home rolls over at midnight without cancelling a context task', (
    tester,
  ) async {
    final base = DateTime(2026, 11, 5, 23, 59, 59);
    await tester.runAsync(
      () => c.records.saveEntry(
        c.selectedId!,
        kind: EntryKind.meal,
        occurredAt: base,
        fields: {'water_ml': '500'},
      ),
    );
    await c.setUiPreferences(
      c.uiPreferences.withOption(UiOption.medicationOverview, false),
    );
    final began = tester.binding.clock.now();
    await tester.pumpWidget(
      MaterialApp(
        home: CareShell(
          c,
          clock: () => base.add(tester.binding.clock.now().difference(began)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('500'), findsWidgets);
    final pending = Completer<String>();
    Object? error;
    final task = c.contextTasks.create(
      ContextSelection(patientId: c.selectedId!),
    );
    final result = task
        .run((_) => pending.future)
        .then<void>(
          (_) {},
          onError: (Object e) {
            error = e;
          },
        );
    await tester.pump(const Duration(seconds: 2));
    expect(error, isNull);
    expect(find.textContaining('500'), findsNothing);
    expect(c.records.entries(c.selectedId!).single.fields['water_ml'], '500');
    expect(tester.takeException(), isNull);
    pending.complete('合成');
    await tester.pump();
    await result;
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'home advances a passed medication check without creating an intake',
    (tester) async {
      final base = DateTime(2026, 11, 5, 8, 59, 59);
      await tester.runAsync(
        () => c.medicationBook.saveMedication(
          c.selectedId!,
          name: '합성 약',
          instruction: '',
          times: ['09:00', '18:00'],
        ),
      );
      final began = tester.binding.clock.now();
      await tester.pumpWidget(
        MaterialApp(
          home: CareShell(
            c,
            clock: () => base.add(tester.binding.clock.now().difference(began)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('09:00'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('18:00'), findsOneWidget);
      expect(find.textContaining('09:00'), findsNothing);
      expect(c.entries, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
