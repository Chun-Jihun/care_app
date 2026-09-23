import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/drafts.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/app.dart';
import 'package:care_notebook/presentation/editors.dart';
import 'package:care_notebook/presentation/visit_record_picker.dart';
import 'package:care_notebook/presentation/ai_draft_page.dart';
import 'package:care_notebook/presentation/ai_settings.dart';
import 'package:care_notebook/presentation/password_field.dart';
import 'package:care_notebook/presentation/pending_photo_field.dart';
import 'package:care_notebook/presentation/task_list.dart';
import 'package:care_notebook/presentation/settings.dart';
import 'package:care_notebook/presentation/checkin_history_page.dart';

import 'support.dart';
import 'ai_settings_ui_test.dart' show ManagedAi;
import 'ai_service_test.dart' show FakeAi;

// User-visible regressions: saved selection must survive search; temporary
// photo/OCR edits and authentication settings must never silently change data.
class PhotoPlatform extends FakePlatform {
  PhotoPlatform(this.photo);
  final Uint8List photo;
  @override
  Future<Uint8List?> pickPhoto({bool camera = false}) async => photo;
}

void main() {
  late Directory root;
  late CareController c;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-ux-flows-');
    c = testController(VaultStore(root, MemorySecrets()), FakePlatform());
    await c.initialize();
    await c.startWithoutLock();
    await c.drafts.setRetention(DraftRetention.month);
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });
  Future<BuildContext> home(WidgetTester tester, {double scale = 1}) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(CareApp(controller: c));
    await tester.pumpAndSettle();
    return tester.element(find.byType(NavigationBar));
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 60,
    );
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  testWidgets(
    '120 visit sources keep Save reachable and hidden selections survive search',
    (tester) async {
      final pid = c.selectedId!;
      for (var i = 0; i < 120; i++) {
        testRepository(c).saveEntry(
          pid,
          kind: EntryKind.generalNote,
          occurredAt: DateTime(2026, 9, 1, 0, i),
          note: 'source-$i',
        );
      }
      final ctx = await home(tester, scale: 2);
      editVisit(ctx, c);
      await tester.pumpAndSettle();
      expect(find.text('저장').hitTestable(), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'visit');
      await reveal(tester, find.text('기록 선택 · 0개 선택됨'));
      await tester.tap(find.text('기록 선택 · 0개 선택됨'));
      await tester.pumpAndSettle();
      expect(find.byType(VisitRecordPicker), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'source-119');
      await tester.pumpAndSettle();
      await reveal(tester, find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(TextField),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byType(TextField), 'source-118');
      await tester.pumpAndSettle();
      expect(find.text('선택한 기록 1개 적용').hitTestable(), findsOneWidget);
      await reveal(tester, find.byType(CheckboxListTile));
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        false,
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('선택한 기록 2개 적용'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('저장'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(
        c.visitBook
            .visitEntries(pid, c.visits.single.id)
            .map((e) => e.note)
            .toSet(),
        {'source-119', 'source-118'},
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'large text leave dialog scrolls and password labels wrap distinctly',
    (tester) async {
      final ctx = await home(tester, scale: 2);
      editEntry(ctx, c, EntryKind.generalNote);
      await tester.pumpAndSettle();
      await reveal(tester, find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'unfinished');
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
        true,
      );
      expect(find.text('계속 작성').hitTestable(), findsOneWidget);
      await tester.tap(find.text('계속 작성'));
      await tester.pumpAndSettle();
      final one = TextEditingController(), two = TextEditingController();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: ListView(
                children: [
                  PasswordField(controller: one, label: '백업 비밀번호 (12자 이상)'),
                  PasswordField(controller: two, label: '백업 비밀번호 확인'),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('백업 비밀번호 (12자 이상)'), findsOneWidget);
      expect(find.text('백업 비밀번호 확인'), findsOneWidget);
      expect(tester.widget<Text>(find.text('백업 비밀번호 확인')).maxLines, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      one.dispose();
      two.dispose();
    },
  );

  testWidgets('caregiver history is separate from backup settings', (
    tester,
  ) async {
    for (var i = 0; i < 60; i++) {
      testRepository(c)
          .addCheckin(fatigue: 'fatigue-$i', sleep: '', stress: '');
    }
    final ctx = await home(tester);
    Navigator.of(ctx).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            Scaffold(body: ListView(children: settingsContent(context, c))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('fatigue-'), findsNothing);
    await reveal(tester, find.text('암호화 백업 저장'));
    expect(find.text('암호화 백업 저장').hitTestable(), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('돌보는 나의 상태'),
      -250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('돌보는 나의 상태'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckinHistoryPage), findsOneWidget);
    expect(find.textContaining('fatigue-'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('device authentication action is hidden when disabled', (
    tester,
  ) async {
    await tester.runAsync(() => c.setPin('123456'));
    c.lock();
    await tester.pumpWidget(CareApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('기기 인증으로 열기'), findsNothing);
    expect(find.text('수첩 열기'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'AI readiness links to management and refreshes after returning',
    (tester) async {
      final vault = testVault(c);
      c.dispose();
      final ai = ManagedAi()..installed = false;
      c = CareController(vault, FakePlatform(), aiRuntime: ai);
      await tester.runAsync(c.initialize);
      final ctx = await home(tester);
      Navigator.of(ctx).push(
        MaterialPageRoute<void>(builder: (_) => AiDraftPage(c, c.selectedId!)),
      );
      await tester.pumpAndSettle();
      expect(find.text('녹음 시작'), findsNothing);
      await tester.tap(find.text('AI·근거자료 관리'));
      await tester.pumpAndSettle();
      expect(find.byType(AiSettings), findsOneWidget);
      ai.installed = true;
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('녹음 시작').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('cancelled replacement retains the photo and creates no record', (
    tester,
  ) async {
    final ctx = await home(tester);
    final bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 12, height: 12)),
    );
    editEntry(ctx, c, EntryKind.meal, initialPhoto: bytes);
    await tester.pumpAndSettle();
    await tester.tap(find.text('다른 사진 선택'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('사진 선택'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PendingPhotoField>(find.byType(PendingPhotoField)).photo,
      same(bytes),
    );
    expect(c.entries, isEmpty);
    expect(find.text('저장').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'reminder labels reflect disabled, restored, past and done states',
    (tester) async {
      final pid = c.selectedId!;
      final task = await c.taskBook.saveTask(
        pid,
        title: 'task',
        dueAt: DateTime.now().add(const Duration(hours: 1)),
        reminder: true,
      );
      final ctx = await home(tester);
      expect(reminderState(ctx, c, pid, task), '알림 꺼짐 · 설정에서 켜 주세요.');
      await tester.runAsync(() => c.enableNotifications(true));
      testRepository(c).setSetting('imported_muted:$pid', 'true');
      expect(reminderState(ctx, c, pid, task), '복원한 수첩 · 알림 허용 필요');
      testRepository(c).setSetting('imported_muted:$pid', 'false');
      expect(reminderState(ctx, c, pid, task), contains('알림 요청됨'));
      await tester.runAsync(() => c.taskBook.completeTask(pid, task.id, true));
      expect(reminderState(ctx, c, pid, c.tasks.single), '완료한 할 일 · 알림 종료');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'prescription OCR is reviewed before medication and its photo save together',
    (tester) async {
      final photo = Uint8List.fromList(
        img.encodePng(img.Image(width: 12, height: 12)),
      );
      final vault = testVault(c);
      c.dispose();
      c = CareController(vault, PhotoPlatform(photo), aiRuntime: FakeAi());
      await tester.runAsync(c.initialize);
      final ctx = await home(tester);
      editMedication(ctx, c);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '시험약');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('사진 넣기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('사진 선택'));
      // Pump route microtasks and allow the real validation isolate to finish.
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        if (!c.busy &&
            tester
                    .widget<PendingPhotoField>(find.byType(PendingPhotoField))
                    .photo !=
                null) {
          break;
        }
      }
      expect(c.busy, false);
      await tester.pumpAndSettle();
      await reveal(tester, find.text('사진에서 글자 읽기'));
      await tester.tap(find.text('사진에서 글자 읽기'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('글자 읽기'));
      await tester.tap(find.text('글자 읽기'));
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const ValueKey('aiDraftText')));
      await tester.enterText(
        find.byKey(const ValueKey('aiDraftText')),
        '사용자가 확인한 지시 08:00',
      );
      await reveal(tester, find.text('확인한 내용을 입력란에 반영'));
      await tester.tap(find.text('확인한 내용을 입력란에 반영'));
      await tester.pumpAndSettle();
      expect(c.medications, isEmpty);
      expect(c.entries, isEmpty);
      await tester.runAsync(() async {
        await tester.tap(find.text('저장'));
        await Future<void>.delayed(const Duration(milliseconds: 700));
      });
      await tester.pumpAndSettle();
      expect(c.medications.single.name, '시험약');
      expect(c.medications.single.instruction, '사용자가 확인한 지시 08:00');
      expect(c.medications.single.times, isEmpty);
      expect(c.entries.single.note, '시험약');
      expect(
        c.records.attachments(c.selectedId!, c.entries.single.id),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
