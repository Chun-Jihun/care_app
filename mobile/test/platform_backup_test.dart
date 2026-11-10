import 'dart:io';

import 'package:care_notebook/domain/ai.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/ai/device_ai_runtime.dart';
import 'package:care_notebook/infrastructure/device_knowledge_library.dart';
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
      expect(call.method, 'pickDocument');
      expect(call.arguments, {'maxBytes': 104857728, 'installBytes': 0});
      return switch (attempts++) {
        0 => file.path,
        1 => null,
        2 => throw PlatformException(code: 'documentTooLarge'),
        _ => throw PlatformException(
          code: 'documentSpaceInsufficient',
          details: 1024 * 1024 + 1,
        ),
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
    await expectLater(
      platform.pickBackup(),
      throwsA(
        isA<CareError>()
            .having(
              (e) => e.code,
              'code',
              CareErrorCode.storageSpaceInsufficient,
            )
            .having((e) => e.labels, 'labels', ['2']),
      ),
    );
  });

  test(
    'Android model and evidence imports bound and clean their own stage',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      final dir = await Directory.systemTemp.createTemp('care-document-test-');
      messenger.setMockMethodCallHandler(pathProvider, (call) async {
        expect(call.method, 'getApplicationSupportDirectory');
        return dir.path;
      });
      final runtime = DeviceAiRuntime();
      addTearDown(() async {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(
          DevicePlatformServices.privacy,
          null,
        );
        messenger.setMockMethodCallHandler(pathProvider, null);
        await runtime.dispose();
        await dir.delete(recursive: true);
      });
      final model = await File('${dir.path}/care-document-import-model.tmp')
          .writeAsBytes([1]);
      final evidence = await File(
        '${dir.path}/care-document-import-evidence.tmp',
      ).writeAsBytes([2]);
      final manifestBytes = await File('assets/ai/manifest.json').length();
      var attempts = 0;
      messenger.setMockMethodCallHandler(DevicePlatformServices.privacy, (
        call,
      ) async {
        expect(call.method, 'pickDocument');
        if (attempts++ < 2) {
          expect(call.arguments, {
            'maxBytes': 1716572594,
            'installBytes': 1716572594 - 12 - manifestBytes,
          });
          if (attempts == 1) throw PlatformException(code: 'documentTooLarge');
          runtime.cancel();
          return model.path;
        }
        expect(call.arguments, {
          'maxBytes': 50 * 1024 * 1024 + 65536 + 12,
          'installBytes': 50 * 1024 * 1024,
        });
        return evidence.path;
      });
      await expectLater(
        runtime.pickBundle(),
        throwsA(
          isA<AiException>().having(
            (e) => e.code,
            'code',
            AiFailure.modelInvalid,
          ),
        ),
      );
      await expectLater(
        runtime.pickBundle(),
        throwsA(
          isA<AiException>().having((e) => e.code, 'code', AiFailure.cancelled),
        ),
      );
      expect(await model.exists(), isFalse);
      expect(await evidence.exists(), isTrue);
      final library = DeviceKnowledgeLibrary();
      final path = (await library.pickBundle())!;
      await expectLater(
        library.install(path, (_) {}, () => throw StateError('cancelled')),
        throwsStateError,
      );
      expect(await evidence.exists(), isFalse);
    },
  );
}
