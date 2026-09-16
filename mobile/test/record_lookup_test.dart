import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/record_lookup_parser.dart';
import 'package:care_notebook/domain/record_lookup.dart';
import 'package:care_notebook/domain/records.dart';

void main() {
  final now = DateTime(2026, 9, 14, 0, 5); // Monday, just after midnight.
  RecordLookup? parse(String text) => RecordLookupParser.parse(text, now: now);

  test('relative dates use calendar days and weeks start on Monday', () {
    final yesterday = parse('어제 복약 기록 보여줘')!;
    expect(yesterday.start, DateTime(2026, 9, 13));
    expect(yesterday.end, DateTime(2026, 9, 14));
    expect(yesterday.kind, EntryKind.medicationIntake);
    expect(parse('이번 주 식사 기록')!.start, DateTime(2026, 9, 14));
    expect(parse('이번 주 식사 기록')!.end, DateTime(2026, 9, 15));
    expect(parse('지난주 활동 기록')!.start, DateTime(2026, 9, 7));
    expect(parse('지난주 활동 기록')!.end, DateTime(2026, 9, 14));
    expect(parse('최근 7일 수분 기록')!.start, DateTime(2026, 9, 8));
    expect(parse('최근 7일 수분 기록')!.requiredField, 'water_ml');
    expect(
      RecordLookupParser.parse('어제 기록', now: DateTime(2027, 1, 1))!.start,
      DateTime(2026, 12, 31),
    );
  });

  test(
    'explicit ranges are inclusive; invalid or ambiguous requests abstain',
    () {
      final range = parse('2026-09-01부터 2026-09-03까지 증상 기록 찾아줘')!;
      expect(range.start, DateTime(2026, 9, 1));
      expect(range.end, DateTime(2026, 9, 4));
      for (final question in [
        '2026-02-30 복약 기록',
        '2026-09-14부터 2026-09-01까지 기록',
        '2026-08-01부터 2026-09-14까지 기록',
        '최근 0일 기록',
        '최근 32일 기록',
        '어제 또는 오늘 복약 기록',
        '어제 기록과 오늘 기록',
        '오늘 25:00 복약 기록',
        '오늘 12:60 복약 기록',
        '오늘 09:00 또는 10:00 복약 기록',
        '오늘 복약 기록 그리고 약을 두 배 먹어도 돼?',
        '어제 식사량이 줄었어?',
        '이번 주 약 추천해줘',
        '어제 말고 오늘 기록',
      ]) {
        expect(parse(question), isNull, reason: question);
      }
    },
  );

  test(
    'only explicit times are resolved; quoted items keep exact strength',
    () {
      final at = parse('어제 09:30에 복약 기록 보여줘')!;
      expect(at.fromMinute, 570);
      expect(at.untilMinute, 571);
      final quoted = parse('최근 3일 "약 A 5 mg" 기록')!;
      expect(quoted.item, '약 A 5 mg');
      expect(quoted.matches(entry('약 A 5 mg', DateTime(2026, 9, 13))), true);
      expect(quoted.matches(entry('약 A 15 mg', DateTime(2026, 9, 13))), false);
      expect(quoted.matches(entry('약 A 5 mg', DateTime(2026, 9, 11))), false);
      expect(parse('어제 저녁 복약 기록'), isNull);
      expect(parse('어제 "약  A 5 mg" 기록')!.item, '약  A 5 mg');
    },
  );

  test('lookup codec rejects widened filters and survives round trips', () {
    final lookup = parse('최근 7일 수분 기록')!;
    expect(RecordLookup.fromJson(lookup.toJson()).toJson(), lookup.toJson());
    for (final change in [
      {'end': '2099-01-01'},
      {'start': '2026-02-30'},
      {'untilMinute': 1441},
      {'fromMinute': -1},
      {'kind': 'unknown'},
      {'requiredField': 'private'},
      {'extra': 'ignored'},
    ]) {
      expect(
        () => RecordLookup.fromJson({...lookup.toJson(), ...change}),
        throwsFormatException,
      );
    }
  });
}

CareEntry entry(String medicine, DateTime at) => CareEntry(
  id: 'e',
  patientId: 'p',
  kind: EntryKind.medicationIntake,
  occurredAt: at,
  offsetMinutes: 0,
  note: '',
  fields: {'medicine': medicine, 'status': 'missed'},
  version: 1,
);
