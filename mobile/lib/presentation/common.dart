import '../l10n/app_strings.dart';
import '../domain/drafts.dart';

import 'package:flutter/material.dart';

import '../domain/records.dart';
import '../application/draft_session.dart';

const forest = Color(0xFF22664E);
const ink = Color(0xFF223B32);
Future<T?> pushPage<T>(BuildContext context, MaterialPageRoute<T> route) async {
  final value = await Navigator.of(context).push<T>(route);
  await route.completed;
  return value;
}

String dateText(BuildContext context, DateTime at) => context.strings.date(at);
String timeText(BuildContext context, DateTime at) => context.strings.time(at);
String errorText(BuildContext context, Object error) =>
    context.strings.error(error);

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
          .showSnackBar(SnackBar(content: Text(errorText(context, error))));
    }
  }
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  String? action,
}) async =>
    await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.tr('취소')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action ?? context.tr('삭제')),
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
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 4,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w700),
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
      title: Text(context.tr(entry.kind.label)),
      subtitle: Text(
        '${dateText(context, entry.occurredAt)} ${timeText(context, entry.occurredAt)}\n${context.strings.summary(entry)}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    ),
  );
}

/// A reviewed multistep action was cancelled; leave its form open quietly.
class EditorCancelled implements Exception {
  const EditorCancelled();
}

class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.title,
    required this.content,
    required this.save,
    this.saveLabel,
    this.draft,
  });
  final String title;
  final String? saveLabel;
  final List<Widget> Function(StateSetter setState) content;
  final Future<void> Function() save;
  final DraftSession? draft;
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  bool saving = false;
  bool dirty = false, leaving = false, confirming = false;
  Object? error;
  @override
  void initState() {
    super.initState();
    dirty = widget.draft?.saved ?? false;
  }

  void changed() {
    setState(() => dirty = true);
    widget.draft?.changed();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving && (!dirty || leaving),
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop || saving || confirming) return;
      confirming = true;
      var leave = false;
      try {
        if (widget.draft case final draft?) {
          final choice = await showDialog<String>(
            context: context,
            useRootNavigator: false,
            builder: (ctx) => AlertDialog(
              title: Text(context.tr('작성 중인 내용을 어떻게 할까요?')),
              content: Text(
                context.tr('초안은 기록으로 확정되지 않아요. 잠금을 해제한 뒤 이어서 작성할 수 있습니다.'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(context.tr('계속 작성')),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'discard'),
                  child: Text(context.tr('초안 삭제')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, 'keep'),
                  child: Text(context.tr('초안 보관 후 나가기')),
                ),
              ],
            ),
          );
          if (!mounted) return;
          if (choice == 'keep') {
            draft.flush(force: true);
            leave = true;
          }
          if (choice == 'discard') {
            await draft.discard();
            leave = true;
          }
        } else {
          leave = await confirm(
            context,
            context.tr('작성을 그만둘까요?'),
            context.tr('아직 저장하지 않은 내용이 있습니다.'),
            action: context.tr('저장하지 않고 나가기'),
          );
        }
      } catch (e) {
        if (mounted) setState(() => error = e);
      } finally {
        confirming = false;
      }
      if (!context.mounted || !leave) return;
      setState(() => leaving = true);
      await WidgetsBinding.instance.endOfFrame;
      if (context.mounted) Navigator.pop(context);
    },
    child: Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: AbsorbPointer(
        absorbing: saving,
        child: Form(
          onChanged: changed,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              if (widget.draft case final draft?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: ValueListenableBuilder<DraftStatus>(
                    valueListenable: draft.status,
                    builder: (_, text, _) => Text(
                      context.strings.draftStatus(text),
                      style: const TextStyle(color: forest),
                    ),
                  ),
                ),
              ...widget
                  .content(
                    (action) => setState(() {
                      action();
                      dirty = true;
                      widget.draft?.changed();
                    }),
                  )
                  .expand((w) => [w, const SizedBox(height: 16)]),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    errorText(context, error!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
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
                      setState(() {
                        saving = false;
                        leaving = true;
                      });
                      Navigator.pop(context);
                    }
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        saving = false;
                        error = e is EditorCancelled ? null : e;
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
                      : Text(widget.saveLabel ?? context.tr('저장')),
                ),
              ),
            ],
          ),
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
}) => TextFormField(
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
  enableIMEPersonalizedLearning: false,
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
    child: Text('${dateText(context, date)}  ${timeText(context, date)}'),
  ),
);
