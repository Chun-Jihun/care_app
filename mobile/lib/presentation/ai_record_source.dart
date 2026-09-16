import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/ai.dart';
import '../l10n/app_strings.dart';
import 'common.dart';
import 'details.dart';

/// Shared by the answer and its evidence page so version checks cannot diverge.
class AiRecordSource extends StatelessWidget {
  const AiRecordSource(
    this.c,
    this.pid,
    this.source, {
    required this.number,
    this.detailed = false,
    super.key,
  });
  final CareController c;
  final String pid;
  final AiReference source;
  final int number;
  final bool detailed;

  @override
  Widget build(BuildContext context) {
    if (!c.unlocked || c.selectedId != pid) return const SizedBox.shrink();
    final entry = c.records.entry(pid, source.id);
    return Card(
      color: const Color(0xFFF0F4EC),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr('참고 기록 {0}', [number]),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (entry == null)
              Text(context.tr('출처 기록이 삭제되었거나 이번 백업에 포함되지 않았습니다.'))
            else ...[
              if (entry.version == source.version)
                Text(
                  '${context.tr(entry.kind.label)} · ${dateText(context, entry.occurredAt)} ${timeText(context, entry.occurredAt)}',
                ),
              if (detailed)
                Text(context.tr('답변에서 참고한 버전: {0}', [source.version])),
              if (entry.version != source.version)
                Text(context.tr('답변 이후 기록이 수정되었어요. 현재 기록을 다시 확인해 주세요.'))
              else ...[
                if (detailed) ...[
                  const SizedBox(height: 12),
                  Text(
                    context.tr('답변에 사용한 부분'),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
                for (final field in entry.kind.fields)
                  if (entry.fields[field.key]?.isNotEmpty ?? false)
                    SelectableText(
                      '${context.tr(field.label)}: ${context.strings.fieldValue(field, entry.fields[field.key]!)}',
                    ),
                if (entry.note.isNotEmpty) SelectableText(entry.note),
              ],
              if (detailed)
                TextButton.icon(
                  onPressed: () => pushPage(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => EntryDetails(c, pid, entry.id),
                    ),
                  ),
                  icon: const Icon(Icons.open_in_new),
                  label: Text(context.tr('원본 기록 보기')),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
