import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../application/care_controller.dart';
import '../../application/draft_session.dart';
import '../../domain/drafts.dart';
import '../../domain/records.dart';
import '../common.dart';
import '../draft_support.dart';

Future<void> editVisit(
  BuildContext context,
  CareController c, {
  VisitPreparation? visit,
  String? initialQuestions,
  CareDraft? restored,
}) async {
  if (!await chooseDraftRetention(context, c, onlyIfUnset: true) ||
      !context.mounted) {
    return;
  }
  final data = restored?.payload as VisitDraftPayload?;
  final pid = c.selectedId!,
      title = TextEditingController(text: data?.title ?? visit?.title),
      questions = TextEditingController(
        text: data?.questions ?? visit?.questions ?? initialQuestions,
      );
  final selected = data != null
      ? data.selected.toSet()
      : visit == null
      ? <String>{}
      : c.visitBook.visitEntries(pid, visit.id).map((e) => e.id).toSet();
  final entries = c.entries;
  final availableEntryIds = entries.map((e) => e.id).toSet();
  final draft = DraftSession(
    c,
    patientId: pid,
    type: DraftType.visit,
    targetId: visit?.id,
    restored: restored,
    snapshot: () => VisitDraftPayload(
      title: title.text,
      questions: questions.text,
      selected: (selected.toList()..sort()),
    ),
  );
  try {
    if (initialQuestions != null) draft.flush(force: true);
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (_) => EditorPage(
          title: visit == null ? context.tr('진료 준비') : context.tr('진료 준비 검토'),
          draft: draft,
          content: (update) => [
            textField(
              title,
              context.tr('진료 준비 제목 *'),
              hint: context.tr('예: 다음 외래에서 확인할 내용'),
            ),
            textField(questions, context.tr('의료진에게 물어볼 질문'), multiline: true),
            Section(context.tr('함께 볼 기록')),
            Text(context.tr('선택한 원본 기록을 모아 볼 수 있어요. 기록이 바뀌면 다시 확인하도록 표시합니다.')),
            if (selected.any((id) => !availableEntryIds.contains(id))) ...[
              Text(
                context.tr(
                  '초안에서 선택했던 원본 중 삭제된 기록이 있어요. 해당 연결을 제외한 뒤 저장할 수 있습니다.',
                ),
              ),
              OutlinedButton(
                onPressed: () => update(
                  () => selected.removeWhere(
                    (id) => !availableEntryIds.contains(id),
                  ),
                ),
                child: Text(context.tr('삭제된 원본 연결 제외')),
              ),
            ],
            if (entries.isEmpty) Text(context.tr('먼저 일기에 기록을 남겨 주세요.')),
            for (final e in entries)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: selected.contains(e.id),
                title: Text(
                  '${dateText(context, e.occurredAt)} ${context.tr(e.kind.label)}',
                ),
                subtitle: Text(
                  context.strings.summary(e),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onChanged: (v) => update(
                  () => v == true ? selected.add(e.id) : selected.remove(e.id),
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
    title.dispose();
    questions.dispose();
  }
  c.draftsChanged();
}
