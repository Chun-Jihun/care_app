import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'knowledge.dart';

/// Supplied by the application, never by the file selected for import.
final class KnowledgeRelease {
  KnowledgeRelease(Uint8List bytes)
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView() {
    if (bytes.length > 65536) throw const FormatException('release too large');
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map ||
        value['schema'] != 'care-knowledge-delivery-v1' ||
        value['version'] is! String ||
        value['preview'] is! bool ||
        value['files'] is! List) {
      throw const FormatException('invalid release');
    }
    version = value['version'] as String;
    preview = value['preview'] as bool;
    checkedAt = DateTime.parse(value['checked_at'] as String).toUtc();
    recheckAfter = DateTime.parse(value['recheck_after'] as String).toUtc();
    if (!recheckAfter.isAfter(checkedAt) || version.length > 100) {
      throw const FormatException('invalid release dates');
    }
    files = List.unmodifiable(
      (value['files'] as List).map((f) {
        if (f is! Map ||
            f['path'] is! String ||
            f['bytes'] is! int ||
            f['sha256'] is! String ||
            (f['bytes'] as int) < 1 ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(f['sha256'] as String)) {
          throw const FormatException('invalid release file');
        }
        final name = f['path'] as String;
        if (name != 'manifest.json' &&
            !RegExp(
              r'^(documents|dur|permits|easy-drug)/(manifest\.json|knowledge\.sqlite3)$',
            ).hasMatch(name)) {
          throw const FormatException('invalid release path');
        }
        return KnowledgeReleaseFile(
          name,
          f['bytes'] as int,
          f['sha256'] as String,
        );
      }),
    );
    if (files.isEmpty ||
        files.length > 9 ||
        files.map((f) => f.name).toSet().length != files.length ||
        payloadBytes > 50 * 1024 * 1024) {
      throw const FormatException('invalid release size');
    }
  }
  final Uint8List bytes;
  late final String version;
  late final bool preview;
  late final DateTime checkedAt, recheckAfter;
  late final List<KnowledgeReleaseFile> files;
  String get id => sha256.convert(bytes).toString();
  int get payloadBytes => files.fold(0, (sum, f) => sum + f.bytes);
  bool stale(DateTime now) => !now.toUtc().isBefore(recheckAfter);
}

final class KnowledgeReleaseFile {
  const KnowledgeReleaseFile(this.name, this.bytes, this.sha256);
  final String name, sha256;
  final int bytes;
}

final class KnowledgeInstallation {
  const KnowledgeInstallation({
    this.active,
    this.previous,
    this.damaged = false,
  });
  final KnowledgeRelease? active, previous;
  final bool damaged;
}

abstract interface class KnowledgeLibrary {
  Future<KnowledgeInstallation> status();
  Future<String?> pickBundle();
  Future<void> install(
    String path,
    void Function(double) progress,
    void Function() check,
  );
  Future<void> rollback();
  Future<KnowledgeReviewReader?> reader({String? packageHash});
}
