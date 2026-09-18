import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/records.dart';
import '../l10n/app_strings.dart';
import 'common.dart';
import 'editors.dart';

class TaskOverview extends StatelessWidget {
  const TaskOverview(this.c, {super.key});
  final CareController c;
  @override
  Widget build(BuildContext context) {
    final pending = c.tasks.where((t) => !t.done).toList();
    return Column(
      children: [
        if (pending.isEmpty)
          EmptyCard(
            context.tr('기억할 일을 적어 두세요'),
            context.tr('진료 일정, 준비물, 생활 속 할 일을 관리할 수 있어요.'),
            icon: Icons.check_circle_outline,
          ),
        ...pending.take(5).map((task) => TaskCard(c, c.selectedId!, task)),
        if (c.tasks.isNotEmpty)
          OutlinedButton.icon(
            onPressed: () => pushPage(
              context,
              MaterialPageRoute<void>(
                builder: (_) => TaskListPage(c, c.selectedId!),
              ),
            ),
            icon: const Icon(Icons.checklist),
            label: Text(context.tr('모든 할 일 · 미완료 {0}개', [pending.length])),
          ),
      ],
    );
  }
}

class TaskListPage extends StatefulWidget {
  const TaskListPage(this.c, this.pid, {super.key});
  final CareController c;
  final String pid;
  @override
  State<TaskListPage> createState() => _TaskListPageState();
}

class _TaskListPageState extends State<TaskListPage> {
  bool completed = false;
  int limit = 50;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.c,
    builder: (context, _) {
      final c = widget.c;
      if (!c.unlocked || c.selectedId != widget.pid) {
        return const SizedBox.shrink();
      }
      final tasks = c.tasks.where((t) => completed || !t.done).toList();
      final shown = tasks.take(limit).toList();
      return Scaffold(
        appBar: AppBar(
          title: Text(context.tr('할 일')),
          actions: [
            IconButton(
              tooltip: context.tr('할 일 추가'),
              onPressed: () => editTask(context, c),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView.builder(
            padding: const EdgeInsets.all(20),
            itemCount: shown.length + 2,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Column(
                  children: [
                    SwitchListTile(
                      title: Text(context.tr('완료한 할 일도 보기')),
                      value: completed,
                      onChanged: (v) => setState(() {
                        completed = v;
                        limit = 50;
                      }),
                    ),
                    if (tasks.isEmpty)
                      Text(context.tr('미완료 할 일이 없어요. 완료한 일은 위에서 확인할 수 있습니다.')),
                  ],
                );
              }
              if (index == shown.length + 1) {
                return tasks.length > limit
                    ? OutlinedButton(
                        onPressed: () => setState(() => limit += 50),
                        child: Text(context.tr('할 일 더 보기')),
                      )
                    : const SizedBox(height: 20);
              }
              return TaskCard(c, widget.pid, shown[index - 1]);
            },
          ),
        ),
      );
    },
  );
}

class TaskCard extends StatelessWidget {
  const TaskCard(this.c, this.pid, this.task, {super.key});
  final CareController c;
  final String pid;
  final CareTask task;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Semantics(
        label: context.tr('{0} 완료', [task.title]),
        child: Checkbox(
          value: task.done,
          onChanged: c.busy
              ? null
              : (v) => attempt(
                  context,
                  () => c.taskBook.completeTask(pid, task.id, v!),
                ),
        ),
      ),
      title: Text(
        task.title,
        style: TextStyle(
          decoration: task.done ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle: Text(
        '${!task.done && task.dueAt.isBefore(DateTime.now()) ? '${context.tr('예정 시각 지남')} · ' : ''}'
        '${dateText(context, task.dueAt)} ${timeText(context, task.dueAt)}${task.reminder ? context.tr(' · 알림') : ''}${task.note.isEmpty ? '' : '\n${task.note}'}',
      ),
      onTap: () => editTask(context, c, task: task),
      trailing: IconButton(
        tooltip: context.tr('할 일 삭제'),
        icon: const Icon(Icons.close, size: 19),
        onPressed: () async {
          if (await confirm(context, context.tr('할 일을 삭제할까요?'), task.title) &&
              context.mounted) {
            await attempt(context, () => c.taskBook.deleteTask(pid, task.id));
          }
        },
      ),
    ),
  );
}
