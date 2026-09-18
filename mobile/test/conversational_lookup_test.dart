import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/record_lookup_parser.dart';
import 'package:care_notebook/domain/record_lookup.dart';
import 'package:care_notebook/domain/records.dart';

void main() {
  final now = DateTime(2026, 9, 18, 15);
  RecordLookup? parse(String text, [RecordLookup? previous]) =>
      RecordLookupParser.parse(text, now: now, previous: previous);

  test(
    'LOOKUP-01 familiar wording, particles and date order preserve scope',
    () {
      for (final text in [
        '어제 약 먹었어?',
        '약 먹었는지 어제 기록 좀 보여주세요',
        '어제의 복약 기록을 볼 수 있을까요?',
        '복용 기록 어제 찾아줘',
        '어제 약은 먹었나요?',
        '약 먹었는지 어제 확인해줘',
      ]) {
        final query = parse(text)!;
        expect(query.kind, EntryKind.medicationIntake, reason: text);
        expect(query.start, DateTime(2026, 9, 17));
        expect(
          query.intakeStatus,
          isEmpty,
        ); // A question never asserts ingestion.
      }
      expect(parse('오늘 물 마신 기록 알려줘')!.requiredField, 'water_ml');
      expect(parse('오늘 물 마셨어?')!.requiredField, 'water_ml');
      expect(parse('어제 뭐 먹었어?')!.kind, EntryKind.meal);
      expect(parse('어제 운동했어?')!.kind, EntryKind.activity);
      expect(parse('밥 먹은 기록 이번 주 보여 줘')!.kind, EntryKind.meal);
      expect(parse('최근 일주일 활동 기록')!.start, DateTime(2026, 9, 12));
      expect(parse('지난달 기록')!.start, DateTime(2026, 8, 1));
      expect(parse('지난달 기록')!.end, DateTime(2026, 9, 1));
      expect(parse('2026년 9월 3일 식사 기록')!.start, DateTime(2026, 9, 3));
      final time = parse('어제 오후 3시 30분 혈압 기록')!;
      expect(time.item, '혈압');
      expect(time.fromMinute, 930);
      expect(parse('오늘 오전 복약 기록')!.untilMinute, 720);
    },
  );

  test(
    'LOOKUP-02 explicit status and exact medication strength remain distinct',
    () {
      expect(parse('어제 먹은 약 기록')!.intakeStatus, 'taken');
      expect(parse('어제 복용하지 못한 약 기록')!.intakeStatus, 'missed');
      expect(parse('지난주 복용 거부 기록')!.intakeStatus, 'refused');
      final name = parse('어제 약 A 5 mg 복용 기록 보여주세요')!;
      expect(name.item, '약 A 5 mg');
      expect(name.kind, EntryKind.medicationIntake);
      final query = parse('어제 복용 거부 기록')!;
      CareEntry entry(String status) => CareEntry(
        id: 'e',
        patientId: 'p',
        kind: EntryKind.medicationIntake,
        occurredAt: DateTime(2026, 9, 17),
        offsetMinutes: 0,
        note: '',
        fields: {'medicine': '약 A', 'status': status},
        version: 1,
      );
      expect(query.matches(entry('refused')), isTrue);
      expect(query.matches(entry('taken')), isFalse);
      expect(RecordLookup.fromJson(query.toJson()).intakeStatus, 'refused');
      expect(
        () => RecordLookup.fromJson({
          ...query.toJson(),
          'intakeStatus': 'guessed',
        }),
        throwsFormatException,
      );
      final old = {...query.toJson()}..remove('intakeStatus');
      expect(RecordLookup.fromJson(old).intakeStatus, isEmpty);
    },
  );

  test('LOOKUP-03 follow-ups need an explicit preceding query and retain its bounds', () {
    final first = parse('오늘 복용 거부 기록')!;
    final next = parse('그럼 어제는?', first)!;
    expect(next.start, DateTime(2026, 9, 17));
    expect(next.kind, first.kind);
    expect(next.intakeStatus, 'refused');
    final morning = parse('그럼 어제 오전은?', first)!;
    expect(morning.fromMinute, 0);
    expect(morning.untilMinute, 720);
    expect(parse('그럼 수분은?', morning)!.untilMinute, 720);
    final water = parse('그럼 수분은?', next)!;
    expect(water.start, next.start);
    expect(water.requiredField, 'water_ml');
    expect(water.intakeStatus, isEmpty);
    expect(parse('어제는?'), isNull);
    expect(parse('그럼 수분은?'), isNull);
    expect(parse('어제 말고 오늘 기록', first), isNull);
  });

  test('LOOKUP-04 ambiguous or compound requests never drop a qualifier', () {
    for (final text in [
      '어제 저녁 복약 기록',
      '오늘 아침 9시 약 기록',
      '오늘 약 안 먹었지?',
      '어제 먹은 약 말고 거부한 약',
      '지난달과 이번달 기록',
      '어제 엄마랑 아빠 복약 기록',
      '최근 32일 식사 기록',
      '최근 999999999999999999999999999999일 식사 기록',
      '2026년 2월 30일 식사 기록',
      '오늘 오후 13시 복약 기록',
      '오늘 09:30 복약 기록 말고 약 추천해줘',
      '어제보다 오늘 물 적게 마셨지?',
      '이번 주 복약 기록 빼고 식사 기록',
    ]) {
      expect(parse(text), isNull, reason: text);
    }
  });
}
