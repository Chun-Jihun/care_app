import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../l10n/app_strings.dart';
import 'common.dart';
import 'editors.dart';

class CheckinHistoryPage extends StatefulWidget {
  const CheckinHistoryPage(this.c, {super.key});
  final CareController c;
  @override
  State<CheckinHistoryPage> createState() => _CheckinHistoryPageState();
}

class _CheckinHistoryPageState extends State<CheckinHistoryPage> {
  int limit = 30;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.c,
    builder: (context, _) {
      if (!widget.c.unlocked) return const SizedBox.shrink();
      final records = widget.c.checkins.checkins(limit: limit + 1);
      final shown = records.take(limit).toList();
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('돌보는 나의 상태'))),
        body: ListView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: shown.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: () => addCheckin(context, widget.c),
                    icon: const Icon(Icons.add),
                    label: Text(context.tr('상태 기록')),
                  ),
                  if (shown.isEmpty)
                    Text(context.tr('수면, 피로, 스트레스와 필요한 도움을 따로 기록할 수 있어요.')),
                ],
              );
            }
            if (index == shown.length + 1) {
              return records.length > limit
                  ? OutlinedButton(
                      onPressed: () => setState(() => limit += 30),
                      child: Text(context.tr('기록 더 보기')),
                    )
                  : const SizedBox(height: 20);
            }
            final r = shown[index - 1];
            return Card(
              child: ListTile(
                title: Text(dateText(context, r.occurredAt)),
                subtitle: Text(
                  [
                    context.tr('피로: {0}', [r.fatigue]),
                    context.tr('수면: {0}', [r.sleep]),
                    context.tr('스트레스: {0}', [r.stress]),
                    r.note,
                  ].join('\n'),
                ),
                trailing: IconButton(
                  tooltip: context.tr('내 상태 기록 삭제'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    if (await confirm(
                          context,
                          context.tr('내 상태 기록을 삭제할까요?'),
                          context.tr('선택한 기록을 삭제합니다.'),
                        ) &&
                        context.mounted) {
                      await attempt(
                        context,
                        () => widget.c.checkins.deleteCheckin(r.id),
                      );
                    }
                  },
                ),
              ),
            );
          },
        ),
      );
    },
  );
}
