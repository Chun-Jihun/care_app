import 'package:flutter/material.dart';

import '../domain/records.dart';
import '../l10n/app_strings.dart';

class AiFieldChoices extends StatelessWidget {
  const AiFieldChoices({
    super.key,
    required this.kind,
    required this.candidates,
    required this.currentFields,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });
  final EntryKind kind;
  final Map<String, String> candidates, currentFields, selected;
  final bool enabled;
  final void Function(String key, String value, bool checked) onChanged;

  @override
  Widget build(BuildContext context) {
    if (candidates.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(context.tr('빈 입력란에 반영할 항목 선택')),
        Text(
          context.tr('항목명이 명확한 줄에서 찾은 후보입니다. 원문과 대조해 선택하세요. 이미 작성한 항목은 유지합니다.'),
        ),
        for (final field in kind.fields)
          if (candidates[field.key] case final value?)
            CheckboxListTile(
              key: ValueKey('aiField-${field.key}'),
              contentPadding: EdgeInsets.zero,
              title: Text(context.tr(field.label)),
              subtitle: Text(context.strings.fieldValue(field, value)),
              value:
                  selected[field.key] == value &&
                  (currentFields[field.key] ?? '').trim().isEmpty,
              onChanged:
                  !enabled || (currentFields[field.key] ?? '').trim().isNotEmpty
                  ? null
                  : (checked) => onChanged(field.key, value, checked == true),
            ),
      ],
    );
  }
}
