import '../l10n/app_strings.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../application/care_controller.dart';

import 'common.dart';
import 'editors.dart';

class EntryDetails extends StatelessWidget {
  const EntryDetails(this.c, this.pid, this.id, {super.key});
  final CareController c;
  final String pid, id;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      if (!c.unlocked) {
        return const SizedBox.shrink();
      }
      final e = c.db.entry(pid, id);
      if (e == null) {
        return Scaffold(
          appBar: AppBar(),
          body: Center(child: Text(context.tr('삭제된 기록입니다.'))),
        );
      }
      final attachments = c.db.attachments(pid, id);
      return Scaffold(
        appBar: AppBar(
          title: Text(context.tr(e.kind.label)),
          actions: [
            IconButton(
              tooltip: context.tr('기록 수정'),
              onPressed: () => editEntry(context, c, e.kind, entry: e),
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              '${dateText(context, e.occurredAt)} ${timeText(context, e.occurredAt)}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              context.tr('직접 작성 · 수정 버전 {0}', [e.version]),
              style: const TextStyle(color: forest),
            ),
            const SizedBox(height: 16),
            for (final field in e.kind.fields)
              if ((e.fields[field.key] ?? '').isNotEmpty)
                Card(
                  child: ListTile(
                    title: Text(
                      context.tr(field.label),
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF68796E),
                      ),
                    ),
                    subtitle: SelectableText(
                      context.strings.fieldValue(field, e.fields[field.key]!),
                      style: const TextStyle(fontSize: 16, color: ink),
                    ),
                  ),
                ),
            if (e.note.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: SelectableText(
                    e.note,
                    style: const TextStyle(height: 1.6),
                  ),
                ),
              ),
            Section(context.tr('사진')),
            Text(
              context.tr('음식·처방자료 등을 첨부하세요. 사진 위치 정보는 제거하고 암호화해 저장합니다.'),
              style: TextStyle(height: 1.5, color: Color(0xFF68796E)),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => attempt(context, () => c.addPhoto(pid, id)),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(context.tr('사진 선택')),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      attempt(context, () => c.addPhoto(pid, id, camera: true)),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: Text(context.tr('촬영')),
                ),
              ],
            ),
            for (final a in attachments)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.photo_outlined, color: forest),
                  title: Text(context.tr('첨부 사진')),
                  subtitle: Text('${(a.bytes / 1024).ceil()} KB'),
                  onTap: () {
                    final photo = c.photo(pid, id, a.id);
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(builder: (_) => PhotoPage(photo)),
                    );
                  },
                  trailing: IconButton(
                    tooltip: context.tr('사진 삭제'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (await confirm(
                            context,
                            context.tr('사진을 삭제할까요?'),
                            context.tr('이 기록에 저장된 사진을 삭제합니다.'),
                          ) &&
                          context.mounted) {
                        await attempt(context, () async {
                          await c.mutate(
                            () => c.db.deleteAttachment(pid, a.id),
                          );
                        });
                      }
                    },
                  ),
                ),
              ),
            if (e.version > 1)
              ExpansionTile(
                title: Text(context.tr('수정 전 기록')),
                children: c.db.revisions(pid, id).map((r) {
                  final snapshot = r;
                  final fields = Map<String, dynamic>.from(
                    snapshot['fields'] as Map,
                  );
                  return ListTile(
                    title: Text(context.tr('버전 {0}', [r['version']])),
                    subtitle: Text(
                      [
                        ...e.kind.fields
                            .where((f) => (fields[f.key] ?? '') != '')
                            .map(
                              (f) =>
                                  '${context.tr(f.label)}: ${context.strings.fieldValue(f, fields[f.key] as String)}',
                            ),
                        snapshot['note'] ?? '',
                      ].join('\n'),
                    ),
                  );
                }).toList(),
              ),
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: () async {
                if (await confirm(
                      context,
                      context.tr('기록을 삭제할까요?'),
                      context.tr(
                        '이 기록의 수정 이력과 첨부 사진도 삭제됩니다. 진료 준비 목록에서도 빠집니다.',
                      ),
                    ) &&
                    context.mounted) {
                  await attempt(context, () async {
                    await c.mutate(() => c.db.deleteEntry(pid, id));
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  });
                }
              },
              icon: const Icon(Icons.delete_outline),
              label: Text(context.tr('기록 삭제')),
            ),
          ],
        ),
      );
    },
  );
}

class PhotoPage extends StatelessWidget {
  const PhotoPage(this.photo, {super.key});
  final Future<Uint8List> photo;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('첨부 사진'))),
    body: FutureBuilder<Uint8List>(
      future: photo,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text(context.tr('사진을 열 수 없습니다.')));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return Center(
          child: InteractiveViewer(
            maxScale: 8,
            child: Image.memory(snapshot.data!, gaplessPlayback: false),
          ),
        );
      },
    ),
  );
}

