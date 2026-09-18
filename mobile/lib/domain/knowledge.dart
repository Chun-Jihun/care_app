import 'dart:typed_data';

/// A citation identifies immutable content, never a model-generated URL/page.
class KnowledgeCitation {
  const KnowledgeCitation({
    required this.packageHash,
    required this.sourceId,
    required this.pageNumber,
    required this.textHash,
    this.excerpt,
    this.excerptStart,
  });
  final String packageHash;
  final String sourceId;
  final int pageNumber;
  final String textHash;
  final String? excerpt;

  /// UTF-16 code-unit offset in the exact, hash-verified page text.
  final int? excerptStart;
}

class KnowledgeSource {
  const KnowledgeSource({
    required this.id,
    required this.title,
    required this.publisher,
    required this.url,
    required this.version,
    required this.pageCount,
    this.publicationDate,
    this.reviewDate,
    this.rasterDpi,
  });
  final String id, title, publisher, url, version;
  final String? publicationDate, reviewDate;
  final int pageCount;
  final int? rasterDpi;
}

class KnowledgeAsset {
  const KnowledgeAsset(this.bytes, this.description);
  final Uint8List bytes;
  final String description;
}

class KnowledgeDocument {
  KnowledgeDocument({
    required this.source,
    required this.citation,
    required this.text,
    this.pageImage,
    List<KnowledgeAsset> assets = const [],
  }) : assets = List.unmodifiable(assets);
  final KnowledgeSource source;
  final KnowledgeCitation citation;
  final String text;
  final Uint8List? pageImage;
  final List<KnowledgeAsset> assets;
}

class KnowledgeHit {
  const KnowledgeHit(this.title, this.citation);
  final String title;
  final KnowledgeCitation citation;
}

/// Deliberately separate from LocalAiRuntime and approved medical retrieval.
abstract interface class KnowledgeReviewReader {
  String get packageHash;
  String get kind;
  Future<List<KnowledgeSource>> sources();
  Future<List<KnowledgeHit>> searchDocuments(String query);
  Future<KnowledgeDocument> document(String sourceId, int pageNumber);
  Future<KnowledgeDocument> resolve(KnowledgeCitation citation);
}

class KnowledgePackageException implements Exception {
  const KnowledgePackageException(this.message);
  final String message;
  @override
  String toString() => message;
}
