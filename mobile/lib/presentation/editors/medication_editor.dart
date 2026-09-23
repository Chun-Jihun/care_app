import 'dart:typed_data';

import '../../domain/reviewed_input.dart';
import '../pending_photo_field.dart';
import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../application/care_controller.dart';
import '../../application/draft_session.dart';
import '../../domain/drafts.dart';
import '../../domain/records.dart';
import '../common.dart';
import '../draft_support.dart';
import '../medication_times_field.dart';

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
  Uint8List? photo;
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
          draftExitNotice: () => photo == null
              ? null
              : context.tr(
                  '사진은 저장을 눌러야 보관돼요. 초안에는 글만 보관되므로 나갔다 돌아오면 사진을 다시 선택해 주세요.',
                ),
          content: (update) => [
            PendingPhotoField(
              c: c,
              pid: pid,
              photo: photo,
              onChanged: (value) => update(() => photo = value),
              onReviewed: (reviewed) => update(
                () => instruction.text = appendReviewedInput(
                  instruction.text,
                  reviewed.text,
                ),
              ),
            ),
            if (photo != null)
              Text(
                context.tr(
                  '저장하면 사진 원본도 약 이름의 진료·연락 기록으로 함께 보관해요. 약 이름과 복용 시각은 직접 확인해 주세요.',
                ),
              ),
            textField(name, context.tr('약 이름 *')),
            textField(
              instruction,
              context.tr('의료진의 처방·복용 지시 원문'),
              multiline: true,
            ),
            MedicationTimesField(
              controller: times,
              onChanged: () => update(() {}),
            ),
            Text(
              context.tr(
                '전달받은 지시를 그대로 옮겨 적어 주세요. 변경 전 지시와 당시의 복약 기록은 이력에 남습니다. 알림은 설정에서 켤 수 있어요.',
              ),
            ),
          ],
          save: () async {
            await draft.complete(photo: photo);
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
