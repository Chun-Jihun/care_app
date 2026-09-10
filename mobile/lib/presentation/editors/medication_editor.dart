import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../application/care_controller.dart';
import '../../application/draft_session.dart';
import '../../domain/drafts.dart';
import '../../domain/records.dart';
import '../common.dart';
import '../draft_support.dart';

Future<void> editMedication(
  BuildContext context,
  CareController c, {
  Medication? medication,
  CareDraft? restored,
}) async {
  if (!await chooseDraftRetention(context, c, onlyIfUnset: true) ||
      !context.mounted) {
    return;
  }
  final data = restored?.payload as MedicationDraftPayload?;
  final pid = c.selectedId!,
      name = TextEditingController(text: data?.name ?? medication?.name),
      instruction = TextEditingController(
        text: data?.instruction ?? medication?.instruction,
      ),
      times = TextEditingController(
        text: data?.times ?? medication?.times.join(', '),
      );
  final draft = DraftSession(
    c,
    patientId: pid,
    type: DraftType.medication,
    targetId: medication?.id,
    restored: restored,
    snapshot: () => MedicationDraftPayload(
      name: name.text,
      instruction: instruction.text,
      times: times.text,
    ),
  );
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (_) => EditorPage(
          title: medication == null
              ? context.tr('약 추가')
              : context.tr('처방 지시 기록'),
          draft: draft,
          content: (_) => [
            textField(name, context.tr('약 이름 *')),
            textField(
              instruction,
              context.tr('의료진의 처방·복용 지시 원문'),
              multiline: true,
            ),
            textField(
              times,
              context.tr('매일 확인할 시각 (선택)'),
              hint: '08:00, 18:00',
            ),
            Text(
              context.tr(
                '전달받은 지시를 그대로 옮겨 적어 주세요. 변경 전 지시와 당시의 복약 기록은 이력에 남습니다. 알림은 설정에서 켤 수 있어요.',
              ),
            ),
          ],
          save: () async {
            await draft.complete();
          },
        ),
      ),
    );
  } finally {
    draft.dispose();
    name.dispose();
    instruction.dispose();
    times.dispose();
  }
  c.draftsChanged();
}
