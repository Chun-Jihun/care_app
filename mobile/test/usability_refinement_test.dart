import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/app.dart';
import 'package:care_notebook/presentation/medication_safety_page.dart';

import 'support.dart';
import 'drug_safety_test.dart' show Catalog, a;

// Failure scenarios, before feature implementation:
// - Locking must remove product confirmations and prevent their delayed writes.
// - A long notebook must not put Save or Backup after the entire history.
// - Filtering visit sources must retain selections, including hidden selections.
// - Cancelling photo/OCR must not create or overwrite a record or medication.
// - Missing models must expose a usable installation/retry path before capture.
// - Large text must retain readable explanations, labels and reachable actions.
// - Disabled reminders/authentication must not appear available or scheduled.
void main() {
  testWidgets('locking removes the product confirmation and its contents', (
    tester,
  ) async {
    late Directory root;
    late CareController c;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('care-usability-');
      c = CareController(
        VaultStore(root, MemorySecrets()),
        FakePlatform(),
        drugCatalog: () async => Catalog(),
      );
      await c.initialize();
      await c.setPin('123456');
      await c.medicationBook.saveMedication(
        c.selectedId!,
        name: a.name,
        instruction: '',
        times: [],
      );
    });
    addTearDown(() async {
      c.dispose();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(CareApp(controller: c));
    await tester.pumpAndSettle();
    final ctx = tester.element(find.byType(NavigationBar));
    Navigator.of(ctx).push<void>(
      MaterialPageRoute(builder: (_) => MedicationSafetyPage(c, c.selectedId!)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(a.name));
    await tester.pumpAndSettle();
    await tester.tap(find.text('검색'));
    await tester.pumpAndSettle();
    final candidate = find.ancestor(
      of: find.text(a.name),
      matching: find.byType(ListTile),
    );
    await tester.ensureVisible(candidate);
    await tester.tap(candidate);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    c.lock();
    await tester.pumpAndSettle();
    expect(c.unlocked, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining(a.code), findsNothing);
    await tester.runAsync(() => c.unlockPin('123456'));
    await tester.pumpAndSettle();
    expect(c.medications.single.product, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
