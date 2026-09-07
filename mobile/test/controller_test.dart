import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';

import 'support.dart';

void main() {
  late Directory root;
  late MemorySecrets secrets;
  late FakePlatform platform;
  late CareController c;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-controller-');
    secrets = MemorySecrets();
    platform = FakePlatform();
    c = CareController(VaultStore(root, secrets), platform);
    await c.initialize();
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });
  test(
    'LOCAL-10 PIN lock, failed write, restart throttling and late unlock',
    () async {
      await c.setPin('123456');
      expect(c.patient.alias, isEmpty);
      expect(c.unlocked, true);
      secrets.rejectKey = 'auth.pin';
      await expectLater(c.setPin('654321'), throwsA(anything));
      secrets.rejectKey = null;
      c.lock();
      await expectLater(c.setPin('654321'), throwsA(isA<CareError>()));
      await c.unlockPin('123456');
      expect(c.unlocked, true);
      c.lock();
      final opening = c.unlockPin('123456');
      c.lock();
      await opening;
      expect(c.unlocked, false);
      for (var i = 0; i < 5; i++) {
        await expectLater(c.unlockPin('000000'), throwsA(isA<CareError>()));
      }
      c.dispose();
      c = CareController(VaultStore(root, secrets), platform);
      await c.initialize();
      expect(c.hasPin, true);
      await expectLater(c.unlockPin('123456'), throwsA(isA<CareError>()));
      await secrets.write('auth.until', '0');
      await c.unlockPin('123456');
      expect(c.unlocked, true);
      await c.deleteAll();
      expect(c.unlocked, false);
      expect(c.hasPin, false);
      expect(secrets.values, isEmpty);
    },
  );
  test(
    'LOCAL-06/14 denied notifications do not create intake or lose records',
    () async {
      await c.setPin('123456');
      final pid = c.selectedId!;
      await c.mutate(
        () => c.db.saveMedication(
          pid,
          name: '사용자가 적은 약',
          instruction: '원문',
          times: ['08:00'],
        ),
      );
      platform.permission = false;
      await expectLater(c.enableNotifications(true), throwsA(isA<CareError>()));
      expect(c.notificationsEnabled, false);
      expect(platform.reminders, isEmpty);
      platform.permission = true;
      await c.enableNotifications(true);
      expect(platform.reminders, hasLength(1));
      expect(c.entries, isEmpty);
      platform.scheduleFails = true;
      await c.mutate(
        () => c.db.saveEntry(
          pid,
          kind: EntryKind.generalNote,
          note: '저장 성공',
          occurredAt: DateTime.now(),
        ),
      );
      expect(c.entries.single.note, '저장 성공');
      expect(c.notice, isNotNull);
      platform.scheduleFails = false;
      await c.enableNotifications(false);
      expect(platform.reminders, isEmpty);
    },
  );
}
