import '../domain/record_lookup.dart';
import '../domain/records.dart';
import 'lookup_period.dart';

/// Fully consumes a bounded lookup request. Unknown qualifiers are never dropped.
final class RecordLookupParser {
  static const _ending =
      r'(?:은|는|을|를)?\s*(?:좀\s*)?(?:보여\s*(?:줘요?|주세요)|알려\s*(?:줘요?|주세요)|찾아\s*(?:줘요?|주세요)|확인해\s*(?:줘요?|주세요)|정리해\s*줘요?|볼\s*수\s*있을까요|조회|확인|있어(?:요)?)?[?.!]*';
  static final _followup = RegExp(r'^(?:그럼|그러면|그렇다면)\s*');
  static final _time = RegExp(
    r'(?:(오전|오후)\s*)?(\d{1,2})(?::(\d{2})|시(?:\s*(\d{1,2})분|\s*(반))?)(?:에)?',
  );
  static const _subjects = <String, (EntryKind, String, String, String)>{
    '복용하지 못한 약|빠뜨린 약|누락된 복약': (EntryKind.medicationIntake, '', '', 'missed'),
    '복용 거부|거부한 약': (EntryKind.medicationIntake, '', '', 'refused'),
    '확인 못한 복약': (EntryKind.medicationIntake, '', '', 'unknown'),
    '먹은 약|복용한 약|복용함': (EntryKind.medicationIntake, '', '', 'taken'),
    '약(?:을|은)? 먹었(?:어요|어|나요|니|는지)|약(?:을|은)? 복용했(?:어요|어|나요|니|는지)': (
      EntryKind.medicationIntake,
      '',
      '',
      '',
    ),
    '복약|복용|약': (EntryKind.medicationIntake, '', '', ''),
    '물(?:을)? 마신|물(?:을)? 마셨(?:어요|어|나요|는지)|마신 물|수분|물': (
      EntryKind.meal,
      '',
      'water_ml',
      '',
    ),
    '밥(?:을)? 먹은|밥(?:을)? 먹었(?:어요|어|나요|는지)|뭐(?:를)? 먹었(?:어요|어|나요)|먹은 음식|식사·수분|식사|음식|밥':
        (EntryKind.meal, '', '', ''),
    '운동했(?:어요|어|나요|는지)|활동·재활|활동|운동|재활': (EntryKind.activity, '', '', ''),
    '산책': (EntryKind.activity, '산책', '', ''),
    '혈압': (EntryKind.measurement, '혈압', '', ''),
    '혈당': (EntryKind.measurement, '혈당', '', ''),
    '체온': (EntryKind.measurement, '체온', '', ''),
    '체중': (EntryKind.measurement, '체중', '', ''),
    '측정': (EntryKind.measurement, '', '', ''),
    '증상': (EntryKind.symptom, '', '', ''),
    '생활': (EntryKind.dailyLiving, '', '', ''),
    '사건': (EntryKind.incident, '', '', ''),
    '진료·연락|진료|연락': (EntryKind.medicalContact, '', '', ''),
    '인계': (EntryKind.handoff, '', '', ''),
    '자유 메모|메모': (EntryKind.generalNote, '', '', ''),
  };
  // Preserve the model's existing explicit ISO-date/time extraction path.
  // Relative, ranged or multiple dates must be resolved by this parser only.
  static bool hasPeriodExpression(String text) {
    final matches = LookupPeriod.expression.allMatches(text).toList();
    return matches.length > 1 ||
        (matches.length == 1 &&
            !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(matches.single[0]!));
  }

