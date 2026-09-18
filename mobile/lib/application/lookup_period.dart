import '../domain/record_lookup.dart';

/// Calendar arithmetic only. No assumed meal times or inferred clinical dates.
final class LookupPeriod {
  const LookupPeriod(this.start, this.end, this.remaining);
  final DateTime start, end;
  final String remaining;
  static final expression = RegExp(
    r'\d{4}-\d{2}-\d{2}(?:\s*(?:부터|~)\s*\d{4}-\d{2}-\d{2}(?:까지)?)?'
    r'|\d{4}년\s*\d{1,2}월\s*\d{1,2}일'
    r'|오늘|어제|그저께|그제|이번\s*주|지난\s*주|이번\s*달|지난\s*달'
    r'|(?:최근|지난)\s*(?:\d+\s*일|일주일|한\s*주|[1-4]\s*주)(?:\s*동안)?',
  );

  static LookupPeriod? extract(String text, DateTime now) {
    final matches = expression.allMatches(text).toList();
    if (matches.length != 1) return null;
    final match = matches.single;
    final period = match[0]!.replaceAll(RegExp(r'\s+'), '');
    final today = DateTime(now.year, now.month, now.day);
    DateTime day(int offset) => DateTime(now.year, now.month, now.day + offset);
    DateTime start, end;
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
      case '이번달':
        start = DateTime(now.year, now.month);
        end = day(1);
      case '지난달':
        start = DateTime(now.year, now.month - 1);
        end = DateTime(now.year, now.month);
      default:
        if (period.startsWith('최근') || period.startsWith('지난')) {
          final digits = RegExp(r'\d+').firstMatch(period)?[0];
          final count = digits == null ? 1 : int.tryParse(digits);
          if (count == null || count < 1 || count > 31) return null;
          final days = period.contains('주') ? count * 7 : count;
          if (days < 1 || days > 31) return null;
          start = day(1 - days);
          end = day(1);
        } else if (period.contains('년')) {
          final parts = RegExp(r'\d+')
              .allMatches(period)
              .map((m) => int.parse(m[0]!))
              .toList();
          start = DateTime(parts[0], parts[1], parts[2]);
          if (start.year != parts[0] ||
              start.month != parts[1] ||
              start.day != parts[2]) {
            return null;
          }
          end = DateTime(start.year, start.month, start.day + 1);
        } else {
          final dates = RegExp(r'\d{4}-\d{2}-\d{2}')
              .allMatches(period)
              .toList();
          final first = RecordLookup.parseDate(dates.first[0]);
          final last = RecordLookup.parseDate(dates.last[0]);
          if (first == null || last == null) return null;
          start = first;
          end = DateTime(last.year, last.month, last.day + 1);
        }
    }
    final days = RecordLookup.calendarDays(start, end);
    if (days < 1 || days > 31) return null;
    final suffix = text
        .substring(match.end)
        .replaceFirst(RegExp(r'^(?:의|에|은|는)'), '');
    return LookupPeriod(
      start,
      end,
      '${text.substring(0, match.start)} $suffix'.trim(),
    );
  }
}
