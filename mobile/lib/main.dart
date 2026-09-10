import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/app_strings.dart';

import 'application/care_controller.dart';
import 'infrastructure/platform_services.dart';
import 'infrastructure/vault_store.dart';
import 'presentation/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var language = AppLanguage.fromLocale(
    WidgetsBinding.instance.platformDispatcher.locale,
  );
  try {
    final secrets = DeviceSecretStore();
    language = AppLanguage.fromCode(await secrets.read('app.language'));
    final controller = CareController(
      VaultStore(await DevicePlatformServices.prepareDirectory(), secrets),
      DevicePlatformServices(),
    );
    await controller.initialize();
    runApp(CareApp(controller: controller));
  } catch (_) {
    runApp(
      MaterialApp(
        locale: language.locale,
        supportedLocales: AppLanguage.values.map((value) => value.locale),
        localizationsDelegates: const [
          AppStrings.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        home: Builder(
          builder: (context) => Scaffold(
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    context.tr(
                      '보안 저장소를 열 수 없습니다. 앱을 다시 실행해 주세요. 기존 기록은 초기화하지 않았습니다.',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
