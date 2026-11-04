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
import '../details.dart';
import '../checkin_history_page.dart';
import '../../domain/ui_preferences.dart';

List<Widget> todayContent(
  BuildContext context,
  CareController c,
  void Function(CareEntry) openEntry, {
  VoidCallback? onShowMedications,
}) {
  final now = DateTime.now();
  final preferences = c.uiPreferences;
  final medications = [...c.medications]
    ..sort((a, b) {
      final left = nextMedicationCheck(a, now),
          right = nextMedicationCheck(b, now);
      if (left == null && right == null) return a.name.compareTo(b.name);
      if (left == null) return 1;
      if (right == null) return -1;
      return left.compareTo(right);
    });
  final entries = preferences.enabled(UiOption.dailySummary)
      ? c.records.entries(c.selectedId!, day: now)
      : const <CareEntry>[];
  final recent = preferences.enabled(UiOption.recentRecords)
      ? c.records.entries(c.selectedId!, limit: 5)
      : const <CareEntry>[];
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
              context.tr(c.patient.role == 'self' ? '오늘의 내 기록' : '오늘의 돌봄'),
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
                        onPressed: c.busy
                            ? null
                            : () => kind == EntryKind.medicationIntake
                                  ? chooseIntake(context, c)
                                  : editEntry(context, c, kind),
                      ),
                    ),
                  )
                  .toList(),
        );
      },
    ),
    Section(
      context.tr('할 일'),
      action: context.tr('할 일 추가'),
      onAction: c.busy ? null : () => editTask(context, c),
    ),
    TaskOverview(c),
    if (c.medications.isNotEmpty) ...[
      Section(
        context.tr('오늘의 복약'),
        action: context.tr('복약 기록'),
        onAction: c.busy ? null : () => chooseIntake(context, c),
      ),
      for (final med in medications.take(3))
        Card(
          child: Column(
            children: [
              ListTile(
                title: Text(med.name),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (nextMedicationCheck(med, now) case final next?)
                      Text(
                        context.tr('다음 확인: {0}', [
                          '${dateText(context, next)} ${timeText(context, next)}',
                        ]),
                      ),
                    MedicationTodayStatus(c, med),
                  ],
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => MedicationDetails(c, c.selectedId!, med.id),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: c.busy
                        ? null
                        : () => recordIntake(context, c, med),
                    icon: const Icon(Icons.add_task),
                    label: Text(context.tr('실제 복약 기록')),
                  ),
                ),
              ),
            ],
          ),
        ),
      if (onShowMedications != null)
        OutlinedButton.icon(
          onPressed: onShowMedications,
          icon: const Icon(Icons.list_alt),
          label: Text(context.tr('전체 약 보기')),
        ),
    ],
    OutlinedButton.icon(
      icon: const Icon(Icons.add_a_photo_outlined),
      label: Text(context.tr('사진으로 기록')),
      onPressed: c.busy ? null : () => startPhotoRecord(context, c),
    ),
    if (preferences.enabled(UiOption.caregiverShortcut) &&
        c.patient.role != 'self')
      Card(
        child: ListTile(
          leading: const Icon(Icons.favorite_outline),
          title: Text(context.tr('돌보는 나의 상태')),
          subtitle: Text(context.tr('수면, 피로, 스트레스와 필요한 도움을 따로 기록할 수 있어요.')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => CheckinHistoryPage(c)),
          ),
        ),
      ),
    if (preferences.enabled(UiOption.chatShortcut))
      Card(
        child: ListTile(
          leading: const Icon(Icons.chat_bubble_outline, color: forest),
          title: Text(context.tr('간병 도우미 대화')),
          subtitle: Text(context.tr('수첩 기록을 찾아보세요. 의료 질문은 검수 준비 중이에요.')),
          trailing: const Icon(Icons.chevron_right),
          onTap: c.busy
              ? null
              : () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => ChatPage(c))),
        ),
      ),
    Section(context.tr('연락이 필요할 때')),
    contactCard(context, c),
    if (preferences.enabled(UiOption.recentRecords)) ...[
      Section(context.tr('최근 기록')),
      if (recent.isEmpty)
        EmptyCard(
          context.tr('첫 기록을 기다리고 있어요'),
          context.tr('아래 기록하기를 눌러 식사나 오늘의 상태를 남겨 보세요.'),
        ),
      ...recent.map((e) => EntryTile(e, onTap: () => openEntry(e))),
    ],
    if (preferences.enabled(UiOption.dailySummary)) ...[
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
    ],
  ];
}

/// A user-entered reminder, independent of intake or clinical recommendations.
DateTime? nextMedicationCheck(Medication medication, DateTime now) {
  DateTime? next;
  for (final time in medication.times) {
    final parts = time.split(':');
    if (parts.length != 2) {
      continue;
    }
    final hour = int.tryParse(parts[0]), minute = int.tryParse(parts[1]);
    if (hour == null ||
        minute == null ||
        hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59) {
      continue;
    }
    var at = DateTime(now.year, now.month, now.day, hour, minute);
    if (at.isBefore(now)) {
      at = DateTime(now.year, now.month, now.day + 1, hour, minute);
    }
    if (next == null || at.isBefore(next)) next = at;
  }
  return next;
}
