import 'dart:io';

import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/platform_services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Android vault capacity is read in bytes and failure blocks staging',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          DevicePlatformServices.privacy,
          null,
        );
      });
      var succeeds = true;
      messenger.setMockMethodCallHandler(DevicePlatformServices.privacy, (
        call,
      ) async {
        expect(call.method, 'availableVaultBytes');
        if (succeeds) return 6 * 1024 * 1024 * 1024;
        throw PlatformException(code: 'unavailable');
      });
      expect(await DevicePlatformServices.availableVaultBytes(), 6442450944);
      succeeds = false;
      await expectLater(
        DevicePlatformServices.availableVaultBytes(),
        throwsA(
          isA<CareError>().having(
            (e) => e.code,
            'code',
            CareErrorCode.storageSpaceCheckFailed,
          ),
        ),
      );
    },
  );

  test('Android backup import requests a bounded document and cleans the staged copy', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final directory = await Directory.systemTemp.createTemp(
      'care-backup-import-',
    );
    addTearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(DevicePlatformServices.privacy, null);
      await directory.delete(recursive: true);
    });
    final file = await File('${directory.path}/care-backup-import-fixture.tmp')
        .writeAsBytes([1, 2, 3]);
    var attempts = 0;
    messenger.setMockMethodCallHandler(DevicePlatformServices.privacy, (
      call,
    ) async {
      expect(call.method, 'pickBackup');
      expect(call.arguments, 104857728);
      return switch (attempts++) {
        0 => file.path,
        1 => null,
        _ => throw PlatformException(code: 'backupFileTooLarge'),
      };
    });
    final platform = DevicePlatformServices();
    expect(await platform.pickBackup(), [1, 2, 3]);
    expect(await file.exists(), isFalse);
    expect(await platform.pickBackup(), isNull);
    await expectLater(
      platform.pickBackup(),
      throwsA(
        isA<CareError>().having(
          (e) => e.code,
          'code',
          CareErrorCode.backupFileTooLarge,
        ),
      ),
    );
  });
}
