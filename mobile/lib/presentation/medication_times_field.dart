import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';

/// Retains the legacy draft string until the user explicitly edits a time.
/// Invalid old draft values remain visible and must be corrected or removed.
class MedicationTimesField extends StatefulWidget {
  const MedicationTimesField({
    super.key,
    required this.controller,
    required this.onChanged,
  });
  final TextEditingController controller;
  final VoidCallback onChanged;
  @override
  State<MedicationTimesField> createState() => _MedicationTimesFieldState();
}

class _MedicationTimesFieldState extends State<MedicationTimesField> {
  bool choosing = false;
  String? notice;
  List<String> get times => widget.controller.text
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  TimeOfDay? parse(String value) {
    if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(value)) return null;
    final parts = value.split(':');
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  void write(List<String> next) {
    widget.controller.text = next.join(', ');
    widget.onChanged();
    setState(() => notice = null);
  }

  Future<void> choose([int? index]) async {
    if (choosing) return;
    setState(() => choosing = true);
    final before = times;
    final selected = await showTimePicker(
      context: context,
      useRootNavigator: false,
      initialTime: index == null
          ? TimeOfDay.now()
          : parse(before[index]) ?? TimeOfDay.now(),
      initialEntryMode: TimePickerEntryMode.input,
    );
    if (!mounted) return;
    setState(() => choosing = false);
    if (selected == null) return;
    final value =
        '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}';
    if (before.indexed.any((e) => e.$1 != index && e.$2 == value)) {
      setState(() => notice = '이미 추가한 시각입니다.');
      return;
    }
    if (index == null) {
      before.add(value);
    } else {
      before[index] = value;
    }
    write(before);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(context.tr('매일 확인할 시각 (선택)')),
      for (final entry in times.indexed)
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: choosing ? null : () => choose(entry.$1),
                icon: const Icon(Icons.access_time),
                label: Text(entry.$2),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: context.tr('{0} 시각 삭제', [entry.$2]),
              onPressed: choosing
                  ? null
                  : () => write(times..removeAt(entry.$1)),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      if (times.any((v) => parse(v) == null))
        Text(
          context.tr('시각을 다시 선택해 주세요.'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      if (notice != null)
        Semantics(liveRegion: true, child: Text(context.tr(notice!))),
      OutlinedButton.icon(
        onPressed: choosing ? null : choose,
        icon: const Icon(Icons.add),
        label: Text(context.tr('시각 추가')),
      ),
    ],
  );
}
