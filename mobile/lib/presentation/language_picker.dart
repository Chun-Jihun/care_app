import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../l10n/app_strings.dart';
import 'common.dart';

class LanguagePicker extends StatelessWidget {
  const LanguagePicker(this.controller, {super.key});
  final CareController controller;

  @override
  Widget build(BuildContext context) => ListTile(
    key: const ValueKey('languagePicker'),
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.language),
    title: Text(context.tr('언어')),
    subtitle: Text(controller.language.nativeName),
    trailing: const Icon(Icons.chevron_right),
    enabled: !controller.busy,
    onTap: () async {
      final selected = await showDialog<AppLanguage>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => SimpleDialog(
          title: Text(ctx.tr('앱에서 사용할 언어')),
          children: [
            for (final language in AppLanguage.values)
              SimpleDialogOption(
                key: ValueKey('language-${language.code}'),
                onPressed: () => Navigator.pop(ctx, language),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        language == controller.language
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(language.nativeName)),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(ctx.tr('언어를 바꾸어도 작성한 기록은 원문 그대로 유지됩니다.')),
            ),
          ],
        ),
      );
      if (selected != null && context.mounted) {
        await attempt(context, () => controller.setLanguage(selected));
      }
    },
  );
}
