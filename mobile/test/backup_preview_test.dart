import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/domain/backup.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/l10n/app_strings.dart';
import 'package:care_notebook/presentation/backup_page.dart';

import 'support.dart';

void main() {
  testWidgets(
    'backup confirmation reports actual prescription history across additive restore',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('care-backup-counts-'),
      ))!;
      final c = testController(
        VaultStore(root, MemorySecrets()),
        FakePlatform(),
      );
      try {
        await tester.runAsync(() async {
          await c.initialize();
          await c.startWithoutLock();
          final pid = c.selectedId!;
          final med = await c.medicationBook.saveMedication(
            pid,
            name: 'synthetic medicine',
            instruction: 'first',
            times: [],
          );
          await c.medicationBook.saveMedication(
            pid,
            id: med.id,
            expectedVersion: 1,
            name: med.name,
            instruction: 'changed',
            times: [],
          );
        });
        final selection = BackupSelection(patientIds: {c.selectedId!});
        final preview = c.backups.preview(selection);
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ko'),
            supportedLocales: const [Locale('ko')],
            localizationsDelegates: const [
              AppStrings.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            home: Builder(
              builder: (context) =>
                  Scaffold(body: Text(backupCounts(context, preview.counts))),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('처방 이력 2개'), findsOneWidget);
        await tester.runAsync(() async {
          final data = await testVault(c)
              .backupSelection('synthetic-backup-password', selection);
          final restored = await c.inspectBackup(
            data,
            'synthetic-backup-password',
          );
          expect(restored.counts, preview.counts);
          await c.importSelection(data, 'synthetic-backup-password');
          final imported = c.patients.singleWhere((p) => p.id != c.selectedId);
          expect(
            c.backups
                .preview(BackupSelection(patientIds: {imported.id}))
                .counts,
            preview.counts,
          );
        });
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        c.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
}
