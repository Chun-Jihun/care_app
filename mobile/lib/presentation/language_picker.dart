import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../l10n/app_strings.dart';

class LanguagePicker extends StatelessWidget {
  const LanguagePicker(this.controller, {super.key});
  final CareController controller;

  @override
  Widget build(BuildContext context) => ListTile(
    key: const ValueKey('languagePicker'),
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.language),
    title: Text(context.tr('언어')),
    subtitle: Text(
      '${controller.language.nativeName}\n${context.tr('언어 변경은 지원 준비 중이에요.')}',
    ),
    // Keep saved preferences and catalogs until the language rollout resumes.
    enabled: false,
  );
}
