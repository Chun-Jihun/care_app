import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/drafts.dart';
import '../domain/records.dart';
import '../infrastructure/care_database.dart';
import 'common.dart';
import 'draft_support.dart';
import 'editors.dart';

String draftLabel(CareDraft draft) => draft.type == DraftType.entry
    ? EntryKind.values.byName(draft.values['kind'] as String).label
    : draft.type.label;

Future<void> resumeDraft(
  BuildContext context,
  CareController c,
  CareDraft draft,
) async {
  if (draft.patientId != null && draft.patientId != c.selectedId) {
    throw const CareError('초안이 속한 수첩으로 전환해 주세요.');
  }
  var matches = false;
  try {
    matches =
        c.db.draftBase(draft.type, draft.patientId, draft.targetId) ==
        draft.base;
  } catch (_) {
    /* Deleted source. */
  }
  if (!matches) {
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('원본이 바뀌거나 삭제되었어요'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '초안은 보관되어 있습니다. 아래 내용을 확인하고 최신 기록에서 다시 작성해 주세요. 자동으로 덮어쓰지 않습니다.',
            ),
            const SizedBox(height: 16),
            SelectableText(_draftText(draft)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('확인'),
          ),
        ],
      ),
    );
    return;
  }
  switch (draft.type) {
    case DraftType.entry:
      await editEntry(
        context,
        c,
        EntryKind.values.byName(draft.values['kind'] as String),
        entry: draft.targetId == null
            ? null
            : c.db.entry(draft.patientId!, draft.targetId!),
        restored: draft,
      );
    case DraftType.medication:
      await editMedication(
        context,
        c,
        medication: draft.targetId == null
            ? null
            : c.db
                  .medications(draft.patientId!, includeArchived: true)
                  .firstWhere((m) => m.id == draft.targetId),
        restored: draft,
      );
    case DraftType.intake:
      await recordIntake(
        context,
        c,
        c.db
            .medications(draft.patientId!, includeArchived: true)
            .firstWhere((m) => m.id == draft.targetId),
        restored: draft,
      );
    case DraftType.task:
      await editTask(
        context,
        c,
        task: draft.targetId == null
            ? null
            : c.db
                  .tasks(draft.patientId!)
                  .firstWhere((t) => t.id == draft.targetId),
        restored: draft,
      );
    case DraftType.visit:
      await editVisit(
        context,
        c,
        visit: draft.targetId == null
            ? null
            : c.db
                  .visits(draft.patientId!)
                  .firstWhere((v) => v.id == draft.targetId),
        restored: draft,
      );
    case DraftType.checkin:
      await addCheckin(context, c, restored: draft);
  }
}

String _draftText(CareDraft draft) {
  final labels = <String, String>{
    'note': '메모',
    'name': '약 이름',
    'instruction': '처방 지시',
    'times': '확인 시각',
    'reason': '누락·거부 이유',
    'reaction': '관찰한 반응',
    'title': '제목',
    'questions': '진료 질문',
    'fatigue': '피로',
    'sleep': '수면',
    'stress': '스트레스',
    for (final kind in EntryKind.values)
      for (final f in kind.fields) f.key: f.label,
  };
  final values = {...draft.values, ...?draft.values['fields'] as Map?};
  return [
    if (values['at'] case final int at)
      '시각: ${dateText(DateTime.fromMillisecondsSinceEpoch(at))} ${timeText(DateTime.fromMillisecondsSinceEpoch(at))}',
    for (final e in values.entries)
      if (labels.containsKey(e.key) &&
          e.value is String &&
          (e.value as String).isNotEmpty)
        '${labels[e.key]}: ${e.key == 'status' ? intakeLabels[e.value] ?? e.value : e.value}',
  ].join('\n\n');
}

class DraftPage extends StatelessWidget {
  const DraftPage(this.c, {super.key});
  final CareController c;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      if (!c.unlocked) return const SizedBox.shrink();
      final drafts = [...c.db.drafts(c.selectedId), ...c.db.drafts(null)];
      return Scaffold(
        appBar: AppBar(title: const Text('작성 중인 초안')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('${c.patient.label} 수첩과 돌보는 나의 초안입니다. 저장을 눌러야 기록으로 확정됩니다.'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('보관기간: ${c.db.draftRetention?.label ?? '선택 필요'}'),
              subtitle: const Text('마지막 자동 저장 시각부터 계산해요.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => attempt(context, () async {
                await chooseDraftRetention(context, c);
              }),
            ),
            if (drafts.isEmpty)
              const EmptyCard(
                '작성 중인 초안이 없어요',
                '작성 중 앱이 잠기거나 초안을 보관하고 나가면 여기에서 이어서 작성할 수 있어요.',
              ),
            for (final d in drafts)
              Card(
                child: ListTile(
                  title: Text(
                    '${draftLabel(d)}${d.targetId == null ? '' : ' · 기존 항목 작성 중'}',
                  ),
                  subtitle: Text(
                    '${dateText(d.updatedAt)} ${timeText(d.updatedAt)} 저장${d.expiresAt == null ? '' : '\n${dateText(d.expiresAt!)} ${timeText(d.expiresAt!)} 만료'}',
                  ),
                  leading: const Icon(Icons.edit_note, color: forest),
                  onTap: () =>
                      attempt(context, () => resumeDraft(context, c, d)),
                  trailing: IconButton(
                    tooltip: '초안 삭제',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (await confirm(
                            context,
                            '이 초안을 삭제할까요?',
                            '작성 중인 내용만 삭제합니다. 확정한 기록은 유지됩니다.',
                          ) &&
                          context.mounted) {
                        await attempt(context, () async {
                          await c.mutate(
                            () => c.db.deleteDraft(d.patientId, d.id),
                          );
                        });
                      }
                    },
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
