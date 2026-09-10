import 'dart:convert';

import '../../domain/records.dart';
import '../ports.dart';
import '../notebook_repository.dart';

final class ReminderService {
  ReminderService(this._platform);
  final PlatformServices _platform;
  String? _state;
  void invalidate() => _state = null;
  Future<String?> sync(NotebookRepository db, bool Function() active) async {
    String? notice;
    final notificationsEnabled = db.setting('reminders_enabled') == 'true';
    final reminders = <Reminder>[];
    final now = DateTime.now();
    final definitions = <String>[];
    if (notificationsEnabled) {
      for (final p in db.patients()) {
        if (db.setting('imported_muted:${p.id}') == 'true') continue;
        for (final t in db.tasks(p.id).where((t) => !t.done && t.reminder)) {
          final source = 'task:${p.id}:${t.id}';
          definitions.add('$source:${t.dueAt.millisecondsSinceEpoch}');
          reminders.add(Reminder(Reminder.idFor(source), t.dueAt));
        }
        for (final med in db.medications(p.id)) {
          for (final time in med.times) {
            final parts = time.split(':').map(int.parse).toList();
            var at = DateTime(now.year, now.month, now.day, parts[0], parts[1]);
            if (!at.isAfter(now)) {
              at = DateTime(
                now.year,
                now.month,
                now.day + 1,
                parts[0],
                parts[1],
              );
            }
            final source = 'med:${p.id}:${med.id}:$time';
            definitions.add(source);
            reminders.add(Reminder(Reminder.idFor(source), at, daily: true));
          }
        }
      }
      reminders.sort((a, b) => a.at.compareTo(b.at));
      if (reminders.where((r) => r.at.isAfter(now)).length > 60) {
        notice = '기록은 저장되었습니다. 가까운 일정부터 최대 60개 알림을 예약했습니다.';
      }
    }
    if (reminders.map((r) => r.id).toSet().length != reminders.length) {
      throw CareError(CareErrorCode.reminderIdCollision);
    }
    definitions.sort();
    final state = jsonEncode([
      notificationsEnabled,
      await _platform.timeZone(),
      definitions,
      reminders
          .where((r) => r.at.isAfter(now))
          .take(60)
          .map((r) => r.id)
          .toList(),
    ]);
    if (!active() || state == _state) return notice;
    await _platform.schedule(reminders);
    _state = state;
    return notice;
  }
}
