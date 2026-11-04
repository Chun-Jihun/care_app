import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../l10n/app_strings.dart';
import 'common.dart';
import '../domain/ui_preferences.dart';
import 'ui_preferences_scope.dart';

/// Lives outside the pending form, so reading and calling do not cancel it.
class BackupActivityBar extends StatelessWidget {
  const BackupActivityBar(
    this.c, {
    super.key,
    required this.onBrowse,
    required this.browsing,
  });
  final CareController c;
  final VoidCallback? onBrowse;
  final bool browsing;

  @override
  Widget build(BuildContext context) => Material(
    elevation: UiPreferencesScope.of(context).enabled(UiOption.lowGraphics)
        ? 0
        : 4,
    child: SafeArea(
      bottom: false,
      child: browsing
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      label: context.tr('백업·복원 중 · 읽기 전용'),
                      liveRegion: true,
                      child: Text(
                        context.tr('읽기 전용'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onBrowse,
                    tooltip: context.tr('백업 화면으로'),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  if (c.backupContact.isNotEmpty)
                    IconButton(
                      onPressed: () =>
                          attempt(context, () => c.openDialer(c.backupContact)),
                      tooltip: context.tr('저장한 의료기관'),
                      icon: const Icon(Icons.call_outlined),
                    ),
                  Tooltip(
                    message: context.tr('위급할 때 119 (대한민국)'),
                    child: TextButton(
                      onPressed: () =>
                          attempt(context, () => c.openDialer('119')),
                      child: const Text('119'),
                    ),
                  ),
                ],
              ),
            )
          : ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height / 2,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Semantics(
                        liveRegion: true,
                        child: Text(context.tr('백업·복원 중 · 읽기 전용')),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          TextButton.icon(
                            onPressed: onBrowse,
                            icon: const Icon(Icons.auto_stories_outlined),
                            label: Text(context.tr('기록 보기')),
                          ),
                          if (c.backupContact.isNotEmpty)
                            TextButton.icon(
                              onPressed: () => attempt(
                                context,
                                () => c.openDialer(c.backupContact),
                              ),
                              icon: const Icon(Icons.call_outlined),
                              label: Text(context.tr('저장한 의료기관')),
                            ),
                          TextButton.icon(
                            onPressed: () =>
                                attempt(context, () => c.openDialer('119')),
                            icon: const Icon(Icons.emergency_outlined),
                            label: Text(context.tr('위급할 때 119 (대한민국)')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
    ),
  );
}
