import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:care_notebook/application/visit_audio_buffer.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/application/visit_audio_device.dart';
import 'package:care_notebook/domain/ai.dart';
import 'package:care_notebook/domain/backup.dart';
import 'package:care_notebook/domain/drafts.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/domain/visit_recording.dart';
import 'package:care_notebook/infrastructure/crypto.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/l10n/app_strings.dart';
import 'package:care_notebook/presentation/visit_recording_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ai_service_test.dart' show FakeAi;
import 'ai_input_ui_support.dart';
import 'support.dart';

void main() {
  final first = '앞부분 ${'가' * 12000}';
  final second = '뒷부분 ${'나' * 9000}';
  final fullSegmentPrefix = '가' * 19991;
  const fullSegmentTail = '😀나나나나나나나';
  for (final (description, segments, notes, secondsApart) in [
    (
      'long visit transcripts can be reviewed and saved in order',
      [first, second],
      ['[00:00] $first', '[00:30] $second'],
      30,
    ),
    (
      'a full-size speech segment keeps its timestamp and whole emoji',
      ['$fullSegmentPrefix$fullSegmentTail'],
      ['[00:00] $fullSegmentPrefix', '[00:00] $fullSegmentTail'],
      0,
    ),
  ]) {
    testWidgets(description, (tester) async {
      late Directory root;
      late CareController c;
      final ai = _SegmentedSpeech(segments);
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('care-visit-transcript-');
        c = CareController(
          VaultStore(root, MemorySecrets()),
          FakePlatform(),
          aiRuntime: ai,
          visitAudio: _VisitMic.new,
        );
        await c.initialize();
        await c.startWithoutLock();
        await c.drafts.setRetention(DraftRetention.month);
        final pid = c.selectedId!;
        final recording = c.visitRecordings.begin(pid);
        final pcm = Uint8List(32000);
        for (var i = 0; i < (segments.length - 1) * 30 + 1; i++) {
          c.visitRecordings.append(pid, recording.id, pcm);
        }
      });
      final pid = c.selectedId!;
      Future<void> savePart(String label) async {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.widgetWithText(FilledButton, '저장'));
          for (var i = 0; i < 50 && c.busy; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
        await tester.pumpAndSettle();
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ko'),
            supportedLocales: const [Locale('ko')],
            localizationsDelegates: const [
              AppStrings.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            home: VisitRecordingPage(c, pid),
          ),
        );
        await tester.tap(find.text('전사하고 검토하기'));
        await tester.pumpAndSettle();
        expect(find.textContaining('원래 말한 내용과 대조'), findsOneWidget);
        expect(ai.opened, 0);
        await cancelAiInputNotice(tester);
        expect(ai.opened, 0);
        expect(c.visitRecordings.list(pid), hasLength(1));
        expect(c.drafts.list(pid), isEmpty);
        await tester.tap(find.text('전사하고 검토하기'));
        await acceptAiInputNotice(tester);
        await tester.pumpAndSettle();
        expect(find.text('전사문 검토'), findsOneWidget);
        expect(ai.opened, 1);
        expect(ai.closed, 1);
        expect(ai.next, segments.length);
        final drafts = c.drafts
            .list(pid)
            .map((draft) => draft.payload as EntryDraftPayload);
        expect(drafts.map((draft) => draft.note), unorderedEquals(notes));
        expect(c.records.entries(pid), isEmpty);
        await savePart('전사 구간 1/2');
        expect(c.records.entries(pid).single.note, notes.first);
        c.handleBackground();
        expect(
          (c.drafts.list(pid).single.payload as EntryDraftPayload).note,
          notes.last,
        );
        await savePart('전사 구간 2/2');
        final saved = c.records.entries(pid);
        expect(saved.map((entry) => entry.note), unorderedEquals(notes));
        expect(
          saved.first.occurredAt.difference(saved.last.occurredAt),
          Duration(seconds: secondsApart),
        );
        expect(c.drafts.list(pid), isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        c.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    });
  }

  testWidgets(
    'an unedited visit transcript is recoverable after backgrounding',
    (tester) async {
      late Directory root;
      late CareController c;
      late VisitRecording recording;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('care-visit-transcript-');
        c = CareController(
          VaultStore(root, MemorySecrets()),
          FakePlatform(),
          aiRuntime: FakeAi(),
          visitAudio: _VisitMic.new,
        );
        await c.initialize();
        await c.startWithoutLock();
        await c.drafts.setRetention(DraftRetention.month);
        final pid = c.selectedId!;
        recording = c.visitRecordings.begin(pid);
        c.visitRecordings.append(pid, recording.id, Uint8List(32000));
      });
      final pid = c.selectedId!;
      try {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ko'),
            supportedLocales: const [Locale('ko')],
            localizationsDelegates: const [
              AppStrings.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            home: VisitRecordingPage(c, pid),
          ),
        );
        await tester.tap(find.text('전사하고 검토하기'));
        await acceptAiInputNotice(tester);
        await tester.pumpAndSettle();
        expect(find.text('진료·연락 기록'), findsOneWidget);
        c.handleBackground();
        final payload = c.drafts.list(pid).single.payload as EntryDraftPayload;
        expect(payload.note, '[00:00] possibly wrong 15 mg');
        expect(
          payload.at?.millisecondsSinceEpoch,
          recording.startedAt.millisecondsSinceEpoch,
        );
        expect(c.records.entries(pid), isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        c.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );

  testWidgets('consent gates the mic and leaving the app retains a draft', (
    tester,
  ) async {
    late Directory root;
    late CareController c;
    final mic = _VisitMic();
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('care-visit-ui-');
      c = CareController(
        VaultStore(root, MemorySecrets()),
        FakePlatform(),
        visitAudio: () => mic,
      );
      await c.initialize();
      await c.startWithoutLock();
    });
    final pid = c.selectedId!;
    try {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ko'),
          supportedLocales: const [Locale('ko')],
          localizationsDelegates: const [
            AppStrings.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: VisitRecordingPage(c, pid),
        ),
      );
      await tester.tap(find.text('녹음 시작'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(mic.permissionRequests, 0);
      expect(c.visitRecordings.list(pid), isEmpty);

      await tester.tap(find.text('녹음 시작'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('동의를 확인하고 녹음'));
      await tester.pumpAndSettle();
      expect(mic.screenOn, isTrue);
      expect(find.text('녹음 마치기'), findsOneWidget);
      mic.pcm.add(Uint8List(32004));
      await tester.pump();
      expect(c.visitRecordings.list(pid).single.byteCount, 32000);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(c.visitRecordings.list(pid).single.byteCount, 32004);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(mic.screenOn, isFalse);
      expect(c.records.entries(pid), isEmpty);
      expect(find.text('녹음 초안 · 보관하거나 삭제해 주세요.'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      c.dispose();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });
  test('recording stops at 30 minutes without buffering the whole visit', () {
    var saved = 0;
    final block = Uint8List(32000);
    final audio = VisitAudioBuffer((pcm) {
      expect(pcm.length, lessThanOrEqualTo(32000));
      saved += pcm.length;
    });
    audio.add(Uint8List.fromList([1]));
    for (var i = 0; i < 1801; i++) {
      audio.add(block);
    }
    audio.finish();
    expect(audio.full, isTrue);
    expect(saved, 57600000);
    expect(saved, VisitRecording.maxBytes);
  });

  test('an interrupted recording reopens as a patient-scoped draft', () async {
    final root = await Directory.systemTemp.createTemp('care-visit-audio-');
    final secrets = MemorySecrets();
    final first = testController(VaultStore(root, secrets), FakePlatform());
    addTearDown(() => root.delete(recursive: true));
    await first.initialize();
    await first.setPin('123456');
    final pid = first.selectedId!;
    final draft = first.visitRecordings.begin(pid);
    final pcm = Uint8List.fromList([12, 34, 56, 78]);
    first.visitRecordings.append(pid, draft.id, pcm);
    first.dispose();

    final reopened = testController(VaultStore(root, secrets), FakePlatform());
    addTearDown(reopened.dispose);
    await reopened.initialize();
    await reopened.unlockPin('123456');
    final recording = reopened.visitRecordings.list(pid).single;
    expect(recording.id, draft.id);
    expect(recording.kept, isFalse);
    expect(reopened.visitRecordings.read(pid, recording.id, 0), pcm);
    expect(reopened.records.entries(pid), isEmpty);
  });

  test(
    'legacy preview and replacement preserve existing visit audio',
    () async {
      final root = await Directory.systemTemp.createTemp('care-visit-legacy-');
      final vault = VaultStore(root, MemorySecrets());
      final c = testController(vault, FakePlatform());
      addTearDown(() => root.delete(recursive: true));
      addTearDown(c.dispose);
      await c.initialize();
      await c.startWithoutLock();
      const password = legacyFullBackupPassword;
      final legacy = await readLegacyFullBackup();
      final pid = c.selectedId!;
      final recording = c.visitRecordings.begin(pid);
      final pcm = Uint8List.fromList([12, 34, 56, 78]);
      c.visitRecordings.append(pid, recording.id, pcm);

      final blocked = throwsA(
        isA<CareError>().having(
          (e) => e.code,
          'code',
          CareErrorCode.legacyRestoreVisitAudio,
        ),
      );
      await expectLater(c.inspectBackup(legacy, password), blocked);
      c.visitRecordings.keep(pid, recording.id);
      await expectLater(c.restoreBackup(legacy, password), blocked);
      expect(c.visitRecordings.read(pid, recording.id, 0), pcm);

      c.visitRecordings.delete(pid, recording.id);
      expect((await c.inspectBackup(legacy, password)).legacy, isTrue);
      await c.restoreBackup(legacy, password);
    },
  );

  test(
    'raw audio stays encrypted and outside backups and other notebooks',
    () async {
      final root = await Directory.systemTemp.createTemp('care-visit-audio-');
      final vault = VaultStore(root, MemorySecrets());
      final c = testController(vault, FakePlatform());
      addTearDown(() => root.delete(recursive: true));
      addTearDown(c.dispose);
      await c.initialize();
      await c.setPin('123456');
      final pid = c.selectedId!;
      final draft = c.visitRecordings.begin(pid);
      const marker = 'SYNTHETIC_VISIT_AUDIO_BOUNDARY_MARKER!';
      final pcm = Uint8List.fromList(utf8.encode(marker * 100));
      c.visitRecordings.append(pid, draft.id, pcm);
      c.visitRecordings.keep(pid, draft.id);
      expect(c.visitRecordings.list(pid).single.kept, isTrue);
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        expect(latin1.decode(file.readAsBytesSync()), isNot(contains(marker)));
      }

      const password = 'synthetic-visit-backup-password';
      final bytes = await vault.backupSelection(
        password,
        BackupSelection(patientIds: {pid}),
      );
      final document = utf8.decode(
        await VaultCrypto.passwordOpen(bytes, password),
      );
      expect(document, isNot(contains('visit_audio_chunk')));
      expect(document, isNot(contains(draft.id)));
      await c.importSelection(bytes, password);
      final other = c.patients.singleWhere((patient) => patient.id != pid).id;
      await c.selectPatient(other);
      expect(c.visitRecordings.list(other), isEmpty);
      expect(
        () => c.visitRecordings.read(other, draft.id, 0),
        throwsA(isA<CareError>()),
      );
      expect(
        () => c.visitRecordings.read(pid, draft.id, 0),
        throwsA(isA<CareError>()),
      );
      await c.selectPatient(pid);
      c.visitRecordings.delete(pid, draft.id);
      expect(
        () => c.visitRecordings.read(pid, draft.id, 0),
        throwsA(isA<CareError>()),
      );
      final next = c.visitRecordings.begin(pid);
      c.visitRecordings.append(pid, next.id, pcm);
      testRepository(c).deletePatient(pid);
      expect(
        () => c.visitRecordings.read(pid, next.id, 0),
        throwsA(isA<CareError>()),
      );
      await c.selectPatient(other);
      final remaining = c.visitRecordings.begin(other);
      c.visitRecordings.append(other, remaining.id, pcm);
      await c.deleteAll();
      await c.startWithoutLock();
      expect(c.visitRecordings.list(c.selectedId!), isEmpty);
      expect(
        () => c.visitRecordings.read(other, remaining.id, 0),
        throwsA(isA<CareError>()),
      );
    },
  );
}

class _SegmentedSpeech extends FakeAi {
  _SegmentedSpeech(this.segments);
  final List<String> segments;
  var next = 0;
  var opened = 0, closed = 0;

  @override
  Future<T> withTranscriber<T>(
    String language,
    Future<T> Function(SpeechTranscriber) use,
  ) async {
    opened++;
    try {
      return await super.withTranscriber(language, use);
    } finally {
      closed++;
    }
  }

  @override
  Future<String> transcribe(Float32List samples, String language) async =>
      segments[next++];
}

class _VisitMic implements VisitAudioDevice {
  final pcm = StreamController<Uint8List>.broadcast();
  var permissionRequests = 0;
  var screenOn = false;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<Stream<Uint8List>> start(void Function() interrupted) async =>
      pcm.stream;
  @override
  Future<void> stop() async {}
  @override
  Future<void> keepScreenOn(bool enabled) async => screenOn = enabled;
  @override
  Future<void> startPlayback() async {}
  @override
  Future<int> writePlayback(Uint8List bytes, int offset) async =>
      bytes.length - offset;
  @override
  Future<bool> playbackDrained() async => true;
  @override
  Future<void> stopPlayback() async {}
  @override
  Future<void> dispose() async => pcm.close();
}
