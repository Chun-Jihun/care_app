import 'records.dart';

/// A bounded, read-only filter. Dates are local calendar dates; end is exclusive.
/// It never interprets an absent entry as a missed dose or a clinical change.
final class RecordLookup {
  const RecordLookup({
    required this.start,
    required this.end,
    this.fromMinute = 0,
    this.untilMinute = 1440,
    this.kind,
    this.item = '',
    this.requiredField = '',
    this.intakeStatus = '',
  });

  final DateTime start, end;
  final int fromMinute, untilMinute;
  final EntryKind? kind;
  final String item, requiredField, intakeStatus;

  bool matches(CareEntry entry) {
    final at = entry.occurredAt;
    final minute = at.hour * 60 + at.minute;
    if (at.isBefore(start) ||
        !at.isBefore(end) ||
        minute < fromMinute ||
        minute >= untilMinute ||
        (kind != null && entry.kind != kind) ||
        (intakeStatus.isNotEmpty && entry.fields['status'] != intakeStatus) ||
        (requiredField.isNotEmpty &&
            (entry.fields[requiredField] ?? '').trim().isEmpty)) {
      return false;
    }
    if (item.isEmpty) return true;
    return const [
      'food',
      'medicine',
      'symptom',
      'activity',
      'measurement',
      'event',
    ].any((key) => entry.fields[key] == item);
  }

  Map<String, Object?> toJson() => {
    'start': date(start),
    'end': date(end),
    'fromMinute': fromMinute,
    'untilMinute': untilMinute,
    'kind': kind?.name,
    'item': item,
    'requiredField': requiredField,
    if (intakeStatus.isNotEmpty) 'intakeStatus': intakeStatus,
  };

  static RecordLookup fromJson(Object? raw) {
    if (raw is! Map ||
        (raw.length != 7 && raw.length != 8) ||
        raw.keys.any(
          (key) => !const [
            'start',
            'end',
            'fromMinute',
            'untilMinute',
            'kind',
            'item',
            'requiredField',
            'intakeStatus',
          ].contains(key),
        ) ||
        !raw.keys.toSet().containsAll([
          'start',
          'end',
          'fromMinute',
          'untilMinute',
          'kind',
          'item',
          'requiredField',
        ])) {
      throw const FormatException('invalid lookup');
    }
    final start = parseDate(raw['start']), end = parseDate(raw['end']);
    final from = raw['fromMinute'], until = raw['untilMinute'];
    final kind = EntryKind.values
        .where((k) => k.name == raw['kind'])
        .firstOrNull;
    if (start == null ||
        end == null ||
        calendarDays(start, end) < 1 ||
        calendarDays(start, end) > 31 ||
        from is! int ||
        until is! int ||
        from < 0 ||
        until > 1440 ||
        from >= until ||
        (raw['kind'] != null && kind == null) ||
        raw['item'] is! String ||
        (raw['item'] as String).length > 200 ||
        !const ['', 'water_ml'].contains(raw['requiredField']) ||
        (raw['requiredField'] == 'water_ml' && kind != EntryKind.meal)) {
      throw const FormatException('invalid lookup');
    }
    final status = raw.containsKey('intakeStatus') ? raw['intakeStatus'] : '';
    if (status is! String ||
        (status.isNotEmpty &&
            (!intakeLabels.containsKey(status) ||
                kind != EntryKind.medicationIntake))) {
      throw const FormatException('invalid intake filter');
    }
    return RecordLookup(
      start: start,
      end: end,
      fromMinute: from,
      untilMinute: until,
      kind: kind,
      item: raw['item'] as String,
      requiredField: raw['requiredField'] as String,
      intakeStatus: status,
    );
  }

  static String date(DateTime at) =>
      '${at.year.toString().padLeft(4, '0')}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';

  static DateTime? parseDate(Object? raw) {
    if (raw is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) {
      return null;
    }
    final at = DateTime.tryParse(raw);
    return at != null && date(at) == raw ? at : null;
  }

  static int calendarDays(DateTime start, DateTime end) => DateTime.utc(
    end.year,
    end.month,
    end.day,
  ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
}
