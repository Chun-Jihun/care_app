import '../domain/record_lookup.dart';
import '../domain/records.dart';

/// A deliberately small Korean grammar. Unconsumed text fails closed so a
/// comparison, negation, extra patient, or clinical request cannot be dropped.
final class RecordLookupParser {
  static final _date = RegExp(
    r'^(오늘|어제|그저께|그제|이번\s*주|지난\s*주|최근\s*\d{1,2}\s*일|'
    r'\d{4}-\d{2}-\d{2}(?:\s*(?:부터|~)\s*\d{4}-\d{2}-\d{2}(?:까지)?)?)'
    r'(?:의|에)?\s*',
  );
  static final _time = RegExp(r'^(\d{2}):(\d{2})(?:에)?\s+');
  static final _ending = RegExp(
    r'^(?:을|를)?\s*(?:보여\s*줘(?:요)?|알려\s*줘(?:요)?|찾아\s*줘(?:요)?|'
    r'정리해\s*줘(?:요)?|조회|확인|있어(?:요)?)?[?.!]?$',
  );
  static const _kinds = {
    '식사·수분': EntryKind.meal,
    '식사': EntryKind.meal,
    '음식': EntryKind.meal,
    '수분': EntryKind.meal,
    '복약': EntryKind.medicationIntake,
    '약': EntryKind.medicationIntake,
    '증상': EntryKind.symptom,
    '활동·재활': EntryKind.activity,
    '활동': EntryKind.activity,
    '재활': EntryKind.activity,
    '측정': EntryKind.measurement,
    '생활': EntryKind.dailyLiving,
    '사건': EntryKind.incident,
    '진료·연락': EntryKind.medicalContact,
    '진료': EntryKind.medicalContact,
    '연락': EntryKind.medicalContact,
    '인계': EntryKind.handoff,
    '자유 메모': EntryKind.generalNote,
    '메모': EntryKind.generalNote,
  };

  static bool hasPeriodExpression(String question) => RegExp(
    r'오늘|어제|그제|그저께|이번\s*주|지난\s*주|최근\s*\d+\s*일|'
    r'\d{4}-\d{2}-\d{2}\s*(?:부터|~)',
  ).hasMatch(question);

  static RecordLookup? parse(String question, {required DateTime now}) {
    if (question.length > 1200) return null;
    // Whitespace inside a quoted item is part of its exact saved name.
    var rest = question.trim();
    final match = _date.firstMatch(rest);
    if (match == null) return null;
    final period = match[1]!.replaceAll(' ', '');
    rest = rest.substring(match.end).trim();
    final today = DateTime(now.year, now.month, now.day);
    DateTime start, end;
    DateTime day(int offset) =>
        DateTime(today.year, today.month, today.day + offset);
    switch (period) {
      case '오늘':
        start = today;
        end = day(1);
      case '어제':
        start = day(-1);
        end = today;
      case '그제' || '그저께':
        start = day(-2);
        end = day(-1);
      case '이번주':
        start = day(1 - today.weekday);
        end = day(1);
      case '지난주':
        start = day(-6 - today.weekday);
        end = day(1 - today.weekday);
      default:
        if (period.startsWith('최근')) {
          final days = int.parse(RegExp(r'\d+').firstMatch(period)![0]!);
          if (days < 1 || days > 31) return null;
          start = day(1 - days);
          end = day(1);
        } else {
          final dates = RegExp(r'\d{4}-\d{2}-\d{2}')
              .allMatches(period)
              .toList();
          final first = RecordLookup.parseDate(dates.first[0]);
          final last = RecordLookup.parseDate(dates.last[0]);
          if (first == null || last == null) return null;
          start = first;
          end = DateTime(last.year, last.month, last.day + 1);
          final days = RecordLookup.calendarDays(start, end);
          if (days < 1 || days > 31) return null;
        }
    }
    var from = 0, until = 1440;
    final time = _time.firstMatch(rest);
    if (time != null) {
      final hour = int.parse(time[1]!), minute = int.parse(time[2]!);
      if (hour > 23 || minute > 59) return null;
      from = hour * 60 + minute;
      until = from + 1;
      rest = rest.substring(time.end).trim();
    }
    EntryKind? kind;
    var item = '', requiredField = '';
    if (rest.startsWith('"')) {
      final quoted = RegExp(r'^"([^"\n]{1,200})"\s*').firstMatch(rest);
      if (quoted == null || quoted[1]!.trim().isEmpty) return null;
      item = quoted[1]!;
      rest = rest.substring(quoted.end).trim();
    } else {
      for (final entry in _kinds.entries) {
        if (rest == entry.key || rest.startsWith('${entry.key} ')) {
          kind = entry.value;
          if (entry.key == '수분') requiredField = 'water_ml';
          rest = rest.substring(entry.key.length).trim();
          break;
        }
      }
    }
    // All-category lookup must explicitly say "기록". Bare dates are ambiguous.
    final hasRecord = rest.startsWith('기록');
    if (hasRecord) rest = rest.substring(2).trim();
    if (kind == null && item.isEmpty && !hasRecord) return null;
    if (!_ending.hasMatch(rest)) return null;
    return RecordLookup(
      start: start,
      end: end,
      fromMinute: from,
      untilMinute: until,
      kind: kind,
      item: item,
      requiredField: requiredField,
    );
  }
}
