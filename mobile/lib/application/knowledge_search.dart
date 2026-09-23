import '../domain/knowledge.dart';

/// Explicit, inspectable query expansion. This is a lexical retrieval baseline,
/// not a trained embedding model or a clinical translation of source content.
final class KnowledgeSearch {
  const KnowledgeSearch(this.reader);
  final KnowledgeReviewReader reader;
  static const topics = <String, List<String>>{
    'falls': ['낙상', '넘어', '미끄러', 'fall', 'falls', 'falling'],
    'pressure': [
      '욕창',
      '피부 눌',
      '오래 누워',
      'pressure ulcer',
      'pressure injury',
      'pressure sores',
      'bedsores',
    ],
    'swallowing': ['삼키', '사레', '연하', 'swallow', 'swallowing', 'dysphagia'],
    'nutrition': [
      '식사',
      '음식',
      '영양',
      '먹지 못',
      '식욕',
      '밥',
      '먹을 때',
      'nutrition',
      'eating',
      'food',
    ],
    'caregiver': [
      '역할을 나',
      '가족끼리',
      '간병 분담',
      'sharing caregiving',
      '간병 스트레스',
      '너무 지쳐',
      '돌보다 지',
      '간병 부담',
      'caregiver stress',
      'caregiver burden',
      'responsibilities',
      'stress',
      'respite',
    ],
    'starting': ['처음 간병', '간병을 시작', '돌봄을 시작', 'getting started'],
    'dry-mouth': ['입이 마르', '입 마름', '구강 건조', 'dry mouth'],
    'brushing': ['양치', '칫솔', '이 닦', '이를 닦', 'brushing'],
    'flossing': ['치실', 'flossing'],
    'discharge': ['퇴원', '집에 돌아', 'discharge', 'going home'],
    'medicine': ['약 관리', '약 정리', '복약', 'medication', 'medicine'],
    'dementia': ['치매', '기억력', 'dementia', 'alzheimer'],
    'hygiene': [
      '씻기',
      '씻길',
      '씻겨',
      '목욕',
      '위생',
      'bathing',
      'hygiene',
      'keep clean',
    ],
    'mobility': ['이동', '침대에서', '일으켜', '옮기', 'transfer', 'mobility'],
  };

  static Set<String> concepts(String question) {
    final q = question.toLowerCase();
    return {
      for (final e in topics.entries)
        if (e.value.any((term) => q.contains(term))) e.key,
    };
  }

  Future<List<KnowledgeSearchResult>> search(String question) async {
    if (question.trim().isEmpty || question.length > 1200) return [];
    final conceptsFound = concepts(question);
    final queries = <String>{
      for (final topic in conceptsFound) ...topics[topic]!,
      ...RegExp(r'[a-zA-Z]{3,}|[가-힣]{2,}')
          .allMatches(question)
          .take(8)
          .map((m) => m[0]!),
    };
    final pages = <String, KnowledgeHit>{};
    for (final query in queries.take(32)) {
      for (final hit in await reader.searchDocuments(query)) {
        pages['${hit.citation.sourceId}:${hit.citation.pageNumber}'] = hit;
      }
    }
    // Titles are not in the contentless FTS table. Include title matches,
    // especially Korean PDFs whose extracted body has spaced Hangul glyphs.
    for (final source in await reader.sources()) {
      if (!queries.any(
        (q) => source.title.toLowerCase().contains(q.toLowerCase()),
      )) {
        continue;
      }
      for (var page = 1; page <= source.pageCount && page <= 10; page++) {
        pages.putIfAbsent(
          '${source.id}:$page',
          () => KnowledgeHit(
            source.title,
            KnowledgeCitation(
              packageHash: reader.packageHash,
              sourceId: source.id,
              pageNumber: page,
              textHash: '',
            ),
          ),
        );
      }
    }
    final results = <KnowledgeSearchResult>[];
    for (final hit in pages.values.take(30)) {
      final page = await reader.document(
        hit.citation.sourceId,
        hit.citation.pageNumber,
      );
      final terms = queries.map((q) => q.toLowerCase()).toSet();
      // Bounded paragraphs/line groups are discovery snippets, not approved
      // answers. The viewer always provides the complete original page.
      for (final span in _spans(page.text)) {
        final text = page.text.substring(span.$1, span.$2);
        final normalized = text.toLowerCase();
        final matched = terms.where(normalized.contains).length;
        final titleMatches = terms
            .where(page.source.title.toLowerCase().contains)
            .length;
        if (matched == 0 && titleMatches == 0) continue;
        final score = matched.toDouble() + titleMatches * .75;
        results.add(
          KnowledgeSearchResult(
            page.source,
            KnowledgeCitation(
              packageHash: reader.packageHash,
              sourceId: page.source.id,
              pageNumber: hit.citation.pageNumber,
              textHash: page.citation.textHash,
              excerpt: text,
              excerptStart: span.$1,
            ),
            score,
          ),
        );
      }
    }
    results.sort((a, b) {
      final score = b.score.compareTo(a.score);
      return score != 0
          ? score
          : '${a.citation.sourceId}:${a.citation.pageNumber}:${a.citation.excerptStart}'
                .compareTo(
                  '${b.citation.sourceId}:${b.citation.pageNumber}:${b.citation.excerptStart}',
                );
    });
    return results.take(12).toList();
  }

  Iterable<(int, int)> _spans(String text) sync* {
    final paragraphs = RegExp(r'[^\r\n]+(?:\r?\n(?!\r?\n)[^\r\n]+)*')
        .allMatches(text);
    for (final paragraph in paragraphs) {
      if (paragraph[0]!.trim().isEmpty) continue;
      if (paragraph.end - paragraph.start <= 1200) {
        yield (paragraph.start, paragraph.end);
        continue;
      }
      int? start;
      var end = paragraph.start;
      for (final line in RegExp(r'[^\r\n]+').allMatches(paragraph[0]!)) {
        final from = paragraph.start + line.start;
        final to = paragraph.start + line.end;
        if (start != null && to - start > 1000) {
          yield (start, end);
          start = null;
        }
        if (to - from > 1200) continue;
        start ??= from;
        end = to;
      }
      if (start != null) yield (start, end);
    }
  }
}

final class KnowledgeSearchResult {
  const KnowledgeSearchResult(this.source, this.citation, this.score);
  final KnowledgeSource source;
  final KnowledgeCitation citation;
  final double score;
}
