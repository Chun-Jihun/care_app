import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/drafts.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/crypto.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/app.dart';
import 'package:care_notebook/presentation/backup_page.dart';
import 'package:care_notebook/presentation/editors.dart';
import 'package:care_notebook/presentation/draft_page.dart';

import 'support.dart';

class BackupPlatform extends FakePlatform {
  Uint8List? bytes;
  @override
  Future<void> saveBackup(Uint8List data) async {
    bytes = data;
  }

  @override
  Future<Uint8List?> pickBackup() async => bytes;
}

void main() {
  late Directory root;
  late CareController c;
  late MemorySecrets secrets;
  late BackupPlatform platform;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-draft-ui-');
    secrets = MemorySecrets();
    platform = BackupPlatform();
    c = testController(VaultStore(root, secrets), platform);
    await c.initialize();
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });
  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => c.setPin('123456'));
    testRepository(c).setDraftRetention(DraftRetention.month);
    await tester.pumpWidget(CareApp(controller: c));
    await tester.pumpAndSettle();
  }

  Future<void> tapIO(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    // Advance route/dialog microtasks as well as real native IO and isolates.
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      if (!c.busy &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    expect(c.busy, false);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'ARCH-04 malformed draft is isolated and raw text stays available',
    (tester) async {
      await start(tester);
      final pid = c.selectedId!;
      for (final id in ['valid-draft', 'invalid-draft']) {
        testRepository(c).saveDraft(
          id: id,
          patientId: pid,
          type: DraftType.entry,
          payload: EntryDraftPayload(
            kind: EntryKind.generalNote,
            note: 'recoverable note',
          ),
        );
      }
      const raw = '{"kind":"unknown_kind","note":"preserved raw text"}';
      withFixtureSql(
        root,
        secrets,
        (sql) => sql.execute('UPDATE record_draft SET payload=? WHERE id=?', [
          raw,
          'invalid-draft',
        ]),
      );
      unawaited(
        Navigator.of(tester.element(find.text('오늘의 돌봄')))
            .push(MaterialPageRoute<void>(builder: (_) => DraftPage(c))),
      );
      await tester.pumpAndSettle();
      expect(find.text('이 초안을 읽을 수 없어요'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('이 초안을 읽을 수 없어요'));
      await tester.pumpAndSettle();
      expect(find.text(raw), findsOneWidget);
      expect(testRepository(c).drafts(pid), hasLength(2));
      expect(testRepository(c).entries(pid), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'DRAFT-01/02 restarting the app offers the encrypted draft and saves it once',
    (tester) async {
      await start(tester);
      final pid = c.selectedId!;
      await tester.tap(find.text('기록하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('자유 메모'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '재시작 후 복구할 합성 메모');
      c.lock();
      await tester.pumpAndSettle();
      expect(find.text('재시작 후 복구할 합성 메모'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      c = testController(VaultStore(root, secrets), platform);
      await tester.runAsync(() async {
        await c.initialize();
        await c.unlockPin('123456');
      });
      await tester.pumpWidget(CareApp(controller: c));
      await tester.pumpAndSettle();
      expect(c.entries, isEmpty);
      expect(find.text('작성 중인 초안이 있어요'), findsOneWidget);
      await tester.tap(find.text('작성 중인 초안이 있어요'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('자유 메모'));
      await tester.pumpAndSettle();
      expect(find.text('재시작 후 복구할 합성 메모'), findsOneWidget);
      await tapIO(tester, find.text('저장'));
      expect(testRepository(c).entries(pid).single.note, '재시작 후 복구할 합성 메모');
      expect(testRepository(c).drafts(pid), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'DRAFT-01/03 intake restores the chosen state and original event time',
    (tester) async {
      await start(tester);
      final pid = c.selectedId!;
      final med = testRepository(c)
          .saveMedication(pid, name: '합성 약', instruction: '받은 지시', times: []);
      final context = tester.element(find.text('오늘의 돌봄'));
      unawaited(recordIntake(context, c, med));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('복용 거부').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '사용자가 적은 거부 이유');
      c.lock();
      await tester.pumpAndSettle();
      await tester.runAsync(() => c.unlockPin('123456'));
      await tester.pumpAndSettle();
      final savedAt = testRepository(c).drafts(pid).single.values['at'];
      expect(c.entries, isEmpty);
      await tester.tap(find.text('작성 중인 초안이 있어요'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('복약 기록').last);
      await tester.pumpAndSettle();
      expect(find.text('사용자가 적은 거부 이유'), findsOneWidget);
      expect(find.text('복용 거부'), findsOneWidget);
      await tapIO(tester, find.text('저장'));
      expect(c.entries.single.fields['status'], 'refused');
      expect(c.entries.single.occurredAt.millisecondsSinceEpoch, savedAt);
      expect(c.entries.single.fields['plan_id'], med.planId);
      expect(testRepository(c).drafts(pid), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('DRAFT-03 a visit draft can explicitly remove a deleted source', (
    tester,
  ) async {
    await start(tester);
    final pid = c.selectedId!;
    final entry = testRepository(c).saveEntry(
      pid,
      kind: EntryKind.generalNote,
      note: '나중에 삭제될 원본',
      occurredAt: DateTime.now(),
    );
    unawaited(editVisit(tester.element(find.text('오늘의 돌봄')), c));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '초안의 진료 제목');
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    c.lock();
    await tester.pumpAndSettle();
    await tester.runAsync(() => c.unlockPin('123456'));
    testRepository(c).deleteEntry(pid, entry.id);
    await tester.pumpAndSettle();
    await tester.tap(find.text('작성 중인 초안이 있어요'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('진료 준비').last);
    await tester.pumpAndSettle();
    await tapIO(tester, find.text('저장'));
    expect(c.visits, isEmpty);
    expect(find.text('현재 수첩의 항목을 찾을 수 없습니다.'), findsOneWidget);
    await tester.ensureVisible(find.text('삭제된 원본 연결 제외'));
    await tester.tap(find.text('삭제된 원본 연결 제외'));
    await tapIO(tester, find.text('저장'));
    expect(c.visits.single.title, '초안의 진료 제목');
    expect(testRepository(c).visitEntries(pid, c.visits.single.id), isEmpty);
    expect(testRepository(c).drafts(pid), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'BACKUP-01/03/UX-01 selection, password preview and additive restore are usable',
    (tester) async {
      await start(tester);
      final pid = c.selectedId!;
      testRepository(c).createPatient(alias: '제외할 수첩');
      testRepository(c).saveEntry(
        pid,
        kind: EntryKind.generalNote,
        note: '선택한 합성 기록',
        occurredAt: DateTime.now(),
      );
      await tester.runAsync(c.refresh); // Publish the directly seeded fixture.
      unawaited(backupFlow(tester.element(find.text('오늘의 돌봄')), c));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '제외할 수첩'),
            )
            .value,
        false,
      );
      final passwordField = find.widgetWithText(
        TextFormField,
        '백업 비밀번호 (12자 이상)',
      );
      final confirmationField = find.widgetWithText(
        TextFormField,
        '백업 비밀번호 확인',
      );
      await tester.scrollUntilVisible(
        passwordField,
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.enterText(passwordField, 'ui-backup-password');
      await tester.scrollUntilVisible(
        confirmationField,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.enterText(confirmationField, 'ui-backup-password');
      await tester.ensureVisible(find.text('백업 범위 확인'));
      await tester.tap(find.text('백업 범위 확인'));
      // The editor remains busy behind the confirmation dialog.
      await tester.pump(const Duration(milliseconds: 400));
      tester.view.physicalSize = const Size(320, 640);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('이 범위로 백업할까요?'), findsOneWidget);
      await tapIO(tester, find.text('암호화하고 저장 위치 선택'));
      expect(platform.bytes, isNotNull);
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(390, 844);
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.pumpAndSettle();
      final archive = jsonDecode(
        utf8.decode(
          await tester.runAsync(
                () => VaultCrypto.passwordOpen(
                  platform.bytes!,
                  'ui-backup-password',
                ),
              ) ??
              Uint8List(0),
        ),
      ) as Map;
      expect((archive['rows'] as Map)['patient_context'], hasLength(1));
      expect(
        testRepository(c).drafts(pid),
        isEmpty,
      ); // Passwords never become drafts.
      unawaited(restoreFlow(tester.element(find.text('오늘의 돌봄')), c));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'ui-backup-password',
      );
      await tapIO(tester, find.text('비밀번호 확인과 내용 보기'));
      expect(find.text('별도 수첩으로 추가할까요?'), findsOneWidget);
      expect(c.patients, hasLength(2));
      await tapIO(tester, find.text('수첩 추가 복원'));
      expect(c.patients, hasLength(3));
      expect(testRepository(c).entries(pid).single.note, '선택한 합성 기록');
      expect(c.selectedId, pid);
      expect(tester.takeException(), isNull);
    },
  );
}
