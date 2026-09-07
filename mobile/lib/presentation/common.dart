import 'package:flutter/material.dart';

import '../domain/records.dart';

const forest = Color(0xFF22664E);
const ink = Color(0xFF223B32);
Future<T?> pushPage<T>(BuildContext context, MaterialPageRoute<T> route) async {
  final value = await Navigator.of(context).push<T>(route);
  await route.completed;
  return value;
}

String dateText(DateTime at) =>
    '${at.year}.${at.month.toString().padLeft(2, '0')}.${at.day.toString().padLeft(2, '0')}';
String timeText(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
String errorText(Object error) => error is CareError
    ? error.message
    : '작업을 완료하지 못했습니다. 입력 내용과 기기 저장 공간을 확인하고 다시 시도해 주세요.';

Future<void> attempt(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (context.mounted && success != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(success)));
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(errorText(error))));
    }
  }
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  String action = '삭제',
}) async =>
    await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
Future<DateTime?> chooseDateTime(BuildContext context, DateTime value) async {
  final date = await showDatePicker(
    context: context,
    useRootNavigator: false,
    initialDate: value,
    firstDate: DateTime(2000),
    lastDate: DateTime(2100),
  );
  if (date == null || !context.mounted) {
    return null;
  }
  final time = await showTimePicker(
    context: context,
    useRootNavigator: false,
    initialTime: TimeOfDay.fromDateTime(value),
  );
  return time == null
      ? null
      : DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

IconData kindIcon(EntryKind kind) => switch (kind) {
  EntryKind.meal => Icons.restaurant_rounded,
  EntryKind.medicationIntake => Icons.medication_outlined,
  EntryKind.symptom => Icons.monitor_heart_outlined,
  EntryKind.activity => Icons.directions_walk_rounded,
  EntryKind.measurement => Icons.straighten_rounded,
  EntryKind.dailyLiving => Icons.wb_sunny_outlined,
  EntryKind.incident => Icons.report_outlined,
  EntryKind.medicalContact => Icons.local_hospital_outlined,
  EntryKind.handoff => Icons.assignment_ind_outlined,
  EntryKind.generalNote => Icons.edit_note_rounded,
};

class Section extends StatelessWidget {
  const Section(this.title, {super.key, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        if (action != null)
          TextButton(onPressed: onAction, child: Text(action!)),
      ],
    ),
  );
}

class EmptyCard extends StatelessWidget {
  const EmptyCard(
    this.title,
    this.body, {
    super.key,
    this.icon = Icons.auto_stories_outlined,
  });
  final String title, body;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: forest, size: 30),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            body,
            style: const TextStyle(color: Color(0xFF66766E), height: 1.6),
          ),
        ],
      ),
    ),
  );
}

class EntryTile extends StatelessWidget {
  const EntryTile(this.entry, {super.key, required this.onTap});
  final CareEntry entry;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: CircleAvatar(
        backgroundColor: const Color(0xFFE8EFE8),
        foregroundColor: forest,
        child: Icon(kindIcon(entry.kind)),
      ),
      title: Text(entry.kind.label),
      subtitle: Text(
        '${dateText(entry.occurredAt)} ${timeText(entry.occurredAt)}\n${entry.summary}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    ),
  );
}

class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.title,
    required this.content,
    required this.save,
    this.saveLabel = '저장',
  });
  final String title, saveLabel;
  final List<Widget> Function(StateSetter setState) content;
  final Future<void> Function() save;
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  bool saving = false;
  String? error;
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: AbsorbPointer(
        absorbing: saving,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            ...widget
                .content(setState)
                .expand((w) => [w, const SizedBox(height: 16)]),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            FilledButton(
              onPressed: () async {
                if (saving) {
                  return;
                }
                setState(() {
                  saving = true;
                  error = null;
                });
                try {
                  await widget.save();
                  if (context.mounted) {
                    Navigator.pop(context);
                  }
                } catch (e) {
                  if (mounted) {
                    setState(() {
                      saving = false;
                      error = errorText(e);
                    });
                  }
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(widget.saveLabel),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget textField(
  TextEditingController controller,
  String label, {
  bool multiline = false,
  bool numeric = false,
  bool secret = false,
  String? hint,
}) => TextField(
  controller: controller,
  decoration: InputDecoration(
    labelText: label,
    hintText: hint,
    alignLabelWithHint: multiline,
  ),
  minLines: multiline ? 3 : 1,
  maxLines: multiline ? 6 : 1,
  keyboardType: secret
      ? TextInputType.visiblePassword
      : numeric
      ? const TextInputType.numberWithOptions(decimal: true)
      : multiline
      ? TextInputType.multiline
      : TextInputType.text,
  obscureText: secret,
  autocorrect: false,
  enableSuggestions: false,
);
Widget dateButton(
  BuildContext context,
  DateTime date,
  StateSetter update,
  void Function(DateTime) change,
) => OutlinedButton.icon(
  onPressed: () async {
    final selected = await chooseDateTime(context, date);
    if (selected != null && context.mounted) {
      update(() => change(selected));
    }
  },
  icon: const Icon(Icons.calendar_today_outlined),
  label: Padding(
    padding: const EdgeInsets.all(12),
    child: Text('${dateText(date)}  ${timeText(date)}'),
  ),
);
