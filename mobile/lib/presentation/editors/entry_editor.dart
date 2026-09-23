import 'dart:typed_data';

import '../pending_photo_field.dart';
import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../application/care_controller.dart';
import '../../application/draft_session.dart';
import '../../domain/drafts.dart';
import '../../domain/records.dart';
import '../../domain/reviewed_input.dart';
import '../common.dart';
import '../ai_draft_page.dart';
import '../draft_support.dart';
import '../record_fields.dart';

Future<void> editEntry(
  BuildContext context,
  CareController c,
  EntryKind kind, {
  CareEntry? entry,
  CareDraft? restored,
  String? initialNote,
  Uint8List? initialPhoto,
  Map<String, String> initialFields = const {},
}) async {
  if (!await chooseDraftRetention(context, c, onlyIfUnset: true) ||
      !context.mounted) {
    return;
  }
  final pid = c.selectedId!;
  Uint8List? photo = initialPhoto;
  final data = restored?.payload as EntryDraftPayload?;
  final note = TextEditingController(
    text: data?.note ?? initialNote ?? entry?.note,
  );
  final values = {
    for (final field in kind.fields)
      field.key: TextEditingController(
        text:
            data?.fields[field.key] ??
            initialFields[field.key] ??
            entry?.fields[field.key],
      ),
  };
  var at = data?.at ?? entry?.occurredAt ?? DateTime.now();
  final fieldsKey = GlobalKey<RecordFieldsState>();
  final draft = DraftSession(
    c,
    patientId: pid,
    type: DraftType.entry,
    targetId: entry?.id,
    restored: restored,
    snapshot: () => EntryDraftPayload(
      kind: kind,
      note: note.text,
      at: at,
      fields: {for (final e in values.entries) e.key: e.value.text},
    ),
  );
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (context) => EditorPage(
          title:
              '${context.tr(kind.label)} ${entry == null ? context.tr('기록') : context.tr('수정')}',
          draft: draft,
          initiallyDirty: initialPhoto != null,
          draftExitNotice: () => photo == null
              ? null
              : context.tr(
                  '사진은 저장을 눌러야 보관돼요. 초안에는 글만 보관되므로 나갔다 돌아오면 사진을 다시 선택해 주세요.',
                ),
          revealError: (error) async =>
              await fieldsKey.currentState?.revealError(error) ?? false,
          content: (update) => [
            Text(
              context.tr('{0} · 직접 작성한 기록', [
                context.strings.patient(c.patient),
              ]),
              style: const TextStyle(color: forest),
            ),
            PendingPhotoField(
              c: c,
              pid: pid,
              photo: photo,
              kind: kind,
              currentFields: {
                for (final e in values.entries) e.key: e.value.text,
              },
              onChanged: (value) => update(() => photo = value),
              onReviewed: (reviewed) {
                update(() {
                  note.text = appendReviewedInput(note.text, reviewed.text);
                  for (final field in reviewed.fields.entries) {
                    final controller = values[field.key];
                    if (controller != null && controller.text.trim().isEmpty) {
                      controller.text = field.value;
                    }
                  }
                });
                fieldsKey.currentState?.revealPopulatedDetails();
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.mic_none),
              label: Text(context.tr('음성으로 입력')),
              onPressed: () async {
                final reviewed = await reviewRecordInput(
                  context,
                  c,
                  pid,
                  kind: kind,
                  currentFields: {
                    for (final e in values.entries) e.key: e.value.text,
                  },
                );
                if (context.mounted &&
                    reviewed != null &&
                    c.unlocked &&
                    c.selectedId == pid) {
                  await attempt(context, () async {
                    final combined = appendReviewedInput(
                      note.text,
                      reviewed.text,
                    );
                    update(() {
                      note.text = combined;
                      for (final field in reviewed.fields.entries) {
                        final controller = values[field.key];
                        if (controller != null &&
                            controller.text.trim().isEmpty) {
                          controller.text = field.value;
                        }
                      }
                    });
                    fieldsKey.currentState?.revealPopulatedDetails();
                  });
                }
              },
            ),
            if (kind == EntryKind.handoff)
              Text(context.tr('다음에 돌볼 사람에게 전할 내용과 확인할 일을 적어요.')),
            dateButton(context, at, update, (v) => at = v),
            if (kind.fields.isNotEmpty)
              RecordFields(key: fieldsKey, kind: kind, values: values),
            textField(
              note,
              kind == EntryKind.generalNote
                  ? context.tr('메모 *')
                  : context.tr('추가 메모'),
              multiline: true,
            ),
            if (kind == EntryKind.medicationIntake)
              Text(
                context.tr(
                  '실제 있었던 복용 상태를 기록해 주세요. 처방 변경은 약 목록에서 따로 기록할 수 있습니다.',
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
    note.dispose();
    for (final value in values.values) {
      value.dispose();
    }
  }
  c.draftsChanged();
}
