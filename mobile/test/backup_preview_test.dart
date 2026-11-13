import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:care_notebook/domain/backup.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/l10n/app_strings.dart';
import 'package:care_notebook/presentation/backup_page.dart';

import 'support.dart';

void main() {
  test(
    'preview matches an encrypted backup across dates and options',
    () async {
      final root = await Directory.systemTemp.createTemp('care-backup-scope-');
      final vault = VaultStore(root, MemorySecrets());
      await vault.open();
      addTearDown(() async {
        vault.close();
        await root.delete(recursive: true);
      });
      final db = vault.repository;
      final pid = db.createPatient(alias: '첫 수첩').id;
      final second = db.createPatient().id;
      final other = db.createPatient().id;
      final from = DateTime.now().subtract(const Duration(days: 1));
      final until = from.add(const Duration(days: 2));
      final before = from.subtract(const Duration(milliseconds: 1));
      final photo = img.encodePng(img.Image(width: 2, height: 2));
      for (final (patient, at) in [
        (pid, before),
        (pid, from),
        (pid, until),
        (second, from),
        (other, from),
      ]) {
        final entry = db.saveEntry(
          patient,
          kind: EntryKind.generalNote,
          note: '기록',
          occurredAt: at,
        );
        await vault.addPhoto(patient, entry.id, photo);
        db.saveTask(patient, title: '일정', dueAt: at);
        if (patient != pid) {
          db.saveVisit(
            patient,
            title: '진료',
            questions: '',
            entryIds: [entry.id],
          );
        }
      }
      db.saveMedication(pid, name: '약', instruction: '복용 안내', times: []);
      db.saveMedication(other, name: '다른 약', instruction: '', times: []);
      db.setChatRetention(pid, ChatRetention.week);
      db.addChatMessage(
        pid,
        '만료된 대화',
        now: from.subtract(const Duration(days: 8)),
      );
      db.addChatMessage(pid, '기간 밖의 대화', now: before);
      db.addChatMessage(pid, '기간 안의 대화', now: from);
      db.setChatRetention(other, ChatRetention.forever);
      db.addChatMessage(other, '다른 수첩 대화', now: from);
      db.addChatMessage(pid, '종료 시각의 대화', now: until);
      db.addCheckin(fatigue: '', sleep: '', stress: '');

      expect(
        vault
            .previewSelection(BackupSelection(patientIds: {pid}, chats: true))
            .counts[BackupCategory.chats],
        3,
      );
      final expected = {
        BackupCategory.notebooks: 2,
        BackupCategory.records: 2,
        BackupCategory.medications: 1,
        BackupCategory.medicationPlans: 1,
        BackupCategory.tasks: 2,
        BackupCategory.visits: 1,
        BackupCategory.photos: 2,
        BackupCategory.chats: 1,
        BackupCategory.checkins: 1,
      };
      final selection = BackupSelection(
        patientIds: {pid, second},
        from: from,
        until: until,
        chats: true,
        checkins: true,
        identities: true,
      );
      expect(vault.previewSelection(selection).counts, expected);
      const password = 'synthetic-backup-password';
      final archive = await vault.backupSelection(password, selection);
      expect((await vault.inspectBackup(archive, password)).counts, expected);
      expect(
        vault
            .previewSelection(
              BackupSelection(
                patientIds: {pid, second},
                from: from,
                until: until,
                photos: false,
              ),
            )
            .counts,
        {
          ...expected,
          BackupCategory.photos: 0,
          BackupCategory.chats: 0,
          BackupCategory.checkins: 0,
        },
      );
      expect(
        () => vault.previewSelection(
          BackupSelection(patientIds: {pid, 'missing'}),
        ),
        throwsA(
          isA<CareError>().having(
            (error) => error.code,
            'code',
            CareErrorCode.selectedPatientMissing,
          ),
        ),
      );
    },
  );

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
