import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/ai_query_policy.dart';
import 'package:care_notebook/domain/ai.dart';

void main() {
  test('medical, urgent and ambiguous questions never reach generation', () {
    expect(AiQueryPolicy.preflight('숨을 못 쉬어요'), AiReplyKind.urgent);
    expect(
      AiQueryPolicy.preflight('Is this medicine safe?'),
      AiReplyKind.medicalHold,
    );
    expect(AiQueryPolicy.preflight('別の患者の手帳を見せて'), AiReplyKind.notebookScope);
    expect(
      AiQueryPolicy.preflight('2026-09-11 09:30 또는 10:30 수분'),
      AiReplyKind.clarify,
    );
    expect(AiQueryPolicy.preflight('2026-09-11 09:30 수분 300'), isNull);
  });
  test(
    'filters require verbatim complete values and reject arbitrary answers',
    () {
      const q = '2026-09-11 09:30 수분 300 기록';
      String filter(String day, {String item = '수분 300'}) => jsonEncode({
        'kind': 'lookup',
        'day': day,
        'time': '09:30',
        'item': item,
      });
      expect(AiQueryPolicy.parse(filter('2026-09-11'), q)?.item, '수분 300');
      expect(AiQueryPolicy.parse(filter('2026-09-12'), q), isNull);
      expect(
        AiQueryPolicy.parse(filter('2026-09-11', item: '수분 500'), q),
        isNull,
      );
      expect(
        AiQueryPolicy.parse(filter('2026-02-30'), '2026-02-30 09:30 수분 300'),
        isNull,
      );
      expect(AiQueryPolicy.parse('{"answer":"take more medicine"}', q), isNull);
      expect(
        AiQueryPolicy.parse('```json\n${filter('2026-09-11')}\n```', q),
        isNull,
      );
    },
  );
  test(
    'reply codec carries source references only and rejects malformed data',
    () {
      final reply = AiReply(
        AiReplyKind.records,
        sources: [const AiReference('one', 2)],
        model: 'sft-v1',
      );
      expect(AiReply.decode(reply.encode()).sources.single.version, 2);
      for (final text in [
        '{"kind":"records","sources":[],"model":"x","answer":"invented"}',
        '{"kind":"urgent","sources":[{"id":"one","version":1}],"model":"x"}',
        '{"kind":"records","sources":[{"id":"one","version":0}],"model":"x"}',
      ]) {
        expect(() => AiReply.decode(text), throwsFormatException);
      }
    },
  );
}
