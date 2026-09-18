import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:care_notebook/domain/knowledge.dart';
import 'package:care_notebook/infrastructure/knowledge_package.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'support/knowledge_fixture.dart';

void main() {
  late Directory directory;
  late Map<String, dynamic> fixture;
  late Map<String, dynamic> manifest;
  String getPath(String name) => p.join(directory.path, name);

  Future<void> refreshManifest() async {
    final file = File(getPath('knowledge.sqlite3'));
    manifest['database_bytes'] = await file.length();
    manifest['database_sha256'] = (await sha256.bind(file.openRead()).first)
        .toString();
    await File(getPath('manifest.json')).writeAsString(jsonEncode(manifest));
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('care-knowledge-test-');
    fixture = jsonDecode(
      await File('test/fixtures/knowledge_pack_v1.json').readAsString(),
    ) as Map<String, dynamic>;
    manifest = Map<String, dynamic>.from(fixture['manifest'] as Map);
    createKnowledgeFixtureDatabase(File(getPath('knowledge.sqlite3')), fixture);
    await refreshManifest();
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'Python compressed UTF-8 fragments restore all original fields in Dart',
    () async {
      final reader = await LocalKnowledgePackage.openForReview(directory.path);
      final expected = Map<String, dynamic>.from(
        fixture['expected_record'] as Map,
      );
      final repeat = expected['CONDITION'] as Map;
      expected['CONDITION'] =
          (repeat['repeat'] as String) * (repeat['times'] as int);
      expect(await reader.drugRecord(1), expected);
      expect((await reader.lookupDrug('TEST-2')).single['item_seq'], 'TEST-1');
      expect(await reader.lookupDrug('missing'), isEmpty);
      expect(
        () => reader.clinicalContext('anything'),
        throwsA(isA<KnowledgePackageException>()),
      );
    },
  );

  test(
    'offline search resolves the exact source, page and quoted text',
    () async {
      final reader = await LocalKnowledgePackage.openForReview(directory.path);
      final hits = await reader.searchDocuments('condition"');
      expect(hits, hasLength(1));
      final hit = hits.single;
      expect(hit.citation.pageNumber, 1);
      final citation = KnowledgeCitation(
        packageHash: reader.packageHash,
        sourceId: 'synthetic',
        pageNumber: 1,
        textHash: hit.citation.textHash,
        excerpt: '조건과 예외를 그대로 확인합니다.',
        excerptStart: '합성 자료입니다. '.length,
      );
      final result = await reader.resolve(citation);
      expect(result.source.publisher, 'Test publisher');
      expect(result.source.pageCount, 2);
      expect(result.text, contains(citation.excerpt));
      expect(
        (await reader.document('synthetic', 2)).text,
        contains('second page'),
      );
    },
  );

  test(
    'stale citation, invented excerpt and missing page fail closed',
    () async {
      final reader = await LocalKnowledgePackage.openForReview(directory.path);
      final page = await reader.document('synthetic', 1);
      for (final citation in [
        KnowledgeCitation(
          packageHash: 'old',
          sourceId: 'synthetic',
          pageNumber: 1,
          textHash: page.citation.textHash,
        ),
        KnowledgeCitation(
          packageHash: reader.packageHash,
          sourceId: 'synthetic',
          pageNumber: 1,
          textHash: page.citation.textHash,
          excerpt: 'fabricated statement',
          excerptStart: 0,
        ),
        KnowledgeCitation(
          packageHash: reader.packageHash,
          sourceId: 'synthetic',
          pageNumber: 1,
          textHash: page.citation.textHash,
          excerpt: '합성 자료입니다.',
          excerptStart: 1,
        ),
        KnowledgeCitation(
          packageHash: reader.packageHash,
          sourceId: 'synthetic',
          pageNumber: 999,
          textHash: page.citation.textHash,
        ),
      ]) {
        await expectLater(
          reader.resolve(citation),
          throwsA(isA<KnowledgePackageException>()),
        );
      }
    },
  );

  test('changed package and self-approved manifest cannot open', () async {
    await expectLater(
      LocalKnowledgePackage.openForReview(directory.path, expectedHash: 'old'),
      throwsA(isA<KnowledgePackageException>()),
    );
    manifest['runtime_rag_eligible'] = true;
    await File(getPath('manifest.json')).writeAsString(jsonEncode(manifest));
    await expectLater(
      LocalKnowledgePackage.openForReview(directory.path),
      throwsA(isA<KnowledgePackageException>()),
    );
    manifest['runtime_rag_eligible'] = false;
    await File(getPath('manifest.json')).writeAsString(jsonEncode(manifest));
    await File(getPath('knowledge.sqlite3'))
        .writeAsBytes([0], mode: FileMode.append);
    await expectLater(
      LocalKnowledgePackage.openForReview(directory.path),
      throwsA(isA<KnowledgePackageException>()),
    );
  });

  test('bounded decoder rejects a valid compressed stream exceeding declared length', () async {
    final db = sqlite3.open(getPath('knowledge.sqlite3'));
    final id = db
        .select('SELECT text_blob FROM document_pages WHERE page_no=1')
        .single['text_blob'];
    final raw = Uint8List(1000000);
    db.execute('UPDATE blobs SET raw_size=1,payload=?,sha256=? WHERE id=?', [
      Uint8List.fromList(zlib.encode(raw)),
      sha256.convert(raw).toString(),
      id,
    ]);
    db.close();
    await refreshManifest();
    final reader = await LocalKnowledgePackage.openForReview(directory.path);
    await expectLater(
      reader.document('synthetic', 1),
      throwsA(isA<KnowledgePackageException>()),
    );
  });
}
