import '../photo_record_flow.dart';
import '../medication_today.dart';
import '../chat_page.dart';
import '../intake_picker.dart';

import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../application/care_controller.dart';
import '../../domain/records.dart';
import '../common.dart';
import '../settings.dart' show contactCard;
import '../editors.dart';
import '../task_list.dart';

List<Widget> todayContent(
  BuildContext context,
  CareController c,
  void Function(CareEntry) openEntry,
) {
  final now = DateTime.now();
  final entries = c.records.entries(c.selectedId!, day: now);
  final recent = c.records.entries(c.selectedId!, limit: 5);
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
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            header: true,
            child: Text(
              context.tr('오늘의 돌봄'),
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            context.strings.day(now),
            style: const TextStyle(color: Color(0xFF52655A)),
          ),
        ],
      ),
    ),
    LayoutBuilder(
      builder: (context, constraints) {
        final largeText = MediaQuery.textScalerOf(context).scale(16) > 24;
        final width = largeText
            ? constraints.maxWidth
            : (constraints.maxWidth - 12) / 2;
        return Wrap(
          key: const ValueKey('quick-records'),
          spacing: 12,
          runSpacing: 8,
          children:
              [
                    EntryKind.meal,
                    EntryKind.medicationIntake,
                    EntryKind.symptom,
                    EntryKind.activity,
                  ]
                  .map(
                    (kind) => SizedBox(
                      width: width,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 56),
                        ),
                        icon: Icon(kindIcon(kind)),
                        label: Text(context.tr(kind.label)),
                        onPressed: () => kind == EntryKind.medicationIntake
                            ? chooseIntake(context, c)
                            : editEntry(context, c, kind),
                      ),
                    ),
                  )
                  .toList(),
        );
      },
    ),
    OutlinedButton.icon(
      icon: const Icon(Icons.add_a_photo_outlined),
      label: Text(context.tr('사진으로 기록')),
      onPressed: () => startPhotoRecord(context, c),
    ),
    Section(
      context.tr('할 일'),
      action: context.tr('추가'),
      onAction: () => editTask(context, c),
    ),
    TaskOverview(c),
    if (c.medications.isNotEmpty) ...[
      Section(
        context.tr('오늘의 복약'),
        action: context.tr('복약 기록'),
        onAction: () => chooseIntake(context, c),
      ),
      for (final med in c.medications.take(3))
        Card(
          child: ListTile(
            title: Text(med.name),
            subtitle: MedicationTodayStatus(c, med),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => recordIntake(context, c, med),
          ),
        ),
      if (c.medications.length > 3)
        Text(context.tr('전체 약과 기록은 약 목록에서 확인할 수 있어요.')),
    ],
    Card(
      child: ListTile(
        leading: const Icon(Icons.chat_bubble_outline, color: forest),
        title: Text(context.tr('간병 도우미 대화')),
        subtitle: Text(context.tr('기록을 찾아보고 궁금한 내용을 물어보세요.')),
        trailing: const Icon(Icons.chevron_right),
        onTap: () =>
            Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => ChatPage(c))),
      ),
    ),
    Section(context.tr('연락이 필요할 때')),
    contactCard(context, c),
    Section(context.tr('최근 기록')),
    if (recent.isEmpty)
      EmptyCard(
        context.tr('첫 기록을 기다리고 있어요'),
        context.tr('아래 기록하기를 눌러 식사나 오늘의 상태를 남겨 보세요.'),
      ),
    ...recent.map((e) => EntryTile(e, onTap: () => openEntry(e))),
    Section(context.tr('차곡차곡, 오늘의 기록')),
    Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${context.tr('수분 기록')}: ${water.toStringAsFixed(water % 1 == 0 ? 0 : 1)} mL',
            ),
            Text('${context.tr('복용함 기록')}: ${context.tr('{0}건', [taken])}'),
            Text(
              context.tr('입력된 기록의 합계입니다.'),
              style: const TextStyle(color: Color(0xFF52655A)),
            ),
          ],
        ),
      ),
    ),
  ];
}
