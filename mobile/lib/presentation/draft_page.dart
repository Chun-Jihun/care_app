import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/drafts.dart';
import '../domain/records.dart';
import 'common.dart';
import 'draft_support.dart';
import 'editors.dart';

String draftLabel(BuildContext context, CareDraft draft) =>
    switch (draft.payload) {
      EntryDraftPayload value => context.tr(value.kind.label),
      UnreadableDraftPayload() => context.tr('이 초안을 읽을 수 없어요'),
      _ => context.tr(draft.type.label),
    };

Future<void> resumeDraft(
  BuildContext context,
  CareController c,
  CareDraft draft,
) async {
  if (draft.patientId != null && draft.patientId != c.selectedId) {
    throw CareError(CareErrorCode.draftPatientMismatch);
  }
  if (draft.payload case UnreadableDraftPayload(:final raw)) {
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(context.tr('이 초안을 읽을 수 없어요')),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr('지원하지 않는 형식이거나 내용이 손상되었습니다. 원문을 보관했으니 확인하거나 삭제해 주세요.'),
            ),
            const SizedBox(height: 16),
            SelectableText(raw),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.tr('확인')),
          ),
        ],
      ),
    );
    return;
  }
  var matches = false;
  try {
    matches =
        c.drafts.base(draft.type, draft.patientId, draft.targetId) ==
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
        title: Text(context.tr('원본이 바뀌거나 삭제되었어요')),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr(
                '초안은 보관되어 있습니다. 아래 내용을 확인하고 최신 기록에서 다시 작성해 주세요. 자동으로 덮어쓰지 않습니다.',
              ),
            ),
            const SizedBox(height: 16),
            SelectableText(_draftText(context, draft)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.tr('확인')),
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
        (draft.payload as EntryDraftPayload).kind,
        entry: draft.targetId == null
            ? null
            : c.records.entry(draft.patientId!, draft.targetId!),
        restored: draft,
      );
    case DraftType.medication:
      await editMedication(
        context,
        c,
        medication: draft.targetId == null
            ? null
            : c.medicationBook
                  .medications(draft.patientId!, includeArchived: true)
                  .firstWhere((m) => m.id == draft.targetId),
        restored: draft,
      );
    case DraftType.intake:
      await recordIntake(
        context,
        c,
        c.medicationBook
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
            : c.taskBook
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
            : c.visitBook
                  .visits(draft.patientId!)
                  .firstWhere((v) => v.id == draft.targetId),
        restored: draft,
      );
    case DraftType.checkin:
      await addCheckin(context, c, restored: draft);
  }
}

String _draftText(BuildContext context, CareDraft draft) {
  if (draft.payload case UnreadableDraftPayload(:final raw)) return raw;
  final labels = <String, String>{
    'note': context.tr('메모'),
    'name': context.tr('약 이름'),
    'instruction': context.tr('처방 지시'),
    'times': context.tr('확인 시각'),
    'reason': context.tr('누락·거부 이유'),
    'reaction': context.tr('관찰한 반응'),
    'title': context.tr('제목'),
    'questions': context.tr('진료 질문'),
    'fatigue': context.tr('피로'),
    'sleep': context.tr('수면'),
    'stress': context.tr('스트레스'),
    for (final kind in EntryKind.values)
      for (final f in kind.fields) f.key: context.tr(f.label),
  };
  String displayValue(String key, String value) {
    if (draft.type == DraftType.intake && key == 'status') {
      return intakeLabels.containsKey(value)
          ? context.tr(intakeLabels[value]!)
          : value;
    }
    if (draft.type == DraftType.entry) {
      final kind = (draft.payload as EntryDraftPayload).kind;
      for (final field in kind.fields) {
        if (field.key == key) return context.strings.fieldValue(field, value);
      }
    }
    return value;
  }

  final values = {...draft.values, ...?draft.values['fields'] as Map?};
  return [
    if (values['at'] case final int at)
      context.tr('시각: {0} {1}', [
        dateText(context, DateTime.fromMillisecondsSinceEpoch(at)),
        timeText(context, DateTime.fromMillisecondsSinceEpoch(at)),
      ]),
    for (final e in values.entries)
      if (labels.containsKey(e.key) &&
          e.value is String &&
          (e.value as String).isNotEmpty)
        '${labels[e.key]}: ${displayValue(e.key as String, e.value as String)}',
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
      final drafts = [...c.drafts.list(c.selectedId), ...c.drafts.list(null)];
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('작성 중인 초안'))),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              context.tr('{0} 수첩과 돌보는 나의 초안입니다. 저장을 눌러야 기록으로 확정됩니다.', [
                context.strings.patient(c.patient),
              ]),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                context.tr('보관기간: {0}', [
                  context.tr(c.drafts.retention?.label ?? '선택 필요'),
                ]),
              ),
              subtitle: Text(context.tr('마지막 자동 저장 시각부터 계산해요.')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => attempt(context, () async {
                await chooseDraftRetention(context, c);
              }),
            ),
            if (drafts.isEmpty)
              EmptyCard(
                context.tr('작성 중인 초안이 없어요'),
                context.tr('작성 중 앱이 잠기거나 초안을 보관하고 나가면 여기에서 이어서 작성할 수 있어요.'),
              ),
            for (final d in drafts)
              Card(
                child: ListTile(
                  title: Text(
                    '${draftLabel(context, d)}${d.targetId == null ? '' : context.tr(' · 기존 항목 작성 중')}',
                  ),
                  subtitle: Text(
                    context.tr('{0} {1} 저장{2}', [
                      dateText(context, d.updatedAt),
                      timeText(context, d.updatedAt),
                      d.expiresAt == null
                          ? ''
                          : context.tr('\n{0} {1} 만료', [
                              dateText(context, d.expiresAt!),
                              timeText(context, d.expiresAt!),
                            ]),
                    ]),
                  ),
                  leading: const Icon(Icons.edit_note, color: forest),
                  onTap: () =>
                      attempt(context, () => resumeDraft(context, c, d)),
                  trailing: IconButton(
                    tooltip: context.tr('초안 삭제'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (await confirm(
                            context,
                            context.tr('이 초안을 삭제할까요?'),
                            context.tr('작성 중인 내용만 삭제합니다. 확정한 기록은 유지됩니다.'),
                          ) &&
                          context.mounted) {
                        await attempt(context, () async {
                          await c.drafts.delete(d.patientId, d.id);
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
