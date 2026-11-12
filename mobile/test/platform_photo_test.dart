import 'dart:io';

import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/platform_services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android gallery stages at most 20 MiB and discards the copy', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final cache = await Directory.systemTemp.createTemp('care-photo-import-');
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(DevicePlatformServices.privacy, null);
      await cache.delete(recursive: true);
    });
    final file = await File('${cache.path}/photo.tmp').writeAsBytes([1, 2, 3]);
    var attempts = 0;
    messenger.setMockMethodCallHandler(DevicePlatformServices.privacy, (
      call,
    ) async {
      expect(call.method, 'pickDocument');
      expect(call.arguments, {
        'maxBytes': 20 * 1024 * 1024,
        'installBytes': 0,
        'imageOnly': true,
      });
      return switch (attempts++) {
        0 => file.path,
        1 => null,
        2 => throw PlatformException(code: 'documentTooLarge'),
        _ => throw PlatformException(code: 'documentOpenFailed'),
      };
    });

    final platform = DevicePlatformServices();
    expect(await platform.pickPhoto(), [1, 2, 3]);
    expect(await file.exists(), isFalse);
    expect(await platform.pickPhoto(), isNull);
    for (final code in [
      CareErrorCode.photoTooLarge,
      CareErrorCode.photoDecodeFailed,
    ]) {
      await expectLater(
        platform.pickPhoto(),
        throwsA(isA<CareError>().having((error) => error.code, 'code', code)),
      );
    }
  });
}
