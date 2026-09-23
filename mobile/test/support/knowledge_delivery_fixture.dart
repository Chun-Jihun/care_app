import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:care_notebook/domain/knowledge.dart';
import 'package:care_notebook/domain/knowledge_installation.dart';
import 'package:care_notebook/domain/medical_evidence.dart';
import 'package:care_notebook/infrastructure/knowledge_package.dart';
import 'package:care_notebook/infrastructure/knowledge_store.dart';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'knowledge_fixture.dart';

const syntheticQuestion = '자꾸 넘어질까 걱정돼요';
const syntheticText =
    'Fall prevention is a SYNTHETIC TEST topic. Preserve all conditions and exceptions.';

Future<({KnowledgeRelease release, File bundle, KnowledgeCitation citation})>
makeDelivery(
  Directory root,
  String version, {
  bool approved = false,
  String body = syntheticText,
}) async {
  final dir = await Directory('${root.path}/$version/documents')
      .create(recursive: true);
  final fixture = jsonDecode(
    await File('test/fixtures/knowledge_pack_v1.json').readAsString(),
  ) as Map<String, dynamic>;
  final manifest = Map<String, dynamic>.from(fixture['manifest'] as Map);
  final database = File('${dir.path}/knowledge.sqlite3');
  createKnowledgeFixtureDatabase(database, fixture);
  final db = sqlite3.open(database.path);
  try {
    final raw = utf8.encode(body);
    final digest = sha256.convert(raw).toString();
    final blob = db
        .select('SELECT text_blob FROM document_pages WHERE id=1')
        .single['text_blob'];
    db.execute('UPDATE blobs SET sha256=?,raw_size=?,payload=? WHERE id=?', [
      digest,
      raw.length,
      Uint8List.fromList(zlib.encode(raw)),
      blob,
    ]);
    db.execute('UPDATE document_pages SET text_sha256=? WHERE id=1', [digest]);
    db.execute(
      "INSERT INTO document_search(document_search) VALUES ('delete-all')",
    );
    db.execute('INSERT INTO document_search(rowid,text) VALUES (1,?)', [body]);
    final metadata = jsonDecode(
      db
              .select("SELECT value FROM metadata WHERE key='package'")
              .single['value']
          as String,
    ) as Map<String, dynamic>;
    metadata['synthetic_test_version'] = version;
    if (approved) {
      metadata.addAll({
        'purpose': 'medical_reference',
        'approval_state': 'approved',
        'clinical_review_completed': true,
        'runtime_rag_eligible': true,
        'mobile_bundle': true,
      });
      final source = jsonDecode(
        db
                .select("SELECT metadata FROM sources WHERE id='synthetic'")
                .single['metadata']
            as String,
      ) as Map;
      source['clinical_reviewed_at'] = '2026-01-01';
      db.execute("UPDATE sources SET metadata=? WHERE id='synthetic'", [
        jsonEncode(source),
      ]);
    }
    db.execute("UPDATE metadata SET value=? WHERE key='package'", [
      jsonEncode(metadata),
    ]);
    manifest.addAll(metadata);
  } finally {
    db.close();
  }
  manifest['database_bytes'] = await database.length();
  manifest['database_sha256'] = (await sha256.bind(database.openRead()).first)
      .toString();
  await File('${dir.path}/manifest.json').writeAsString(jsonEncode(manifest));
  final files = <Map<String, Object>>[];
  final payload = BytesBuilder();
  for (final name in ['manifest.json', 'knowledge.sqlite3']) {
    final bytes = await File('${dir.path}/$name').readAsBytes();
    files.add({
      'path': 'documents/$name',
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    });
    payload.add(bytes);
  }
  final raw = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'schema': 'care-knowledge-delivery-v1',
        'version': version,
        'preview': !approved,
        'checked_at': '2026-01-01T00:00:00Z',
        'recheck_after': '2099-01-01T00:00:00Z',
        'files': files,
      }),
    ),
  );
  final header = ByteData(12)
    ..buffer.asUint8List().setRange(0, 8, ascii.encode('CAREKB01'));
  header.setUint32(8, raw.length, Endian.little);
  final bundle = File('${root.path}/$version.careknowledge');
  await bundle.writeAsBytes([
    ...header.buffer.asUint8List(),
    ...raw,
    ...payload.takeBytes(),
  ]);
  final reader = approved
      ? await LocalKnowledgePackage.openApproved(
          dir.path,
          expectedHash: manifest['database_sha256'] as String,
        )
      : await LocalKnowledgePackage.openForReview(dir.path);
  final page = await reader.document('synthetic', 1);
  return (
    release: KnowledgeRelease(raw),
    bundle: bundle,
    citation: KnowledgeCitation(
      packageHash: reader.packageHash,
      sourceId: 'synthetic',
      pageNumber: 1,
      textHash: page.citation.textHash,
      excerpt: body,
      excerptStart: 0,
    ),
  );
}

class TestKnowledgeLibrary implements KnowledgeLibrary {
  TestKnowledgeLibrary(this.store);
  final KnowledgeStore store;
  @override
  Future<KnowledgeInstallation> status() => store.status();
  @override
  Future<String?> pickBundle() async => null;
  @override
  Future<void> install(
    String path,
    void Function(double) progress,
    void Function() check,
  ) => store.install(path, progress, check);
  @override
  Future<void> rollback() => store.rollback();
  @override
  Future<KnowledgeReviewReader?> reader({String? packageHash}) =>
      store.reader(packageHash: packageHash);
}

ReviewedPassage syntheticPassage(
  KnowledgeCitation citation, {
  String id = 'test-1',
  String group = 'synthetic-falls',
  DateTime? expires,
}) => ReviewedPassage(
  id: id,
  answerGroup: group,
  citation: citation,
  reviewedAt: DateTime.utc(2026),
  expiresAt: expires ?? DateTime.utc(2099),
  questions: const [syntheticQuestion, '낙상이 걱정돼요'],
);
