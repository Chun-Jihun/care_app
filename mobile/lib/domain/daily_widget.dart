import 'dart:convert';

import '../l10n/app_strings.dart';
import 'records.dart';

/// A bounded, explicitly shared projection. No notebook IDs, aliases, free
/// notes, instructions, dose values, photo data, or encryption keys leave here.
final class DailyWidgetSnapshot {
  DailyWidgetSnapshot._(Map<String, Object?> data)
    : _encoded = jsonEncode(data);
  final String _encoded;
  Map<String, Object?> toJson() =>
      Map<String, Object?>.from(jsonDecode(_encoded) as Map);
  static String _title(String value) {
    final runes = value.replaceAll(RegExp(r'\s+'), ' ').trim().runes.toList();
    return runes.length <= 40
        ? String.fromCharCodes(runes)
        : '${String.fromCharCodes(runes.take(39))}…';
  }

  static String dayKey(DateTime at) =>
      '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';

  factory DailyWidgetSnapshot.build({
    required DateTime now,
    required List<CareTask> tasks,
    required List<Medication> medications,
    required List<CareEntry> entries,
    required AppStrings strings,
    required bool details,
  }) {
    final days = <Map<String, Object?>>[];
    for (var offset = 0; offset < 7; offset++) {
      final start = DateTime(now.year, now.month, now.day + offset);
      final end = DateTime(now.year, now.month, now.day + offset + 1);
      final pending = tasks.where(
        (task) =>
            !task.done &&
            !task.dueAt.isBefore(start) &&
            task.dueAt.isBefore(end),
      );
      final events = <Map<String, Object?>>[];
      for (final task in pending) {
        events.add({
          'at': task.dueAt.millisecondsSinceEpoch,
          if (details) 'text': _title(task.title),
        });
      }
      for (final medication in medications.where((m) => m.active)) {
        for (final time in medication.times) {
          final parts = time.split(':');
          if (parts.length != 2) continue;
          final hour = int.tryParse(parts[0]), minute = int.tryParse(parts[1]);
          if (hour == null ||
              minute == null ||
              hour < 0 ||
              hour > 23 ||
              minute < 0 ||
              minute > 59) {
            continue;
          }
          events.add({
            'at': DateTime(
              start.year,
              start.month,
              start.day,
              hour,
              minute,
            ).millisecondsSinceEpoch,
            if (details) 'text': _title(medication.name),
          });
        }
      }
      events.sort((a, b) => (a['at'] as int).compareTo(b['at'] as int));
      // Keep future checks first today; a bounded list must never imply there
      // are no more appointments when omitted events may still remain.
      final relevant = offset == 0
          ? events
                .where((e) => (e['at'] as int) >= now.millisecondsSinceEpoch)
                .toList()
          : events;
      days.add({
        'day': dayKey(start),
        'start': start.millisecondsSinceEpoch,
        'end': end.millisecondsSinceEpoch,
        'pending': pending.length,
        'overdue': tasks
            .where((t) => !t.done && t.dueAt.isBefore(start))
            .length,
        'intakes': offset == 0
            ? entries
                  .where(
                    (e) =>
                        e.kind == EntryKind.medicationIntake &&
                        e.fields['status'] == 'taken' &&
                        !e.occurredAt.isBefore(start) &&
                        e.occurredAt.isBefore(end),
                  )
                  .length
            : null,
        'events': relevant.take(32).toList(),
        'more': relevant.length > 32,
      });
    }
    final data = <String, Object?>{
      'version': 1,
      'updated': now.millisecondsSinceEpoch,
      'details': details,
      'timeZoneOffset': now.timeZoneOffset.inMinutes,
      'labels': {
        for (final item in {
          'title': '간병수첩',
          'pending': '오늘 할 일',
          'intakes': '복용함 기록',
          'overdue': '지난 예정',
          'next': '다음 확인',
          'updated': '마지막 갱신',
          'open': '앱에서 확인',
          'refresh': '기록 갱신 필요',
          'empty': '확인할 예정 없음',
          'scope': '선택한 수첩 · 입력한 기록 기준',
        }.entries)
          item.key: strings.text(item.value),
      },
      'days': days,
    };
    if (utf8.encode(jsonEncode(data)).length > 65536) {
      throw const FormatException('Widget projection too large');
    }
    return DailyWidgetSnapshot._(data);
  }
}
