import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/backup.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/app.dart';

import 'support.dart';

class WaitingBackupPlatform extends FakePlatform {
  final saving = Completer<void>();
  final finish = Completer<void>();
  final dialed = <String>[];
  @override
  Future<void> saveBackup(Uint8List data) async {
    saving.complete();
    await finish.future;
  }

  @override
  Future<Uint8List?> pickBackup() async {
    saving.complete();
    await finish.future;
    return null;
  }

  @override
  Future<void> dial(String number) async => dialed.add(number);
}

void main() {
  test(
    'encrypted export keeps its snapshot serialized until the picker returns',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'care-backup-export-response-',
      );
      final platform = WaitingBackupPlatform();
      final c = testController(VaultStore(root, MemorySecrets()), platform);
      Future<void>? backup;
      try {
        await c.initialize();
        await c.startWithoutLock();
        await c.profiles.updatePatient(
          c.selectedId!,
          alias: '',
          role: 'family',
          context: '',
          contact: '02-000-0000',
        );
        backup = c.exportSelection(
          'synthetic-backup-password',
          BackupSelection(patientIds: {c.selectedId!}),
        );
        await platform.saving.future.timeout(const Duration(seconds: 20));
        expect(c.backingUp, isTrue);
        expect(c.backupContact, '02-000-0000');
        await c.openDialer(c.backupContact);
        expect(platform.dialed, ['02-000-0000']);
        expect(c.externalOperation, isTrue);
        await expectLater(
          c.selectPatient(c.selectedId!),
          throwsA(isA<CareError>()),
        );
      } finally {
        platform.finish.complete();
        await backup;
        expect(c.busy, isFalse);
        expect(c.backingUp, isFalse);
        expect(c.backupContact, isEmpty);
        expect(c.externalOperation, isFalse);
        c.dispose();
        await root.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'pending backup keeps contact reachable, writes serialized and lock private',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('care-backup-response-'),
      ))!;
      late WaitingBackupPlatform platform;
      late CareController c;
      Future<void>? backup;
      try {
        await tester.runAsync(() async {
          platform = WaitingBackupPlatform();
          c = testController(VaultStore(root, MemorySecrets()), platform);
          await c.initialize();
          await c.startWithoutLock();
          await c.profiles.updatePatient(
            c.selectedId!,
            alias: '',
            role: 'family',
            context: '',
            contact: '02-000-0000',
          );
          await c.records.saveEntry(
            c.selectedId!,
            kind: EntryKind.generalNote,
            note: 'synthetic read-only snapshot',
            occurredAt: DateTime.now(),
          );
          backup = c.chooseBackup().then((_) {});
          await Future.any([
            platform.saving.future,
            backup!.then((_) => throw StateError('backup ended before picker')),
          ]).timeout(const Duration(seconds: 20));
        });
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(CareApp(controller: c));
        await tester.pump();
        expect(c.busy, isTrue);
        expect(c.entries.single.note, 'synthetic read-only snapshot');
        await expectLater(
          c.records.saveEntry(
            c.selectedId!,
            kind: EntryKind.generalNote,
            note: 'must not commit',
            occurredAt: DateTime.now(),
          ),
          throwsA(isA<CareError>()),
        );
        final contacts = find.byKey(const ValueKey('backup-contacts'));
        final healthcare = find.descendant(
          of: contacts,
          matching: find.text('저장한 의료기관'),
        );
        await tester.ensureVisible(healthcare);
        await tester.pump();
        expect(tester.getBottomLeft(healthcare).dy, lessThanOrEqualTo(360));
        await tester.tap(healthcare);
        await tester.pump();
        final call = find.descendant(
          of: contacts,
          matching: find.text('위급할 때 119 (대한민국)'),
        );
        await tester.ensureVisible(call);
        await tester.pump();
        expect(tester.getBottomLeft(call).dy, lessThanOrEqualTo(360));
        expect(call.hitTestable(), findsOneWidget);
        await tester.tap(call);
        await tester.pump();
        expect(platform.dialed, ['02-000-0000', '119']);
        // Completing one external action must not hide the still-open file picker.
        expect(c.externalOperation, isTrue);
        expect(c.busy, isTrue);
        expect(c.entries, hasLength(1));
        c.lock();
        await tester.pump();
        expect(contacts, findsNothing);
        expect(c.unlocked, isFalse);
      } finally {
        if (backup != null) {
          await tester.runAsync(() async {
            platform.finish.complete();
            if (c.unlocked) {
              await backup!;
            } else {
              await expectLater(backup, throwsA(isA<CareError>()));
            }
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
}
