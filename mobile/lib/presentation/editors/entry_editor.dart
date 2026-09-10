import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../application/care_controller.dart';
import '../../application/draft_session.dart';
import '../../domain/drafts.dart';
import '../../domain/records.dart';
import '../common.dart';
import '../draft_support.dart';

Future<void> editEntry(
  BuildContext context,
  CareController c,
  EntryKind kind, {
  CareEntry? entry,
  CareDraft? restored,
}) async {
  if (!await chooseDraftRetention(context, c, onlyIfUnset: true) ||
      !context.mounted) {
    return;
  }
  final pid = c.selectedId!;
  final data = restored?.payload as EntryDraftPayload?;
  final note = TextEditingController(text: data?.note ?? entry?.note);
  final values = {
    for (final field in kind.fields)
      field.key: TextEditingController(
        text: data?.fields[field.key] ?? entry?.fields[field.key],
      ),
  };
  var at = data?.at ?? entry?.occurredAt ?? DateTime.now();
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
          content: (update) => [
            Text(
              context.tr('{0} · 직접 작성한 기록', [
                context.strings.patient(c.patient),
              ]),
              style: const TextStyle(color: forest),
            ),
            dateButton(context, at, update, (v) => at = v),
            for (final f in kind.fields)
              if (f.choices.isEmpty)
                textField(
                  values[f.key]!,
                  '${context.tr(f.label)}${f.required ? ' *' : ''}',
                  numeric: f.numeric,
                  multiline: f.key == 'instruction',
                )
              else
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  itemHeight: null,
                  initialValue: values[f.key]!.text.isEmpty
                      ? null
                      : values[f.key]!.text,
                  decoration: InputDecoration(
                    labelText:
                        '${context.tr(f.label)}${f.required ? ' *' : ''}',
                  ),
                  items: [
                    if (!f.required)
                      DropdownMenuItem(
                        value: '',
                        child: Text(context.tr('선택하지 않음')),
                      ),
                    ...f.choices.entries.map(
                      (e) => DropdownMenuItem(
                        value: e.key,
                        child: Text(context.tr(e.value)),
                      ),
                    ),
                  ],
                  onChanged: (v) => values[f.key]!.text = v ?? '',
                ),
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
            Text(
              context.tr('사진은 저장 후 기록 상세에서 추가할 수 있어요.'),
              style: TextStyle(color: Color(0xFF66766E)),
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
    note.dispose();
    for (final value in values.values) {
      value.dispose();
    }
  }
  c.draftsChanged();
}
