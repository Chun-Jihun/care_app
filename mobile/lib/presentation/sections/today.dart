import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../application/care_controller.dart';
import '../../domain/records.dart';
import '../common.dart';
import '../settings.dart' show contactCard;
import '../editors.dart';

List<Widget> todayContent(
  BuildContext context,
  CareController c,
  void Function(CareEntry) openEntry,
) {
  final now = DateTime.now();
  final entries = c.records.entries(c.selectedId!, day: now);
  final recent = c.records.entries(c.selectedId!, limit: 5);
  final tasks = c.tasks;
  final water = entries
      .where((e) => e.kind == EntryKind.meal)
      .fold<double>(
        0,
        (sum, e) => sum + (double.tryParse(e.fields['water_ml'] ?? '') ?? 0),
      );
  final taken = entries
      .where(
        (e) =>
            e.kind == EntryKind.medicationIntake &&
            e.fields['status'] == 'taken',
      )
      .length;
  return [
    Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.strings.day(now),
            style: const TextStyle(color: Color(0xFF68796E)),
          ),
          const SizedBox(height: 8),
          Text(
            context.tr('오늘의 돌봄'),
            style: Theme.of(context).textTheme.headlineLarge
                ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1),
          ),
        ],
      ),
    ),
    Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: forest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.spa_outlined, color: Color(0xFFBDDAB9)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.tr('차곡차곡, 오늘의 기록'),
                  style: TextStyle(color: Color(0xFFD5E8CE)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            entries.isEmpty
                ? context.tr('작은 변화부터\n편하게 남겨 보세요.')
                : context.tr('오늘 {0}개의 기록을\n차곡차곡 남겼어요.', [entries.length]),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 25,
              height: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: _stat(
                  context.tr('수분 기록'),
                  '${water.toStringAsFixed(water % 1 == 0 ? 0 : 1)} mL',
                ),
              ),
              Container(width: 1, height: 42, color: Colors.white24),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: _stat(
                    context.tr('복용함 기록'),
                    context.tr('{0}건', [taken]),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            context.tr('입력된 기록의 합계입니다.'),
            style: TextStyle(color: Color(0xFFD5E8CE), fontSize: 12),
          ),
        ],
      ),
    ),
    Section(context.tr('빠르게 남기기')),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children:
          [
                EntryKind.meal,
                EntryKind.medicationIntake,
                EntryKind.symptom,
                EntryKind.activity,
              ]
              .map(
                (k) => ActionChip(
                  avatar: Icon(kindIcon(k), size: 18, color: forest),
                  label: Text(context.tr(k.label)),
                  onPressed: () => editEntry(context, c, k),
                ),
              )
              .toList(),
    ),
    Section(
      context.tr('할 일'),
      action: context.tr('추가'),
      onAction: () => editTask(context, c),
    ),
    if (tasks.isEmpty)
      EmptyCard(
        context.tr('기억할 일을 적어 두세요'),
        context.tr('진료 일정, 준비물, 생활 속 할 일을 관리할 수 있어요.'),
        icon: Icons.check_circle_outline,
      ),
    ...tasks.map((task) => _taskCard(context, c, task)),
    Section(context.tr('최근 기록')),
    if (recent.isEmpty)
      EmptyCard(
        context.tr('첫 기록을 기다리고 있어요'),
        context.tr('아래 기록하기를 눌러 식사나 오늘의 상태를 남겨 보세요.'),
      ),
    ...recent.map((e) => EntryTile(e, onTap: () => openEntry(e))),
    Section(context.tr('연락이 필요할 때')),
    contactCard(context, c),
  ];
}

Widget _stat(String label, String value) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(label, style: const TextStyle(color: Color(0xFFD5E8CE), fontSize: 12)),
    const SizedBox(height: 4),
    Text(
      value,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 23,
        fontWeight: FontWeight.w700,
      ),
    ),
  ],
);
Widget _taskCard(BuildContext context, CareController c, CareTask task) => Card(
  child: ListTile(
    leading: Semantics(
      label: context.tr('{0} 완료', [task.title]),
      child: Checkbox(
        value: task.done,
        onChanged: (v) => attempt(context, () async {
          await c.taskBook.completeTask(c.selectedId!, task.id, v!);
        }),
      ),
    ),
    title: Text(
      task.title,
      style: TextStyle(
        decoration: task.done ? TextDecoration.lineThrough : null,
      ),
    ),
    subtitle: Text(
      '${dateText(context, task.dueAt)} ${timeText(context, task.dueAt)}${task.reminder ? context.tr(' · 알림') : ''}${task.note.isEmpty ? '' : '\n${task.note}'}',
    ),
    onTap: () => editTask(context, c, task: task),
    trailing: IconButton(
      tooltip: context.tr('할 일 삭제'),
      icon: const Icon(Icons.close, size: 19),
      onPressed: () async {
        if (await confirm(context, context.tr('할 일을 삭제할까요?'), task.title) &&
            context.mounted) {
          await attempt(context, () async {
            await c.taskBook.deleteTask(c.selectedId!, task.id);
          });
        }
      },
    ),
  ),
);
