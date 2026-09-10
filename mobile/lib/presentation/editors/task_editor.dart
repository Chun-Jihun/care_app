import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../application/care_controller.dart';
import '../../application/draft_session.dart';
import '../../domain/drafts.dart';
import '../../domain/records.dart';
import '../common.dart';
import '../draft_support.dart';

Future<void> editTask(
  BuildContext context,
  CareController c, {
  CareTask? task,
  CareDraft? restored,
}) async {
  if (!await chooseDraftRetention(context, c, onlyIfUnset: true) ||
      !context.mounted) {
    return;
  }
  final data = restored?.payload as TaskDraftPayload?;
  final pid = c.selectedId!,
      title = TextEditingController(text: data?.title ?? task?.title),
      note = TextEditingController(text: data?.note ?? task?.note);
  var at =
      data?.at ?? task?.dueAt ?? DateTime.now().add(const Duration(hours: 1));
  var reminder = data?.reminder ?? task?.reminder ?? false;
  final draft = DraftSession(
    c,
    patientId: pid,
    type: DraftType.task,
    targetId: task?.id,
    restored: restored,
    snapshot: () => TaskDraftPayload(
      title: title.text,
      note: note.text,
      at: at,
      reminder: reminder,
    ),
  );
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (context) => EditorPage(
          title: task == null ? context.tr('할 일 추가') : context.tr('할 일 수정'),
          draft: draft,
          content: (update) => [
            textField(title, context.tr('할 일 *')),
            dateButton(context, at, update, (v) => at = v),
            textField(note, context.tr('메모'), multiline: true),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.tr('일정 알림')),
              subtitle: Text(
                c.notificationsEnabled
                    ? context.tr('기기 상태에 따라 알림 시각이 늦어질 수 있어요.')
                    : context.tr('설정에서 알림을 켜면 예약됩니다.'),
              ),
              value: reminder,
              onChanged: (v) => update(() => reminder = v),
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
    title.dispose();
    note.dispose();
  }
  c.draftsChanged();
}
