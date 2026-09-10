import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../application/care_controller.dart';
import '../common.dart';
import '../details.dart';
import '../editors.dart';

List<Widget> medicationContent(
  BuildContext context,
  CareController c, {
  required bool archived,
  required ValueChanged<bool> onArchiveChanged,
}) {
  final meds = c.medicationBook.medications(
    c.selectedId!,
    includeArchived: archived,
  );
  return [
    Section(context.tr('약과 복약 기록')),
    Text(
      context.tr('처방받은 내용과 실제 복용 상태를 함께 관리해요.'),
      style: TextStyle(color: Color(0xFF68796E), height: 1.5),
    ),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(context.tr('보관한 약도 보기')),
      value: archived,
      onChanged: onArchiveChanged,
    ),
    if (meds.isEmpty)
      EmptyCard(
        context.tr('약 목록을 만들어 보세요'),
        context.tr('약 이름과 전달받은 지시, 확인할 시각을 직접 적을 수 있어요.'),
        icon: Icons.medication_outlined,
      ),
    ...meds.map(
      (m) => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.medication_outlined, color: forest),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${m.name}${m.active ? '' : context.tr(' · 보관됨')}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('약 상세'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            MedicationDetails(c, c.selectedId!, m.id),
                      ),
                    ),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              if (m.instruction.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(m.instruction),
                ),
              Text(
                m.times.isEmpty ? context.tr('정해둔 시각 없음') : m.times.join(' · '),
                style: const TextStyle(color: forest),
              ),
              if (m.active)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => recordIntake(context, c, m),
                    icon: const Icon(Icons.add_task, size: 18),
                    label: Text(context.tr('실제 복약 기록')),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  ];
}
