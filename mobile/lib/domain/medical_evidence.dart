import 'knowledge.dart';

enum EvidenceHold {
  unreviewed,
  insufficient,
  conflicting,
  expired,
  invalid,
  restricted,
}

/// Review rules are application-owned. Import manifests cannot create them.
/// An answer group denotes passages reviewed TOGETHER for a specific question.
final class ReviewedPassage {
  ReviewedPassage({
    required this.id,
    required this.answerGroup,
    required this.citation,
    required this.reviewedAt,
    required this.expiresAt,
    required List<String> questions,
  }) : questions = List.unmodifiable(questions);
  final String id, answerGroup;
  final KnowledgeCitation citation;
  final DateTime reviewedAt, expiresAt;
  final List<String> questions;
}

abstract interface class EvidenceSelector {
  /// Returns JSON {"evidence_ids":[...]}, never free-form medical advice.
  Future<String> selectEvidence(
    String question,
    List<ReviewedPassage> passages,
  );
}

abstract interface class MedicalEvidenceCatalog {
  Future<List<ReviewedPassage>> passages();
  Future<KnowledgeReviewReader?> reader(String packageHash);
}

final class EmptyMedicalEvidenceCatalog implements MedicalEvidenceCatalog {
  const EmptyMedicalEvidenceCatalog();
  @override
  Future<List<ReviewedPassage>> passages() async => const [];
  @override
  Future<KnowledgeReviewReader?> reader(String packageHash) async => null;
}

final class EvidenceAnswer {
  EvidenceAnswer({this.hold, List<KnowledgeCitation> citations = const []})
    : citations = List.unmodifiable(citations);
  final EvidenceHold? hold;
  final List<KnowledgeCitation> citations;
}
