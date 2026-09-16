import 'dart:convert';

import '../domain/ai.dart';

/// The model extracts filters only. No model-generated answer is displayed.
final class AiQueryPolicy {
  static final _dates = RegExp(r'\b\d{4}-\d{2}-\d{2}\b');
  static final _times = RegExp(r'\b\d{2}:\d{2}\b');
  static final _other = RegExp(
    r'다른\s*(환자|수첩|사람)|다른.*수첩|another.*(patient|notebook)|other.*(patient|notebook)|別の.*(患者|手帳)|另[一個个].*(患者|手册|手冊)',
    caseSensitive: false,
  );
  static final _medical = RegExp(
    r'진단|처방|용량|더\s*먹|같이\s*먹|중단|부작용|안전|추천|증상.*왜|diagnos|dose|prescrib|safe|side.effect|should.I|recommend|用量|診断|中止|安全|副作用|剂量|劑量|诊断|診斷|停用|加倍|推荐|推薦',
    caseSensitive: false,
  );
  // Precautionary escalation for explicit urgent requests, not a clinical classifier.
  static final _urgent = RegExp(
    r'응급|긴급|119|숨을?\s*못\s*쉬|의식이?\s*없|emergency|unconscious|cannot.breathe|can.t.breathe|救急|意識がない|呼吸できない|急救|失去意识|失去意識|无法呼吸|無法呼吸',
    caseSensitive: false,
  );

  static AiReplyKind? guard(String question) {
    if (_urgent.hasMatch(question)) return AiReplyKind.urgent;
    if (_other.hasMatch(question)) return AiReplyKind.notebookScope;
    if (_medical.hasMatch(question)) return AiReplyKind.medicalHold;
    return null;
  }

  static AiReplyKind? preflight(String question) {
    final blocked = guard(question);
    if (blocked != null) return blocked;
    if (_dates.allMatches(question).map((m) => m[0]).toSet().length != 1 ||
        _times.allMatches(question).map((m) => m[0]).toSet().length != 1) {
      return AiReplyKind.clarify;
    }
    return null;
  }

  static QueryFilter? parse(String raw, String question) {
    if (raw.length > 4096) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map ||
          data.length != 4 ||
          !data.keys.toSet().containsAll(['kind', 'day', 'time', 'item'])) {
        return null;
      }
      if (data['kind'] != 'lookup') return null;
      for (final key in ['day', 'time', 'item']) {
        if (data[key] is! String || (data[key] as String).trim().isEmpty) {
          return null;
        }
        data[key] = (data[key] as String).trim();
        if (!question.contains(data[key] as String)) return null;
      }
      final day = data['day'] as String, time = data['time'] as String;
      if (!_dates.hasMatch(day) ||
          day.length != 10 ||
          !_times.hasMatch(time) ||
          time.length != 5) {
        return null;
      }
      final at = DateTime.tryParse('${day}T$time:00');
      if (at == null ||
          '${at.year.toString().padLeft(4, '0')}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}' !=
              day ||
          at.hour != int.parse(time.substring(0, 2)) ||
          at.minute != int.parse(time.substring(3))) {
        return null;
      }
      return QueryFilter(at, data['item'] as String);
    } on Object {
      return null;
    }
  }
}

final class QueryFilter {
  const QueryFilter(this.at, this.item);
  final DateTime at;
  final String item;
}
