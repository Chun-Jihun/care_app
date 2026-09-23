import '../domain/knowledge.dart';
import '../domain/knowledge_installation.dart';
import '../domain/medical_evidence.dart';

/// Separate application-owned clinical allowlist. Package flags alone grant
/// nothing. The production composition currently supplies ZERO reviewed rules.
final class ReviewedKnowledgeCatalog implements MedicalEvidenceCatalog {
  ReviewedKnowledgeCatalog(this.library, List<ReviewedPassage> rules)
    : _rules = List.unmodifiable(rules);
  final KnowledgeLibrary library;
  final List<ReviewedPassage> _rules;

  @override
  Future<List<ReviewedPassage>> passages() async {
    if (_rules.isEmpty) return const [];
    final state = await library.status();
    final active = state.active;
    if (active == null ||
        state.damaged ||
        active.preview ||
        active.stale(DateTime.now())) {
      return const [];
    }
    final hashes = active.files
        .where((f) => f.name == 'documents/knowledge.sqlite3')
        .map((f) => f.sha256)
        .toSet();
    return _rules
        .where((p) => hashes.contains(p.citation.packageHash))
        .toList();
  }

  @override
  Future<KnowledgeReviewReader?> reader(String packageHash) async {
    // Historical citations may be read, but only if their clinical rule is
    // still in the allowlist. New answers can use only the active version.
    if (!_rules.any((p) => p.citation.packageHash == packageHash)) return null;
    final reader = await library.reader(packageHash: packageHash);
    return reader == null ? null : _AuthorizedReader(reader, _rules);
  }
}

final class _AuthorizedReader implements KnowledgeReviewReader {
  _AuthorizedReader(this.inner, this.rules);
  final KnowledgeReviewReader inner;
  final List<ReviewedPassage> rules;
  @override
  String get packageHash => inner.packageHash;
  @override
  String get kind => inner.kind;
  @override
  Future<List<KnowledgeSource>> sources() => inner.sources();
  @override
  Future<List<KnowledgeHit>> searchDocuments(String query) =>
      inner.searchDocuments(query);
  @override
  Future<KnowledgeDocument> document(String sourceId, int pageNumber) =>
      inner.document(sourceId, pageNumber);
  @override
  Future<KnowledgeDocument> resolve(KnowledgeCitation citation) {
    if (!rules.any((p) => p.citation.matches(citation))) {
      throw const KnowledgePackageException('승인 목록에서 해당 발췌를 확인할 수 없습니다.');
    }
    return inner.resolve(citation);
  }
}
