import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../application/draft_session.dart';
import '../domain/drafts.dart';
import '../domain/records.dart';
import 'common.dart';
import 'draft_support.dart';

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
  final data = restored?.values;
  final note = TextEditingController(
    text: data?['note'] as String? ?? entry?.note,
  );
  final values = {
    for (final field in kind.fields)
      field.key: TextEditingController(
        text:
            (data?['fields'] as Map?)?[field.key] as String? ??
            entry?.fields[field.key],
      ),
  };
  var at = data?['at'] == null
      ? entry?.occurredAt ?? DateTime.now()
      : DateTime.fromMillisecondsSinceEpoch(data!['at'] as int);
  final draft = DraftSession(
    c,
    patientId: pid,
    type: DraftType.entry,
    targetId: entry?.id,
    restored: restored,
    snapshot: () => {
      'kind': kind.name,
      'note': note.text,
      'at': at.millisecondsSinceEpoch,
      'fields': {for (final e in values.entries) e.key: e.value.text},
    },
  );
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (ctx) => EditorPage(
          title: '${kind.label} ${entry == null ? '기록' : '수정'}',
          draft: draft,
          content: (update) => [
            Text(
              '${c.patient.label} · 직접 작성한 기록',
              style: const TextStyle(color: forest),
            ),
            dateButton(ctx, at, update, (v) => at = v),
            for (final f in kind.fields)
              if (f.choices.isEmpty)
                textField(
                  values[f.key]!,
                  '${f.label}${f.required ? ' *' : ''}',
                  numeric: f.numeric,
                  multiline: f.key == 'instruction',
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: values[f.key]!.text.isEmpty
                      ? null
                      : values[f.key]!.text,
                  decoration: InputDecoration(
                    labelText: '${f.label}${f.required ? ' *' : ''}',
                  ),
                  items: [
                    if (!f.required)
                      const DropdownMenuItem(value: '', child: Text('선택하지 않음')),
                    ...f.choices.entries.map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ),
                  ],
                  onChanged: (v) => values[f.key]!.text = v ?? '',
                ),
            textField(
              note,
              kind == EntryKind.generalNote ? '메모 *' : '추가 메모',
              multiline: true,
            ),
            if (kind == EntryKind.medicationIntake)
              const Text('실제 있었던 복용 상태를 기록해 주세요. 처방 변경은 약 목록에서 따로 기록할 수 있습니다.'),
            const Text(
              '사진은 저장 후 기록 상세에서 추가할 수 있어요.',
              style: TextStyle(color: Color(0xFF66766E)),
            ),
          ],
          save: () async {
            await draft.complete(
              () => c.db.saveEntry(
                pid,
                id: entry?.id,
                expectedVersion: entry?.version,
                kind: kind,
                occurredAt: at,
                note: note.text,
                fields: {for (final e in values.entries) e.key: e.value.text},
              ),
            );
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

Future<void> editPatient(
  BuildContext context,
  CareController c, {
  Patient? patient,
}) async {
  final alias = TextEditingController(text: patient?.alias),
      details = TextEditingController(text: patient?.context),
      contact = TextEditingController(text: patient?.contact);
  var role = patient?.role ?? 'family';
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (_) => EditorPage(
          title: patient == null ? '수첩 추가' : '돌봄 대상 수정',
          content: (update) => [
            const Text('이름 없이 시작해도 괜찮아요. 여러 사람을 돌본다면 구분하기 쉬운 별칭을 적어 주세요.'),
            textField(alias, '이름 또는 별칭 (선택)'),
            DropdownButtonFormField<String>(
              initialValue: role,
              decoration: const InputDecoration(labelText: '나는 어떤 역할인가요?'),
              items: const [
                DropdownMenuItem(value: 'self', child: Text('환자 본인')),
                DropdownMenuItem(value: 'family', child: Text('가족')),
                DropdownMenuItem(value: 'cohabitant', child: Text('동거인')),
                DropdownMenuItem(value: 'caregiver', child: Text('간병인')),
              ],
              onChanged: (v) => role = v!,
            ),
            textField(
              details,
              '돌봄에 필요한 배경 (선택)',
              multiline: true,
              hint: '알레르기, 생활 습관, 의료진에게 전달받은 주의사항 등',
            ),
            textField(contact, '의료기관 연락처 (선택)'),
          ],
          save: () async {
            if (patient == null) {
              final created = await c.mutate(
                () => c.db.createPatient(
                  alias: alias.text,
                  role: role,
                  context: details.text,
                  contact: contact.text,
                ),
              );
              await c.selectPatient(created.id);
            } else {
              await c.mutate(
                () => c.db.updatePatient(
                  patient.id,
                  alias: alias.text,
                  role: role,
                  context: details.text,
                  contact: contact.text,
                ),
              );
            }
          },
        ),
      ),
    );
  } finally {
    alias.dispose();
    details.dispose();
    contact.dispose();
  }
}

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
  final data = restored?.values;
  final pid = c.selectedId!,
      name = TextEditingController(
        text: data?['name'] as String? ?? medication?.name,
      ),
      instruction = TextEditingController(
        text: data?['instruction'] as String? ?? medication?.instruction,
      ),
      times = TextEditingController(
        text: data?['times'] as String? ?? medication?.times.join(', '),
      );
  final draft = DraftSession(
    c,
    patientId: pid,
    type: DraftType.medication,
    targetId: medication?.id,
    restored: restored,
    snapshot: () => {
      'name': name.text,
      'instruction': instruction.text,
      'times': times.text,
    },
  );
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (_) => EditorPage(
          title: medication == null ? '약 추가' : '처방 지시 기록',
          draft: draft,
          content: (_) => [
            textField(name, '약 이름 *'),
            textField(instruction, '의료진의 처방·복용 지시 원문', multiline: true),
            textField(times, '매일 확인할 시각 (선택)', hint: '08:00, 18:00'),
            const Text(
              '전달받은 지시를 그대로 옮겨 적어 주세요. 변경 전 지시와 당시의 복약 기록은 이력에 남습니다. 알림은 설정에서 켤 수 있어요.',
            ),
          ],
          save: () async {
            await draft.complete(
              () => c.db.saveMedication(
                pid,
                id: medication?.id,
                expectedVersion: medication?.version,
                name: name.text,
                instruction: instruction.text,
                times: times.text
                    .split(',')
                    .map((t) => t.trim())
                    .where((t) => t.isNotEmpty)
                    .toList(),
              ),
            );
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
  final data = restored?.values;
  final pid = c.selectedId!,
      reason = TextEditingController(text: data?['reason'] as String?),
      reaction = TextEditingController(text: data?['reaction'] as String?);
  var status = data?['status'] as String? ?? 'taken';
  var at = data?['at'] == null
      ? DateTime.now()
      : DateTime.fromMillisecondsSinceEpoch(data!['at'] as int);
  final draft = DraftSession(
    c,
    patientId: pid,
    type: DraftType.intake,
    targetId: medication.id,
    restored: restored,
    snapshot: () => {
      'status': status,
      'at': at.millisecondsSinceEpoch,
      'reason': reason.text,
      'reaction': reaction.text,
    },
  );
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (ctx) => EditorPage(
          title: '복약 기록',
          draft: draft,
          content: (update) => [
            Text(medication.name, style: Theme.of(ctx).textTheme.headlineSmall),
            if (medication.instruction.isNotEmpty) Text(medication.instruction),
            dateButton(ctx, at, update, (v) => at = v),
            DropdownButtonFormField<String>(
              initialValue: status,
              decoration: const InputDecoration(labelText: '실제 복용 상태'),
              items: intakeLabels.entries
                  .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  )
                  .toList(),
              onChanged: (v) => status = v!,
            ),
            textField(reason, '누락·거부 이유 (선택)'),
            textField(reaction, '관찰한 반응 (선택)', multiline: true),
          ],
          save: () async {
            await draft.complete(
              () => c.db.recordIntake(
                pid,
                medication.id,
                status,
                at,
                reason: reason.text,
                reaction: reaction.text,
              ),
            );
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
  final data = restored?.values;
  final pid = c.selectedId!,
      title = TextEditingController(
        text: data?['title'] as String? ?? task?.title,
      ),
      note = TextEditingController(
        text: data?['note'] as String? ?? task?.note,
      );
  var at = data?['at'] == null
      ? task?.dueAt ?? DateTime.now().add(const Duration(hours: 1))
      : DateTime.fromMillisecondsSinceEpoch(data!['at'] as int);
  var reminder = data?['reminder'] as bool? ?? task?.reminder ?? false;
  final draft = DraftSession(
    c,
    patientId: pid,
    type: DraftType.task,
    targetId: task?.id,
    restored: restored,
    snapshot: () => {
      'title': title.text,
      'note': note.text,
      'at': at.millisecondsSinceEpoch,
      'reminder': reminder,
    },
  );
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (ctx) => EditorPage(
          title: task == null ? '할 일 추가' : '할 일 수정',
          draft: draft,
          content: (update) => [
            textField(title, '할 일 *'),
            dateButton(ctx, at, update, (v) => at = v),
            textField(note, '메모', multiline: true),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('일정 알림'),
              subtitle: Text(
                c.notificationsEnabled
                    ? '기기 상태에 따라 알림 시각이 늦어질 수 있어요.'
                    : '설정에서 알림을 켜면 예약됩니다.',
              ),
              value: reminder,
              onChanged: (v) => update(() => reminder = v),
            ),
          ],
          save: () async {
            await draft.complete(
              () => c.db.saveTask(
                pid,
                id: task?.id,
                title: title.text,
                note: note.text,
                dueAt: at,
                reminder: reminder,
              ),
            );
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
  final data = restored?.values;
  final pid = c.selectedId!,
      title = TextEditingController(
        text: data?['title'] as String? ?? visit?.title,
      ),
      questions = TextEditingController(
        text:
            data?['questions'] as String? ??
            visit?.questions ??
            initialQuestions,
      );
  final selected = data?['selected'] != null
      ? Set<String>.from(data!['selected'] as List)
      : visit == null
      ? <String>{}
      : c.db.visitEntries(pid, visit.id).map((e) => e.id).toSet();
  final entries = c.entries;
  final availableEntryIds = entries.map((e) => e.id).toSet();
  final draft = DraftSession(
    c,
    patientId: pid,
    type: DraftType.visit,
    targetId: visit?.id,
    restored: restored,
    snapshot: () => {
      'title': title.text,
      'questions': questions.text,
      'selected': selected.toList()..sort(),
    },
  );
  try {
    if (initialQuestions != null) draft.flush(force: true);
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (_) => EditorPage(
          title: visit == null ? '진료 준비' : '진료 준비 검토',
          draft: draft,
          content: (update) => [
            textField(title, '진료 준비 제목 *', hint: '예: 다음 외래에서 확인할 내용'),
            textField(questions, '의료진에게 물어볼 질문', multiline: true),
            const Section('함께 볼 기록'),
            const Text('선택한 원본 기록을 모아 볼 수 있어요. 기록이 바뀌면 다시 확인하도록 표시합니다.'),
            if (selected.any((id) => !availableEntryIds.contains(id))) ...[
              const Text(
                '초안에서 선택했던 원본 중 삭제된 기록이 있어요. 해당 연결을 제외한 뒤 저장할 수 있습니다.',
              ),
              OutlinedButton(
                onPressed: () => update(
                  () => selected.removeWhere(
                    (id) => !availableEntryIds.contains(id),
                  ),
                ),
                child: const Text('삭제된 원본 연결 제외'),
              ),
            ],
            if (entries.isEmpty) const Text('먼저 일기에 기록을 남겨 주세요.'),
            for (final e in entries)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: selected.contains(e.id),
                title: Text('${dateText(e.occurredAt)} ${e.kind.label}'),
                subtitle: Text(
                  e.summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onChanged: (v) => update(
                  () => v == true ? selected.add(e.id) : selected.remove(e.id),
                ),
              ),
          ],
          save: () async {
            await draft.complete(
              () => c.db.saveVisit(
                pid,
                id: visit?.id,
                title: title.text,
                questions: questions.text,
                entryIds: selected.toList(),
              ),
            );
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

Future<void> addCheckin(
  BuildContext context,
  CareController c, {
  CareDraft? restored,
}) async {
  if (!await chooseDraftRetention(context, c, onlyIfUnset: true) ||
      !context.mounted) {
    return;
  }
  final data = restored?.values;
  final fatigue = TextEditingController(text: data?['fatigue'] as String?),
      sleep = TextEditingController(text: data?['sleep'] as String?),
      stress = TextEditingController(text: data?['stress'] as String?),
      note = TextEditingController(text: data?['note'] as String?);
  final draft = DraftSession(
    c,
    patientId: null,
    type: DraftType.checkin,
    restored: restored,
    snapshot: () => {
      'fatigue': fatigue.text,
      'sleep': sleep.text,
      'stress': stress.text,
      'note': note.text,
    },
  );
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (_) => EditorPage(
          title: '돌보는 나의 상태',
          draft: draft,
          content: (_) => [
            const Text('돌봄을 이어가는 내 상태를 적어 보세요. 환자의 일기와 따로 보관됩니다.'),
            textField(fatigue, '피로 정도'),
            textField(sleep, '수면 시간·상태'),
            textField(stress, '스트레스'),
            textField(note, '내게 필요한 도움·메모', multiline: true),
          ],
          save: () async {
            if ([
              fatigue,
              sleep,
              stress,
              note,
            ].every((c) => c.text.trim().isEmpty)) {
              throw const CareError('내 상태를 한 가지 이상 적어 주세요.');
            }
            await draft.complete(
              () => c.db.addCheckin(
                fatigue: fatigue.text,
                sleep: sleep.text,
                stress: stress.text,
                note: note.text,
              ),
            );
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