class MedicationDetails extends StatelessWidget {
  const MedicationDetails(this.c, this.pid, this.id, {super.key});
  final CareController c;
  final String pid, id;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      if (!c.unlocked) {
        return const SizedBox.shrink();
      }
      final med = c.db
          .medications(pid, includeArchived: true)
          .firstWhere((m) => m.id == id);
      final plans = c.db.medicationPlans(pid, id);
      return Scaffold(
        appBar: AppBar(title: Text(med.name)),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              med.instruction.isEmpty
                  ? context.tr('기록된 지시가 없습니다.')
                  : med.instruction,
              style: const TextStyle(fontSize: 18, height: 1.6),
            ),
            const SizedBox(height: 12),
            Text(med.times.join(' · ')),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => recordIntake(context, c, med),
              icon: const Icon(Icons.add_task),
              label: Text(context.tr('실제 복약 기록')),
            ),
            OutlinedButton(
              onPressed: () => editMedication(context, c, medication: med),
              child: Text(context.tr('처방 지시 수정 기록')),
            ),
            Section(context.tr('처방 지시 이력')),
            ...plans.map(
              (p) => Card(
                child: ListTile(
                  title: Text(
                    p['status'] == 'active'
                        ? context.tr('현재 기록된 지시')
                        : context.tr('이전 지시'),
                  ),
                  subtitle: Text(
                    '${dateText(context, DateTime.fromMillisecondsSinceEpoch(p['created_at'] as int))}\n${p['name']}\n${p['instruction']}\n${(jsonDecode(p['times'] as String) as List).join(' · ')}',
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            TextButton(
              onPressed: () async {
                if (await confirm(
                      context,
                      med.active
                          ? context.tr('목록에서 보관할까요?')
                          : context.tr('다시 목록에 표시할까요?'),
                      med.active
                          ? context.tr(
                              '기존 복약 이력은 유지하고 이 약의 앱 알림을 끕니다. 약을 중단하라는 의미가 아닙니다.',
                            )
                          : context.tr('저장된 시각에 따라 앱 알림을 다시 예약합니다.'),
                      action: med.active ? context.tr('보관') : context.tr('표시'),
                    ) &&
                    context.mounted) {
                  await attempt(context, () async {
                    await c.mutate(
                      () => c.db.archiveMedication(pid, id, med.active),
                    );
                  });
                }
              },
              child: Text(
                med.active ? context.tr('목록에서 보관') : context.tr('목록에 다시 표시'),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class VisitDetails extends StatelessWidget {
  const VisitDetails(this.c, this.pid, this.id, {super.key});
  final CareController c;
  final String pid, id;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      if (!c.unlocked) {
        return const SizedBox.shrink();
      }
      final v = c.db.visits(pid).where((v) => v.id == id).firstOrNull;
      if (v == null) {
        return Scaffold(
          appBar: AppBar(),
          body: Center(child: Text(context.tr('삭제된 진료 준비입니다.'))),
        );
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(v.title),
          actions: [
            IconButton(
              tooltip: context.tr('진료 준비 검토'),
              onPressed: () => editVisit(context, c, visit: v),
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (v.stale)
              Card(
                color: Color(0xFFFFF1DB),
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    context.tr('선택한 원본 기록이 변경되었어요. 수정 화면에서 다시 검토하고 저장해 주세요.'),
                  ),
                ),
              ),
            Section(context.tr('물어볼 질문')),
            SelectableText(
              v.questions.isEmpty
                  ? context.tr('아직 적어둔 질문이 없습니다.')
                  : v.questions,
              style: const TextStyle(fontSize: 17, height: 1.6),
            ),
            Section(context.tr('함께 볼 원본 기록')),
            ...c.db
                .visitEntries(pid, id)
                .map(
                  (e) => EntryTile(
                    e,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => EntryDetails(c, pid, e.id),
                      ),
                    ),
                  ),
                ),
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: () async {
                if (await confirm(
                      context,
                      context.tr('진료 준비를 삭제할까요?'),
                      context.tr('원본 일기 기록은 그대로 남습니다.'),
                    ) &&
                    context.mounted) {
                  await attempt(context, () async {
                    await c.mutate(() => c.db.deleteVisit(pid, id));
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  });
                }
              },
              icon: const Icon(Icons.delete_outline),
              label: Text(context.tr('진료 준비 삭제')),
            ),
          ],
        ),
      );
    },
  );
}
