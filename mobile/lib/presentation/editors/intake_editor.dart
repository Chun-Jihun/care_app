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
  var status = data?.status ?? 'taken';
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
          title: context.tr('복약 기록'),
          draft: draft,
          content: (update) => [
            Text(
              medication.name,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (medication.instruction.isNotEmpty) Text(medication.instruction),
            dateButton(context, at, update, (v) => at = v),
            DropdownButtonFormField<String>(
              isExpanded: true,
              itemHeight: null,
              initialValue: status,
              decoration: InputDecoration(labelText: context.tr('실제 복용 상태')),
              items: intakeLabels.entries
                  .map(
                    (e) => DropdownMenuItem(
                      value: e.key,
                      child: Text(context.tr(e.value)),
                    ),
                  )
                  .toList(),
              onChanged: (v) => status = v!,
            ),
            textField(reason, context.tr('누락·거부 이유 (선택)')),
            textField(reaction, context.tr('관찰한 반응 (선택)'), multiline: true),
          ],
          save: () async {
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
