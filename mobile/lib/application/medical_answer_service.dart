import 'dart:convert';

import '../domain/knowledge.dart';
import '../domain/medical_evidence.dart';

/// Fail-closed, extractive RAG. Only reviewed question/passage pairs are eligible.
/// Raw discovery search results never confer clinical authorization.
final class MedicalAnswerService {
  const MedicalAnswerService(this.catalog, this.selector);
  final MedicalEvidenceCatalog catalog;
  final EvidenceSelector selector;
  static String _normalize(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[?!？。!]+$'), '');
  static final _restricted = RegExp(
    r'진단|용량|같이\s*먹|병용|중단|더\s*먹|처방.*변경|약.*바꿔|상호작용|diagnos|dose|interaction|prescrib|stop.*medic|用量|診断|剂量|劑量|诊断|診斷',
    caseSensitive: false,
  );

  Future<EvidenceAnswer> answer(String question, {DateTime? now}) async {
    try {
      return await _answer(question, now: now);
    } on Object {
      return EvidenceAnswer(hold: EvidenceHold.invalid);
    }
  }

  Future<EvidenceAnswer> _answer(String question, {DateTime? now}) async {
    if (_restricted.hasMatch(question)) {
      return EvidenceAnswer(hold: EvidenceHold.restricted);
    }
    if (question.length > 1200 ||
        question.contains('<|') ||
        question.contains('|>')) {
      return EvidenceAnswer(hold: EvidenceHold.invalid);
    }
    final all = await catalog.passages();
    if (all.isEmpty) return EvidenceAnswer(hold: EvidenceHold.unreviewed);
    final key = _normalize(question);
    // Deliberately require a reviewed equivalent question. Keyword matches alone
    // cannot establish patient applicability or completeness of medical evidence.
    final candidates = all
        .where((p) => p.questions.any((q) => _normalize(q) == key))
        .toList();
    if (candidates.isEmpty || candidates.length > 3) {
      return EvidenceAnswer(hold: EvidenceHold.insufficient);
    }
    final time = (now ?? DateTime.now()).toUtc();
    if (candidates.any(
      (p) => time.isBefore(p.reviewedAt) || !time.isBefore(p.expiresAt),
    )) {
      return EvidenceAnswer(hold: EvidenceHold.expired);
    }
    if (candidates.map((p) => p.answerGroup).toSet().length != 1) {
      return EvidenceAnswer(hold: EvidenceHold.conflicting);
    }
    if (candidates.map((p) => p.id).toSet().length != candidates.length ||
        candidates.map((p) => jsonEncode(p.citation.toJson())).toSet().length !=
            candidates.length) {
      return EvidenceAnswer(hold: EvidenceHold.invalid);
    }
    try {
      for (final p in candidates) {
        final c = p.citation;
        KnowledgeCitation.fromJson(c.toJson());
        if (!RegExp(r'^[a-zA-Z0-9._-]{1,64}$').hasMatch(p.id)) {
          return EvidenceAnswer(hold: EvidenceHold.invalid);
        }
        if (c.excerpt == null ||
            c.excerpt!.isEmpty ||
            c.excerpt!.length > 1200 ||
            c.excerpt!.contains('<|') ||
            c.excerpt!.contains('|>')) {
          return EvidenceAnswer(hold: EvidenceHold.invalid);
        }
        final reader = await catalog.reader(c.packageHash);
        if (reader == null) return EvidenceAnswer(hold: EvidenceHold.invalid);
        final doc = await reader.resolve(c);
        final source = doc.source;
        final uri = Uri.tryParse(source.url);
        if (source.title.isEmpty ||
            source.publisher.isEmpty ||
            source.publicationDate == null ||
            source.reviewDate == null ||
            uri?.scheme != 'https' ||
            uri!.host.isEmpty) {
          return EvidenceAnswer(hold: EvidenceHold.invalid);
        }
      }
      final raw = await selector.selectEvidence(question, candidates);
      if (raw.length > 1024) return EvidenceAnswer(hold: EvidenceHold.invalid);
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.length != 1 ||
          value['evidence_ids'] is! List) {
        return EvidenceAnswer(hold: EvidenceHold.invalid);
      }
      final ids = value['evidence_ids'] as List;
      if (ids.isEmpty) return EvidenceAnswer(hold: EvidenceHold.insufficient);
      // All co-reviewed passages are necessary to preserve conditions/exceptions.
      // A model may reorder them, but cannot drop or invent a passage.
      if (ids.length != candidates.length ||
          ids.toSet().length != ids.length ||
          ids.any((id) => !candidates.any((p) => p.id == id))) {
        return EvidenceAnswer(hold: EvidenceHold.invalid);
      }
      // Recheck authorization after inference (updates/revocations may occur).
      final current = await catalog.passages();
      final after = (now ?? DateTime.now()).toUtc();
      if (candidates.any(
        (p) =>
            !after.isBefore(p.expiresAt) ||
            !current.any(
              (v) =>
                  v.id == p.id &&
                  v.citation.matches(p.citation) &&
                  v.reviewedAt == p.reviewedAt &&
                  v.expiresAt == p.expiresAt &&
                  v.answerGroup == p.answerGroup,
            ),
      )) {
        return EvidenceAnswer(hold: EvidenceHold.invalid);
      }
      for (final p in candidates) {
        final reader = await catalog.reader(p.citation.packageHash);
        if (reader == null) return EvidenceAnswer(hold: EvidenceHold.invalid);
        await reader.resolve(p.citation);
      }
      return EvidenceAnswer(
        citations: ids
            .map((id) => candidates.firstWhere((p) => p.id == id).citation)
            .toList(),
      );
    } on Object {
      return EvidenceAnswer(hold: EvidenceHold.invalid);
    }
  }

  Future<KnowledgeReviewReader?> reader(KnowledgeCitation citation) =>
      catalog.reader(citation.packageHash);
}
