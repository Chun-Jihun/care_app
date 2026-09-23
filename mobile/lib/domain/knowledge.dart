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

  bool matches(KnowledgeCitation other) =>
      packageHash == other.packageHash &&
      sourceId == other.sourceId &&
      pageNumber == other.pageNumber &&
      textHash == other.textHash &&
      excerpt == other.excerpt &&
      excerptStart == other.excerptStart;

  Map<String, Object?> toJson() => {
    'packageHash': packageHash,
    'sourceId': sourceId,
    'pageNumber': pageNumber,
    'textHash': textHash,
    'excerpt': excerpt,
    'excerptStart': excerptStart,
  };

  static KnowledgeCitation fromJson(Object? value) {
    if (value is! Map ||
        value.length != 6 ||
        value['packageHash'] is! String ||
        value['textHash'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['packageHash'] as String) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['textHash'] as String) ||
        value['sourceId'] is! String ||
        (value['sourceId'] as String).isEmpty ||
        (value['sourceId'] as String).length > 200 ||
        value['pageNumber'] is! int ||
        value['pageNumber'] < 1 ||
        value['pageNumber'] > 10000 ||
        value['excerpt'] is! String ||
        (value['excerpt'] as String).isEmpty ||
        (value['excerpt'] as String).length > 1200 ||
        value['excerptStart'] is! int ||
        value['excerptStart'] < 0 ||
        value['excerptStart'] > 16000000) {
      throw const FormatException('invalid citation');
    }
    return KnowledgeCitation(
      packageHash: value['packageHash'] as String,
      sourceId: value['sourceId'] as String,
      pageNumber: value['pageNumber'] as int,
      textHash: value['textHash'] as String,
      excerpt: value['excerpt'] as String,
      excerptStart: value['excerptStart'] as int,
    );
  }
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

/// Read-only document access. A reader alone never grants clinical authorization.
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
