import 'package:flutter/material.dart';

import '../domain/records.dart';
import '../l10n/app_strings.dart';

/// Visual grouping only. Every controller remains owned by the draft editor,
/// including fields that are currently collapsed.
class RecordFields extends StatefulWidget {
  const RecordFields({super.key, required this.kind, required this.values});
  final EntryKind kind;
  final Map<String, TextEditingController> values;
  @override
  State<RecordFields> createState() => RecordFieldsState();
}

class RecordFieldsState extends State<RecordFields>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  late final focus = {for (final f in widget.kind.fields) f.key: FocusNode()};
  late final anchors = {for (final f in widget.kind.fields) f.key: GlobalKey()};
  late bool expanded = hasDetailValues;
  String? invalid;

  Set<String> get quick => switch (widget.kind) {
    EntryKind.meal => {'food', 'amount', 'water_ml'},
    EntryKind.symptom => {'symptom', 'severity'},
    EntryKind.activity => {'activity', 'minutes', 'completion'},
    EntryKind.medicationIntake => {'medicine', 'status'},
    EntryKind.measurement => {'measurement', 'value', 'unit'},
    EntryKind.dailyLiving => {'category', 'details'},
    EntryKind.incident => {'event', 'action'},
    EntryKind.medicalContact => {'institution', 'instruction'},
    EntryKind.handoff => {'completed', 'pending', 'observe'},
    EntryKind.generalNote => {},
  };
  bool primary(RecordField f) => f.required || quick.contains(f.key);
  bool get hasDetailValues => widget.kind.fields.any(
    (f) => !primary(f) && widget.values[f.key]!.text.trim().isNotEmpty,
  );

  void revealPopulatedDetails() {
    if (!expanded && hasDetailValues) setState(() => expanded = true);
  }

  Future<bool> revealError(Object error) async {
    if (error is! CareError || error.labels.isEmpty) return false;
    final matching = widget.kind.fields.where(
      (f) => error.labels.contains(f.label),
    );
    if (matching.isEmpty) return false;
    final field = matching.first;
    setState(() {
      invalid = field.key;
      if (!primary(field)) expanded = true;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return true;
    final target = anchors[field.key]!.currentContext;
    if (target != null && target.mounted) {
      await Scrollable.ensureVisible(target, alignment: .15);
      if (mounted) focus[field.key]!.requestFocus();
    }
    return true;
  }

  @override
  void dispose() {
    for (final node in focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  Widget input(RecordField f) {
    final controller = widget.values[f.key]!;
    void changed(String? value) {
      if (f.choices.isNotEmpty) controller.text = value ?? '';
      if (invalid == f.key) setState(() => invalid = null);
    }

    final decoration = InputDecoration(
      labelText: '${context.tr(f.label)}${f.required ? ' *' : ''}',
      errorText: invalid == f.key ? context.tr('입력 내용을 확인해 주세요.') : null,
      errorMaxLines: 3,
    );
    return Padding(
      key: anchors[f.key],
      padding: const EdgeInsets.only(bottom: 16),
      child: f.choices.isEmpty
          ? TextFormField(
              key: ValueKey('entry-field-${f.key}'),
              controller: controller,
              focusNode: focus[f.key],
              decoration: decoration,
              minLines: f.key == 'instruction' ? 3 : 1,
              maxLines: f.key == 'instruction' ? 6 : 1,
              keyboardType: f.numeric
                  ? const TextInputType.numberWithOptions(decimal: true)
                  : f.key == 'instruction'
                  ? TextInputType.multiline
                  : TextInputType.text,
              autocorrect: false,
              enableIMEPersonalizedLearning: false,
              enableSuggestions: false,
              onChanged: changed,
            )
          : DropdownButtonFormField<String>(
              key: ValueKey('entry-field-${f.key}-${controller.text}'),
              focusNode: focus[f.key],
              isExpanded: true,
              itemHeight: null,
              initialValue: controller.text.isEmpty ? null : controller.text,
              decoration: decoration,
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
              onChanged: changed,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final details = widget.kind.fields.where((f) => !primary(f));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...widget.kind.fields.where(primary).map(input),
        if (details.isNotEmpty) ...[
          Semantics(
            expanded: expanded,
            child: OutlinedButton.icon(
              onPressed: () {
                FocusScope.of(context).unfocus();
                setState(() => expanded = !expanded);
              },
              icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
              label: Text(context.tr('자세히 기록')),
            ),
          ),
          if (expanded) ...[const SizedBox(height: 16), ...details.map(input)],
        ],
      ],
    );
  }
}
