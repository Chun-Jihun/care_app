import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/chat.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/platform_services.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';

import 'support.dart';

class DelayedPlatform extends FakePlatform {
  Completer<Uint8List?>? photoResult;
  Completer<bool>? permissionResult;
  Completer<void>? scheduleResult;
  int scheduleCalls = 0;
  int saveCalls = 0;
  @override
  Future<void> saveBackup(Uint8List data) async {
    saveCalls++;
  }

  @override
  Future<Uint8List?> pickPhoto({bool camera = false}) async =>
      photoResult?.future;
  @override
  Future<bool> requestNotifications() async =>
      permissionResult == null ? permission : await permissionResult!.future;
  @override
  Future<void> schedule(List<Reminder> next) async {
    scheduleCalls++;
    await scheduleResult?.future;
    await super.schedule(next);
  }
}

void main() {
  late Directory root;
  late CareController c;
  late DelayedPlatform platform;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-review-');
    platform = DelayedPlatform();
    c = CareController(VaultStore(root, MemorySecrets()), platform);
    await c.initialize();
    await c.setPin('123456');
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });

  test(
    'REVIEW-01 locked controller rejects reads and protected operations',
    () async {
      final pid = c.selectedId!;
      c.lock();
      expect(c.patients, isEmpty);
      expect(c.entries, isEmpty);
      expect(() => c.db, throwsA(isA<CareError>()));
      await expectLater(c.enableDeviceAuth(false), throwsA(isA<CareError>()));
      await expectLater(
        c.enableNotifications(false),
        throwsA(isA<CareError>()),
      );
      await expectLater(c.chooseBackup(), throwsA(isA<CareError>()));
      await expectLater(
        c.exportBackup('long-backup-password'),
        throwsA(isA<CareError>()),
      );
      await expectLater(c.selectPatient(pid), throwsA(isA<CareError>()));
    },
  );

  test(
    'REVIEW-01 late permission response cannot change a locked notebook',
    () async {
      platform.permissionResult = Completer<bool>();
      final enabling = c.enableNotifications(true);
      await Future<void>.delayed(Duration.zero);
      c.lock();
      final rejected = expectLater(enabling, throwsA(isA<CareError>()));
      platform.permissionResult!.complete(true);
      await rejected;
      await c.unlockPin('123456');
      expect(c.notificationsEnabled, false);
    },
  );

  test(
    'REVIEW-02 mutation excludes concurrent changes and releases busy on error',
    () async {
      final pid = c.selectedId!;
      await c.enableNotifications(true);
      platform.scheduleResult = Completer<void>();
      final saving = c.mutate(
        () => c.db.saveTask(
          pid,
          title: '합성 일정',
          dueAt: DateTime.now().add(const Duration(hours: 1)),
          reminder: true,
        ),
      );
      await expectLater(
        c.mutate(() => c.db.createPatient()),
        throwsA(isA<CareError>()),
      );
      platform.scheduleResult!.complete();
      await saving;
      expect(c.busy, false);
      await expectLater(
        c.mutate(() => throw const CareError('합성 실패')),
        throwsA(isA<CareError>()),
      );
      expect(c.busy, false);
    },
  );

  test(
    'REVIEW-03 unrelated records do not reschedule and task IDs stay stable',
    () async {
      final pid = c.selectedId!;
      final due = DateTime.now().add(const Duration(hours: 3));
      await c.mutate(
        () => c.db.saveTask(pid, title: '먼 일정', dueAt: due, reminder: true),
      );
      await c.enableNotifications(true);
      final id = platform.reminders.single.id;
      final calls = platform.scheduleCalls;
      await c.setChatRetention(pid, ChatRetention.week);
      await c.addChatMessage(pid, '합성 질문');
      await c.mutate(
        () => c.db.saveEntry(
          pid,
          kind: EntryKind.generalNote,
          occurredAt: DateTime.now(),
          note: '합성 메모',
        ),
      );
      expect(platform.scheduleCalls, calls);
      await c.mutate(
        () => c.db.saveTask(
          pid,
          title: '가까운 일정',
          dueAt: due.subtract(const Duration(hours: 1)),
          reminder: true,
        ),
      );
      expect(
        platform.reminders
            .singleWhere(
              (r) => r.at.millisecondsSinceEpoch == due.millisecondsSinceEpoch,
            )
            .id,
        id,
      );
    },
  );
  test('REVIEW-01 camera response after lock cannot save a photo', () async {
    final pid = c.selectedId!;
    final e = c.db.saveEntry(
      pid,
      kind: EntryKind.generalNote,
      occurredAt: DateTime.now(),
      note: '합성 사진 기록',
    );
    platform.photoResult = Completer<Uint8List?>();
    final adding = c.addPhoto(pid, e.id, camera: true);
    c.lock();
    final rejected = expectLater(adding, throwsA(isA<CareError>()));
    platform.photoResult!.complete(Uint8List.fromList([1, 2, 3]));
    await rejected;
    await c.unlockPin('123456');
    expect(c.db.attachments(pid, e.id), isEmpty);
    expect(c.busy, false);
  });

  test('REVIEW-01 backup prepared after lock is not exported', () async {
    final exporting = c.exportBackup('review-backup-password');
    c.lock();
    await expectLater(exporting, throwsA(isA<CareError>()));
    expect(platform.saveCalls, 0);
  });

  test(
    'REVIEW-06 bounded queries preserve scope, search and order across batches',
    () {
      final pid = c.selectedId!, other = c.db.createPatient().id;
      final at = DateTime(2026, 1, 1);
      for (var i = 0; i < 450; i++) {
        c.db.saveEntry(
          pid,
          kind: i.isEven ? EntryKind.generalNote : EntryKind.meal,
          note: '합성 $i',
          occurredAt: at.add(Duration(minutes: i)),
          fields: i.isEven ? {} : {'food': '밥'},
        );
      }
      final foreign = c.db.saveEntry(
        other,
        kind: EntryKind.generalNote,
        occurredAt: at,
        note: '다른 수첩',
      );
      final all = c.db.entries(pid);
      expect(all, hasLength(450));
      expect(
        c.db.entries(pid, limit: 5).map((e) => e.id),
        all.take(5).map((e) => e.id),
      );
      expect(c.db.entries(pid, query: '음식: 밥', limit: 7), hasLength(7));
      expect(c.db.entries(pid, query: '합성 0').single.note, '합성 0');
      expect(c.db.entry(pid, all.last.id)?.note, '합성 0');
      expect(c.db.entry(pid, foreign.id), isNull);
      expect(c.db.entries(pid, limit: 0), isEmpty);
    },
  );
}
