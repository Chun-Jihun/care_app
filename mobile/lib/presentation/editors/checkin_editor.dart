import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../application/care_controller.dart';
import '../../application/draft_session.dart';
import '../../domain/drafts.dart';
import '../../domain/records.dart';
import '../common.dart';
import '../draft_support.dart';

Future<void> addCheckin(
  BuildContext context,
  CareController c, {
  CareDraft? restored,
}) async {
  if (!await chooseDraftRetention(context, c, onlyIfUnset: true) ||
      !context.mounted) {
    return;
  }
  final data = restored?.payload as CheckinDraftPayload?;
  final fatigue = TextEditingController(text: data?.fatigue),
      sleep = TextEditingController(text: data?.sleep),
      stress = TextEditingController(text: data?.stress),
      note = TextEditingController(text: data?.note);
  final draft = DraftSession(
    c,
    patientId: null,
    type: DraftType.checkin,
    restored: restored,
    snapshot: () => CheckinDraftPayload(
      fatigue: fatigue.text,
      sleep: sleep.text,
      stress: stress.text,
      note: note.text,
    ),
  );
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (_) => EditorPage(
          title: context.tr('돌보는 나의 상태'),
          draft: draft,
          content: (_) => [
            Text(context.tr('돌봄을 이어가는 내 상태를 적어 보세요. 환자의 일기와 따로 보관됩니다.')),
            textField(fatigue, context.tr('피로 정도')),
            textField(sleep, context.tr('수면 시간·상태')),
            textField(stress, context.tr('스트레스')),
            textField(note, context.tr('내게 필요한 도움·메모'), multiline: true),
          ],
          save: () async {
            if ([
              fatigue,
              sleep,
              stress,
              note,
            ].every((c) => c.text.trim().isEmpty)) {
              throw CareError(CareErrorCode.checkinRequired);
            }
            await draft.complete();
          },
        ),
      ),
    );
  } finally {
    draft.dispose();
    for (final t in [fatigue, sleep, stress, note]) {
      t.dispose();
    }
  }
  c.draftsChanged();
}
