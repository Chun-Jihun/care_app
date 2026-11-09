import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/domain/backup.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/app.dart';
import 'package:care_notebook/presentation/common.dart';
import 'package:care_notebook/presentation/backup_page.dart';
import 'package:care_notebook/presentation/details.dart';
import 'package:care_notebook/presentation/shell.dart';
import 'package:care_notebook/presentation/password_field.dart';

import 'support.dart';

class BrowsingBackupPlatform extends FakePlatform {
  final started = Completer<void>();
  final finish = Completer<void>();
  @override
  Future<void> saveBackup(Uint8List data) async {
    started.complete();
    await finish.future;
  }

  @override
  Future<Uint8List?> pickBackup() async {
    started.complete();
    await finish.future;
    return null;
  }
}

class PreparingRestoreSecrets extends MemorySecrets {
  bool holdNextGeneration = false;
  final prepared = Completer<void>();
  final proceed = Completer<void>();
  @override
  Future<void> write(String key, String value) async {
    if (holdNextGeneration && key.startsWith('vault.')) {
      holdNextGeneration = false;
      prepared.complete();
      await proceed.future;
    }
    await super.write(key, value);
  }
}

class CapturingBackupPlatform extends FakePlatform {
  Uint8List? archive;
  @override
  Future<void> saveBackup(Uint8List data) async => archive = data;
}

