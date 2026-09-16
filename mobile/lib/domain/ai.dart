import 'dart:convert';
import 'dart:typed_data';

import 'record_lookup.dart';

enum AiReplyKind {
  records,
  noRecords,
  clarify,
  medicalHold,
  urgent,
  notebookScope,
  unavailable,
}

final class AiReference {
  const AiReference(this.id, this.version);
  final String id;
  final int version;
  Map<String, Object> toJson() => {'id': id, 'version': version};
}

final class AiReply {
  AiReply(
    this.kind, {
    List<AiReference> sources = const [],
    this.model = '',
    this.lookup,
    this.hasMore = false,
  }) : sources = List.unmodifiable(sources);
  final AiReplyKind kind;
  final List<AiReference> sources;
  final String model;
  final RecordLookup? lookup;
  final bool hasMore;
  String encode() => jsonEncode({
    'kind': kind.name,
    'sources': sources.map((e) => e.toJson()).toList(),
    'model': model,
    if (lookup != null) 'lookup': lookup!.toJson(),
    if (hasMore) 'hasMore': true,
  });
  static AiReply decode(String value) {
    if (value.length > 8192) throw const FormatException('reply too large');
    final data = jsonDecode(value);
    if (data is! Map ||
        !data.keys.toSet().containsAll(['kind', 'sources', 'model']) ||
        data.keys.any(
          (k) => !const [
            'kind',
            'sources',
            'model',
            'lookup',
            'hasMore',
          ].contains(k),
        ) ||
        data['sources'] is! List ||
        data['model'] is! String) {
      throw const FormatException('invalid reply');
    }
    final kind = AiReplyKind.values
        .where((k) => k.name == data['kind'])
        .firstOrNull;
    if (kind == null ||
        (data['sources'] as List).length > 8 ||
        (data['model'] as String).length > 100) {
      throw const FormatException('invalid reply');
    }
    final sources = <AiReference>[];
    for (final row in data['sources'] as List) {
      if (row is! Map ||
          row.length != 2 ||
          row['id'] is! String ||
          (row['id'] as String).isEmpty ||
          (row['id'] as String).length > 100 ||
          row['version'] is! int ||
          row['version'] < 1) {
        throw const FormatException('invalid source');
      }
      sources.add(AiReference(row['id'] as String, row['version'] as int));
    }
    if (sources.map((e) => e.id).toSet().length != sources.length ||
        (kind != AiReplyKind.records && sources.isNotEmpty) ||
        (kind == AiReplyKind.records && sources.isEmpty)) {
      throw const FormatException('invalid sources');
    }
    final lookup = data.containsKey('lookup')
        ? RecordLookup.fromJson(data['lookup'])
        : null;
    if ((lookup != null &&
            kind != AiReplyKind.records &&
            kind != AiReplyKind.noRecords) ||
        (data.containsKey('hasMore') && data['hasMore'] is! bool) ||
        (data['hasMore'] == true && (lookup == null || sources.length != 8))) {
      throw const FormatException('invalid lookup reply');
    }
    return AiReply(
      kind,
      sources: sources,
      model: data['model'] as String,
      lookup: lookup,
      hasMore: data['hasMore'] == true,
    );
  }
}

enum AiFailure {
  unavailable,
  busy,
  cancelled,
  invalidInput,
  modelInvalid,
  failed,
  microphoneDenied,
  noSpeech,
}

final class AiException implements Exception {
  const AiException(this.code);
  final AiFailure code;
  @override
  String toString() => 'AiException(${code.name})';
}

final class AiModelStatus {
  const AiModelStatus({
    this.installed = false,
    this.supported = true,
    this.version = '',
    this.bytes = 0,
  });
  final bool installed, supported;
  final String version;
  final int bytes;
}

final class OcrLine {
  const OcrLine(this.text, this.confidence, this.box);
  final String text;
  final double confidence;

  /// Normalized image coordinates, x1/y1/x2/y2.
  final List<double> box;
}

final class OcrDraft {
  OcrDraft(List<OcrLine> lines) : lines = List.unmodifiable(lines);
  final List<OcrLine> lines;
  String get text => lines.map((e) => e.text).join('\n');
}

abstract interface class MicrophoneCapture {
  Future<void> start(void Function() full);
  Future<Float32List> stop();
  Future<void> dispose();
}

abstract interface class LocalAiRuntime {
  Future<AiModelStatus> status();
  Future<String?> pickBundle();
  Future<void> installBundle(String path, void Function(double) progress);
  Future<void> removeModels();
  Future<String> extractQuery(String question, String language);
  Future<OcrDraft> recognize(Uint8List image, String language);
  Future<String> transcribe(Float32List samples, String language);
  void cancel();
  Future<void> dispose();
}

final class UnavailableAiRuntime implements LocalAiRuntime {
  const UnavailableAiRuntime();
  @override
  Future<AiModelStatus> status() async => const AiModelStatus(supported: false);
  @override
  Future<String?> pickBundle() async => null;
  @override
  Future<void> removeModels() async {}
  @override
  Future<void> installBundle(
    String path,
    void Function(double) progress,
  ) async => throw const AiException(AiFailure.unavailable);
  @override
  Future<String> extractQuery(String question, String language) async =>
      throw const AiException(AiFailure.unavailable);
  @override
  Future<OcrDraft> recognize(Uint8List image, String language) async =>
      throw const AiException(AiFailure.unavailable);
  @override
  Future<String> transcribe(Float32List samples, String language) async =>
      throw const AiException(AiFailure.unavailable);
  @override
  void cancel() {}
  @override
  Future<void> dispose() async {}
}
