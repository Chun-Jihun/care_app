import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/application/draft_session.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/domain/drafts.dart';
import 'package:care_notebook/domain/notebook_context.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/app.dart';

import 'support.dart';

void main() {
  late Directory root;
  late MemorySecrets secrets;
  late CareController c;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-optional-lock-');
    secrets = MemorySecrets();
    c = testController(VaultStore(root, secrets), FakePlatform());
    await c.initialize();
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });
  Future<void> restart() async {
    c.dispose();
    c = testController(VaultStore(root, secrets), FakePlatform());
    await c.initialize();
  }

  test(
    'LOCK-01 no-PIN onboarding and restart keep records encrypted',
    () async {
      expect(c.hasPin, isFalse);
      await c.startWithoutLock();
      final pid = c.selectedId!;
      const note = 'OPTIONAL_LOCK_ENCRYPTED_SENTINEL';
      await c.records.saveEntry(
        pid,
        kind: EntryKind.generalNote,
        note: note,
        occurredAt: DateTime.now(),
      );
      await restart();
      expect(c.unlocked, isTrue);
      expect(c.hasPin, isFalse);
      expect(c.selectedId, pid);
      expect(c.entries.single.note, note);
      expect(secrets.values.containsKey('auth.pin'), isFalse);
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        expect(latin1.decode(file.readAsBytesSync()), isNot(contains(note)));
      }
      await c.deleteAll();
      await restart();
      expect(c.unlocked, isFalse);
      expect(c.hasPin, isFalse);
      expect(secrets.values, isEmpty);
    },
  );

  test(
    'LOCK-02 existing PIN cannot be bypassed; disabling requires current PIN',
    () async {
      await c.setPin('123456');
      await c.enableDeviceAuth(true);
      // Legacy installs have a PIN but no onboarding marker.
      expect(secrets.values.containsKey('app.started'), isFalse);
      await restart();
      expect(c.hasPin, isTrue);
      expect(c.unlocked, isFalse);
      await expectLater(c.startWithoutLock(), throwsA(isA<CareError>()));
      await expectLater(c.disableAppLock('123456'), throwsA(isA<CareError>()));
      await c.unlockPin('123456');
      await expectLater(c.disableAppLock('000000'), throwsA(isA<CareError>()));
      expect(c.hasPin, isTrue);
      await c.disableAppLock('123456');
      expect(c.unlocked, isTrue);
      expect(c.hasPin, isFalse);
      expect(await c.deviceAuthEnabled, isFalse);
      await restart();
      expect(c.unlocked, isTrue);
      await c.setPin('654321');
      expect(await c.deviceAuthEnabled, isFalse);
      c.handleBackground();
      expect(c.unlocked, isFalse);
      await expectLater(c.unlockPin('123456'), throwsA(isA<CareError>()));
      await c.unlockPin('654321');
    },
  );

  test(
    'LOCK-03 failed changes never silently enable or remove the PIN',
    () async {
      await c.startWithoutLock();
      await expectLater(c.enableDeviceAuth(true), throwsA(isA<CareError>()));
      for (final key in ['auth.pin', 'auth.until']) {
        secrets.rejectKey = key;
        await expectLater(c.setPin('123456'), throwsA(anything));
        secrets.rejectKey = null;
        await restart();
        expect(c.hasPin, isFalse);
        expect(c.unlocked, isTrue);
      }
      await c.setPin('123456');
      secrets.rejectDeleteKey = 'auth.pin';
      await expectLater(c.disableAppLock('123456'), throwsA(anything));
      secrets.rejectDeleteKey = null;
      expect(c.hasPin, isTrue);
      await restart();
      expect(c.hasPin, isTrue);
      expect(c.unlocked, isFalse);
      await c.unlockPin('123456');
    },
  );

  test('LOCK-04 background without lock flushes drafts and ends temporary chat, keeping editor usable', () async {
    await c.startWithoutLock();
    final pid = c.selectedId!;
    await c.drafts.setRetention(DraftRetention.month);
    await c.setChatRetention(pid, ChatRetention.session);
    await c.addChatMessage(pid, 'temporary question');
    var text = '';
    final draft = DraftSession(
      c,
      patientId: pid,
      type: DraftType.entry,
      snapshot: () => DraftPayload.fromFields(DraftType.entry, {
        'kind': 'generalNote',
        'note': text,
        'at': 12345,
      }),
    );
    addTearDown(draft.dispose);
    text = 'before background';
    draft.changed();
    final session = c.captureSession();
    final pending = Completer<void>();
    final task = c.contextTasks.create(ContextSelection(patientId: pid));
    final completion = expectLater(
      task.run((_) => pending.future),
      throwsA(isA<CareError>()),
    );
    c.handleBackground();
    await completion;
    expect(task.cancelled, isTrue);
    pending.complete();
    expect(c.unlocked, isTrue);
    c.requireSession(session);
    expect(c.chatMessages(pid), isEmpty);
    expect(c.drafts.list(pid).single.values['note'], text);
    text = 'after returning';
    await draft.complete();
    expect(c.entries.single.note, text);
    expect(c.drafts.list(pid), isEmpty);
    await c.setChatRetention(pid, ChatRetention.week);
    await c.addChatMessage(pid, 'retained question');
    c.handleBackground();
    await restart();
    expect(c.chatMessages(pid).single.text, 'retained question');
  });

  test(
    'LOCK-05 locking during verification cancels pending lock removal',
    () async {
      await c.setPin('123456');
      final disabling = c.disableAppLock('123456');
      c.lock();
      await expectLater(disabling, throwsA(isA<CareError>()));
      await restart();
      expect(c.hasPin, isTrue);
      expect(c.unlocked, isFalse);
      await c.unlockPin('123456');
    },
  );

  Future<void> settleIO(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 350)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapWithIO(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(finder);
      for (var i = 0; i < 200 && c.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    expect(c.busy, isFalse);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'LOCK-06 onboarding has no PIN; settings support cancel, enable and verified disable',
    (tester) async {
      await tester.pumpWidget(CareApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tapWithIO(tester, find.text('내 수첩 시작하기'));
      expect(find.text('오늘의 돌봄'), findsOneWidget);
      expect(find.byTooltip('잠그기'), findsNothing);
      await tester.tap(find.byType(NavigationDestination).last);
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('appLockToggle'));
      await tester.scrollUntilVisible(
        toggle,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(find.text('지금 잠그기'), findsNothing);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(c.hasPin, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '123456');
      await tester.enterText(find.byType(TextField).at(1), '123456');
      await tapWithIO(tester, find.text('저장'));
      expect(c.hasPin, isTrue);
      expect(find.byTooltip('잠그기'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '000000');
      await tapWithIO(tester, find.text('잠금 끄기'));
      expect(c.hasPin, isTrue);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '123456');
      await tapWithIO(tester, find.text('잠금 끄기'));
      expect(c.hasPin, isFalse);
      expect(find.byTooltip('잠그기'), findsNothing);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(find.text('지금 잠그기'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'LOCK-07 background with lock off preserves the live form and still saves it',
    (tester) async {
      await tester.runAsync(() async {
        await c.startWithoutLock();
        await c.drafts.setRetention(DraftRetention.month);
      });
      await tester.pumpWidget(CareApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('기록하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('자유 메모'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '돌아와 이어서 작성');
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await settleIO(tester);
      expect(find.text('돌아와 이어서 작성'), findsOneWidget);
      expect(find.byType(LockScreen), findsNothing);
      await tester.tap(find.text('저장'));
      await settleIO(tester);
      expect(c.entries.single.note, '돌아와 이어서 작성');
      expect(tester.takeException(), isNull);
    },
  );
}