void main() {
  testWidgets(
    'large text journal search stays visible above the keyboard during backup',
    (tester) async {
      late Directory root;
      late CareController c;
      late BrowsingBackupPlatform platform;
      Future<Uint8List?>? work;
      try {
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('care-backup-search-');
          platform = BrowsingBackupPlatform();
          c = testController(VaultStore(root, MemorySecrets()), platform);
          await c.initialize();
          await c.startWithoutLock();
          work = c.chooseBackup();
          await platform.started.future;
        });
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(CareApp(controller: c));
        await tester.pump();
        await tester.tap(find.text('기록 보기'));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.text('일기').last);
        await tester.pump(const Duration(milliseconds: 400));
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pump();
        final search = find.byType(TextField);
        await tester.scrollUntilVisible(
          search,
          120,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.ensureVisible(search);
        await tester.pump();
        expect(search.hitTestable(), findsOneWidget);
        expect(tester.getBottomLeft(search).dy, lessThanOrEqualTo(360));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.runAsync(() async {
          platform.finish.complete();
          await work;
        });
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
  for (final replaceAll in [true, false]) {
    testWidgets(
      '${replaceAll ? 'replacement' : 'additive'} restore closes reading routes at commit and shows current data',
      (tester) async {
        late Directory root;
        late CareController c;
        late PreparingRestoreSecrets secrets;
        Future<void>? work;
        try {
          await tester.runAsync(() async {
            root = await Directory.systemTemp.createTemp('care-restore-read-');
            secrets = PreparingRestoreSecrets();
            final platform = CapturingBackupPlatform();
            c = testController(VaultStore(root, secrets), platform);
            await c.initialize();
            await c.startWithoutLock();
            await c.records.saveEntry(
              c.selectedId!,
              kind: EntryKind.generalNote,
              note: 'archived original',
              occurredAt: DateTime.now(),
            );
            const selectionPassword = 'synthetic-backup-password';
            if (!replaceAll) {
              await c.exportSelection(
                selectionPassword,
                BackupSelection(patientIds: {c.selectedId!}),
              );
            }
            await c.medicationBook.saveMedication(
              c.selectedId!,
              name: 'medicine after snapshot',
              instruction: 'later instruction',
              times: [],
            );
            secrets.holdNextGeneration = true;
            work = replaceAll
                ? c.restoreBackup(
                    await readLegacyFullBackup(),
                    legacyFullBackupPassword,
                  )
                : c.importSelection(platform.archive!, selectionPassword);
            await secrets.prepared.future.timeout(const Duration(seconds: 20));
          });
          await tester.pumpWidget(CareApp(controller: c));
          await tester.pump();
          await tester.tap(find.text('기록 보기'));
          await tester.pump(const Duration(milliseconds: 500));
          await tester.tap(find.text('약').last);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byTooltip('약 상세'));
          await tester.pump(const Duration(milliseconds: 500));
          expect(find.byType(MedicationDetails), findsOneWidget);
          // Finish the entire disk commit without a UI frame in between. Even a
          // fast commit must invalidate routes created against the old data.
          await tester.runAsync(() async {
            secrets.proceed.complete();
            await work;
          });
          await tester.pumpAndSettle();
          expect(find.byType(MedicationDetails), findsNothing);
          expect(
            c.entries.single.note,
            replaceAll ? legacyFullBackupNote : 'archived original',
          );
          expect(c.patients.length, replaceAll ? 1 : 2);
          expect(c.medications.length, replaceAll ? 0 : 1);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.runAsync(() async {
            if (!secrets.proceed.isCompleted) secrets.proceed.complete();
            await work;
          });
          await tester.pumpWidget(const SizedBox.shrink());
          c.dispose();
          await tester.runAsync(() => root.delete(recursive: true));
        }
      },
    );
  }
  testWidgets(
    'backup keeps medication and settings readable with write controls disabled',
    (tester) async {
      late Directory root;
      late CareController c;
      late BrowsingBackupPlatform platform;
      Future<Uint8List?>? work;
      try {
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp(
            'care-backup-read-controls-',
          );
          platform = BrowsingBackupPlatform();
          c = testController(VaultStore(root, MemorySecrets()), platform);
          await c.initialize();
          await c.startWithoutLock();
          await c.medicationBook.saveMedication(
            c.selectedId!,
            name: 'readable medicine',
            instruction: 'confirmed instruction',
            times: [],
          );
          work = c.chooseBackup();
          await platform.started.future;
        });
        await tester.pumpWidget(CareApp(controller: c));
        await tester.pump();
        await tester.tap(find.text('기록 보기'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('약').last);
        await tester.pump(const Duration(milliseconds: 300));
        final intake = find.widgetWithText(TextButton, '실제 복약 기록');
        await tester.ensureVisible(intake);
        await tester.pump();
        expect(tester.widget<TextButton>(intake).onPressed, isNull);
        expect(find.text('confirmed instruction'), findsOneWidget);
        await tester.tap(find.byTooltip('약 상세'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(MedicationDetails), findsOneWidget);
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '처방 지시 수정 기록'),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.byType(BackButton).hitTestable().last);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('진료').last);
        await tester.pump(const Duration(milliseconds: 300));
        final contact = find.widgetWithText(ListTile, '의료진의 설명과 다음 할 일');
        await tester.scrollUntilVisible(
          contact,
          200,
          scrollable: find.byType(Scrollable).last,
        );
        expect(tester.widget<ListTile>(contact).onTap, isNull);
        await tester.tap(find.text('설정').last);
        await tester.pump(const Duration(milliseconds: 300));
        final notifications = find.widgetWithText(
          SwitchListTile,
          '일정·복약 확인 알림',
        );
        await tester.scrollUntilVisible(
          notifications,
          200,
          scrollable: find.byType(Scrollable).last,
        );
        expect(tester.widget<SwitchListTile>(notifications).onChanged, isNull);
        final backup = find.widgetWithText(ListTile, '암호화 백업 저장');
        await tester.scrollUntilVisible(
          backup,
          200,
          scrollable: find.byType(Scrollable).last,
        );
        expect(tester.widget<ListTile>(backup).onTap, isNull);
      } finally {
        await tester.runAsync(() async {
          platform.finish.complete();
          await work;
        });
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
  testWidgets('finishing the backup form preserves the record route above it', (
    tester,
  ) async {
    late Directory root;
    late CareController c;
    late BrowsingBackupPlatform platform;
    Future<void>? flow;
    try {
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp(
          'care-backup-form-browse-',
        );
        platform = BrowsingBackupPlatform();
        c = testController(VaultStore(root, MemorySecrets()), platform);
        await c.initialize();
        await c.startWithoutLock();
        await c.records.saveEntry(
          c.selectedId!,
          kind: EntryKind.generalNote,
          note: 'background editor sentinel',
          occurredAt: DateTime.now(),
        );
      });
      await tester.pumpWidget(CareApp(controller: c));
      await tester.pumpAndSettle();
      flow = backupFlow(tester.element(find.byType(CareShell)), c);
      await tester.pumpAndSettle();
      for (final label in ['백업 비밀번호 (12자 이상)', '백업 비밀번호 확인']) {
        await tester.scrollUntilVisible(
          find.text(label),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        final field = find.descendant(
          of: find.widgetWithText(PasswordField, label),
          matching: find.byType(TextField),
        );
        await tester.ensureVisible(field);
        await tester.enterText(field, 'synthetic-backup-password');
      }
      await tester.ensureVisible(find.text('백업 범위 확인'));
      await tester.tap(find.text('백업 범위 확인'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('암호화하고 저장 위치 선택'));
      for (var i = 0; i < 300 && !platform.started.isCompleted; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
      expect(platform.started.isCompleted, isTrue);
      await tester.pump();
      await tester.tap(find.text('기록 보기'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('일기').last);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.byType(EntryTile).last);
      await tester.pump();
      await tester.tap(find.byType(EntryTile).last);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(EntryDetails), findsOneWidget);
      await tester.runAsync(() async {
        platform.finish.complete();
      });
      for (var i = 0; i < 20 && c.busy; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pumpAndSettle();
      expect(find.byType(EntryDetails), findsOneWidget);
      expect(find.byType(EditorPage, skipOffstage: false), findsNothing);
    } finally {
      if (!platform.finish.isCompleted) {
        await tester.runAsync(() async {
          platform.finish.complete();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      // A disposed Navigator need not complete a route that the buggy form
      // failed to pop. Never hang teardown while testing that failure.
      unawaited(flow ?? Future<void>.value());
      c.dispose();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });
  testWidgets(
    'backup permits journal navigation and reading, but no record mutation',
    (tester) async {
      late Directory root;
      late CareController c;
      late BrowsingBackupPlatform platform;
      Future<Uint8List?>? work;
      try {
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('care-backup-browse-');
          platform = BrowsingBackupPlatform();
          c = testController(VaultStore(root, MemorySecrets()), platform);
          await c.initialize();
          await c.startWithoutLock();
          await c.records.saveEntry(
            c.selectedId!,
            kind: EntryKind.generalNote,
            note: 'read while backup waits',
            occurredAt: DateTime.now(),
          );
          work = c.chooseBackup();
          await platform.started.future;
        });
        await tester.pumpWidget(CareApp(controller: c));
        await tester.pump();
        await tester.tap(find.text('기록 보기'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('일기').last);
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester
              .widgetList<FloatingActionButton>(
                find.byType(FloatingActionButton),
              )
              .every((button) => button.onPressed == null),
          isTrue,
        );
        expect(
          tester
              .widget<PopupMenuButton<String>>(
                find.byType(PopupMenuButton<String>).last,
              )
              .enabled,
          isFalse,
        );
        await tester.ensureVisible(find.byType(EntryTile).last);
        await tester.pump();
        await tester.tap(find.byType(EntryTile).last);
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.descendant(
            of: find.byType(EntryDetails),
            matching: find.text('read while backup waits'),
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == '기록 수정',
                ),
              )
              .onPressed,
          isNull,
        );
        final photoButton = find.widgetWithText(OutlinedButton, '사진 선택');
        expect(tester.widget<OutlinedButton>(photoButton).onPressed, isNull);
        await expectLater(
          c.records.deleteEntry(c.selectedId!, c.entries.single.id),
          throwsA(isA<CareError>()),
        );
        expect(c.entries, hasLength(1));
        await tester.runAsync(() async {
          platform.finish.complete();
          await work;
        });
        await tester.pump(const Duration(milliseconds: 400));
        // Finishing the background operation must not pop the record being read.
        expect(
          find.descendant(
            of: find.byType(EntryDetails),
            matching: find.text('read while backup waits'),
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == '기록 수정',
                ),
              )
              .onPressed,
          isNotNull,
        );
      } finally {
        if (!platform.finish.isCompleted) platform.finish.complete();
        await tester.runAsync(() async {
          await work;
        });
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
}