  static RecordLookup? parse(
    String question, {
    required DateTime now,
    RecordLookup? previous,
  }) {
    if (question.length > 1200 || question.contains('\uE000')) return null;
    // Protect exact names from date/time recognition and whitespace folding.
    var rest = question.trim();
    final quoted = RegExp(r'"([^"\n]{1,200})"').allMatches(rest).toList();
    if (quoted.length > 1) return null;
    final quotedItem = quoted.firstOrNull?[1];
    if (quotedItem != null) {
      rest = rest.replaceRange(
        quoted.single.start,
        quoted.single.end,
        '\uE000',
      );
    }
    final followup = _followup.hasMatch(rest);
    rest = rest.replaceFirst(_followup, '');
    final period = LookupPeriod.extract(rest, now);
    if (period == null &&
        (LookupPeriod.expression.hasMatch(rest) ||
            !followup ||
            previous == null)) {
      return null;
    }
    rest = period?.remaining ?? rest;
    var from = 0, until = 1440;
    var hasTime = false;
    final times = _time.allMatches(rest).toList();
    if (times.length > 1) return null;
    if (times.isNotEmpty) {
      hasTime = true;
      final time = times.single;
      var hour = int.parse(time[2]!);
      final minute = time[5] != null
          ? 30
          : int.parse(time[3] ?? time[4] ?? '0');
      if (hour > 23 ||
          minute > 59 ||
          (time[1] != null && (hour < 1 || hour > 12))) {
        return null;
      }
      if (time[1] != null) hour = hour % 12 + (time[1] == '오후' ? 12 : 0);
      from = hour * 60 + minute;
      until = from + 1;
      rest = rest.replaceRange(time.start, time.end, '');
    } else {
      final half = RegExp(r'오전|오후').allMatches(rest).toList();
      if (half.length > 1) return null;
      if (half.isNotEmpty) {
        hasTime = true;
        from = half.single[0] == '오전' ? 0 : 720;
        until = from + 720;
        rest = rest.replaceRange(half.single.start, half.single.end, '');
      }
    }
    if (period == null && previous != null && !hasTime) {
      from = previous.fromMinute;
      until = previous.untilMinute;
    }
    rest = rest.trim();
    final start = period?.start ?? previous!.start;
    final end = period?.end ?? previous!.end;
    RecordLookup make({
      EntryKind? kind,
      String item = '',
      String field = '',
      String status = '',
    }) => RecordLookup(
      start: start,
      end: end,
      fromMinute: from,
      untilMinute: until,
      kind: kind,
      item: item,
      requiredField: field,
      intakeStatus: status,
    );

    if (previous != null &&
        period != null &&
        RegExp('^$_ending\$').hasMatch(rest)) {
      return RecordLookup(
        start: start,
        end: end,
        fromMinute: hasTime ? from : previous.fromMinute,
        untilMinute: hasTime ? until : previous.untilMinute,
        kind: previous.kind,
        item: previous.item,
        requiredField: previous.requiredField,
        intakeStatus: previous.intakeStatus,
      );
    }
    if (RegExp('^(?:기록|내역)\\s*$_ending\$').hasMatch(rest)) return make();
    if (quotedItem != null &&
        quotedItem.trim().isNotEmpty &&
        RegExp('^\uE000\\s*(?:기록|내역)?\\s*$_ending\$').hasMatch(rest)) {
      return make(item: quotedItem);
    }
    for (final entry in _subjects.entries) {
      if (RegExp(
        '^(?:${entry.key.replaceAll(' ', r'\s+')})\\s*(?:기록|내역)?\\s*$_ending\$',
      ).hasMatch(rest)) {
        final (kind, item, field, status) = entry.value;
        return make(kind: kind, item: item, field: field, status: status);
      }
    }
    // Unquoted medicine names are exact, never substring/fuzzy dose matches.
    final named = RegExp('^(.{1,200}?)\\s+(?:복약|복용)\\s*(?:기록|내역)\\s*$_ending\$')
        .firstMatch(rest);
    if (named != null &&
        !RegExp(r'말고|그리고|또는|빼고|아침|점심|저녁|새벽|밤|엄마|아빠|어머니|아버지|["?]')
            .hasMatch(named[1]!)) {
      return make(kind: EntryKind.medicationIntake, item: named[1]!.trim());
    }
    return null;
  }
}
