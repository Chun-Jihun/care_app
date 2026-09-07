import 'package:flutter/material.dart';

import 'application/care_controller.dart';
import 'infrastructure/platform_services.dart';
import 'infrastructure/vault_store.dart';
import 'presentation/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final controller = CareController(
      VaultStore(
        await DevicePlatformServices.prepareDirectory(),
        DeviceSecretStore(),
      ),
      DevicePlatformServices(),
    );
    await controller.initialize();
    runApp(CareApp(controller: controller));
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  '보안 저장소를 열 수 없습니다. 앱을 다시 실행해 주세요. 기존 기록은 초기화하지 않았습니다.',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
