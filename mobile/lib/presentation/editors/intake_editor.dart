import '../contact_action.dart';
import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../application/care_controller.dart';
import '../../application/draft_session.dart';
import '../../domain/drafts.dart';
import '../../domain/records.dart';
import '../common.dart';
import '../draft_support.dart';

Future<void> recordIntake(
  BuildContext context,
  CareController c,
  Medication medication, {
  CareDraft? restored,
}) async {
  if (!await chooseDraftRetention(context, c, onlyIfUnset: true) ||
      !context.mounted) {
    return;
  }
  final data = restored?.payload as IntakeDraftPayload?;
  final pid = c.selectedId!,
      reason = TextEditingController(text: data?.reason),
      reaction = TextEditingController(text: data?.reaction);
  var status = data?.status ?? '';
  var at = data?.at ?? DateTime.now();
  final draft = DraftSession(
    c,
    patientId: pid,
    type: DraftType.intake,
    targetId: medication.id,
    restored: restored,
    snapshot: () => IntakeDraftPayload(
      status: status,
      at: at,
      reason: reason.text,
      reaction: reaction.text,
    ),
  );
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (context) => EditorPage(
          actions: [ContactAction(c)],
          onSaved: c.showSavedNotice,
          title: context.tr('복약 기록'),
          saveLabel: context.tr('복약 기록 저장'),
          draft: draft,
          content: (update) => [
            Text(
              context.tr('{0} · 실제 복약', [context.strings.patient(c.patient)]),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              medication.name,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (medication.instruction.isNotEmpty) Text(medication.instruction),
            Text(context.tr('실제로 복용하거나 확인한 시각')),
            dateButton(context, at, update, (v) => at = v),
            TextButton.icon(
              onPressed: () => update(() => at = DateTime.now()),
              icon: const Icon(Icons.schedule),
              label: Text(context.tr('지금 시각으로')),
            ),
            ...c.medicationBook
                .intakes(pid, medication.id, at)
                .take(3)
                .map(
                  (entry) => Text(
                    context.tr('같은 날 기록: {0} · {1}', [
                      timeText(context, entry.occurredAt),
                      context.tr(
                        intakeLabels[entry.fields['status']] ?? '확인 못함',
                      ),
                    ]),
                  ),
                ),
            DropdownButtonFormField<String>(
              isExpanded: true,
              itemHeight: null,
              initialValue: status.isEmpty ? null : status,
              decoration: InputDecoration(labelText: context.tr('실제 복용 상태')),
              hint: Text(context.tr('확인한 상태를 선택해 주세요')),
              items: intakeLabels.entries
                  .map(
                    (e) => DropdownMenuItem(
                      value: e.key,
                      child: Text(context.tr(e.value)),
                    ),
                  )
                  .toList(),
              onChanged: (v) => update(() => status = v!),
            ),
            textField(reason, context.tr('누락·거부 이유 (선택)')),
            textField(reaction, context.tr('관찰한 반응 (선택)'), multiline: true),
          ],
          save: () async {
            if (!intakeLabels.containsKey(status)) {
              throw CareError(CareErrorCode.intakeStatusRequired);
            }
            // Same input minute means potentially duplicated logging, not a
            // clinical judgement about safe dose intervals.
            final matching = c.medicationBook
                .intakes(pid, medication.id, at)
                .where((e) {
                  final previous = e.occurredAt;
                  return previous.year == at.year &&
                      previous.month == at.month &&
                      previous.day == at.day &&
                      previous.hour == at.hour &&
                      previous.minute == at.minute;
                });
            if (matching.isNotEmpty &&
                !await confirm(
                  context,
                  context.tr('같은 시각의 복약 기록이 있어요'),
                  context.tr('기존 기록과 실제 복용 사실을 확인해 주세요. 새 기록을 추가할까요?'),
                  action: context.tr('새 기록 추가'),
                )) {
              throw const EditorCancelled();
            }
            if (!context.mounted) throw const EditorCancelled();
            await draft.complete();
          },
        ),
      ),
    );
  } finally {
    draft.dispose();
    reason.dispose();
    reaction.dispose();
  }
  c.draftsChanged();
}
