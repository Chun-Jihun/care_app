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
  late Map<String, dynamic> fixture, manifest;
  String path(String name) => p.join(directory.path, name);
  Future<void> refreshManifest() async {
    final file = File(path('knowledge.sqlite3'));
    manifest['database_bytes'] = await file.length();
    manifest['database_sha256'] = (await sha256.bind(file.openRead()).first)
        .toString();
    await File(path('manifest.json')).writeAsString(jsonEncode(manifest));
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('care-packed-test-');
    fixture = jsonDecode(
      await File('test/fixtures/knowledge_pack_v2.json').readAsString(),
    ) as Map<String, dynamic>;
    manifest = Map<String, dynamic>.from(fixture['manifest'] as Map);
    createKnowledgeFixtureDatabase(File(path('knowledge.sqlite3')), fixture);
    await refreshManifest();
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('partial product names never identify a product; exact full names and codes can', () async {
    final reader = await LocalKnowledgePackage.openForReview(directory.path);
    final exact = await reader.findDrugName('Synthetic product');
    expect(exact.identified?.code, 'TEST-1');
    expect((await reader.findDrugName('Synthetic')).identified, isNull);
    expect(
      (await reader.findDrugName('TEST-1')).identified?.name,
      'Synthetic product',
    );
    expect(
      (await reader.findDrugName('Synthetic product 500mg')).identified,
      isNull,
    );
    expect((await reader.findDrugName('unknown product')).candidates, isEmpty);
  });

  test(
    'Python v2 fields, Unicode and group boundaries restore exactly in Dart',
    () async {
      final reader = await LocalKnowledgePackage.openForReview(directory.path);
      final expected = Map<String, dynamic>.from(
        fixture['expected_record'] as Map,
      );
      final repeated = expected['CONDITION'] as Map;
      expected['CONDITION'] =
          (repeated['repeat'] as String) * (repeated['times'] as int);
      expect(await reader.drugRecord(1), expected);
      for (final id in [129, 512, 513, 601]) {
        expect((await reader.drugRecord(id))['ITEM_SEQ'], 'ALT${id - 2}');
      }
      expect((await reader.lookupDrug('TEST-2')).single['id'], 1);
      final hits = await reader.lookupDrug('ALT598');
      expect(hits.map((h) => h['id']), [600, 601]);
      expect(hits.last['page_no'], 6);
      expect(hits.last['row_no'], 99);
      expect(await reader.lookupDrug('missing'), isEmpty);
      expect(reader.coverageNotice, '합성 시험용 자료');
      expect(
        () => reader.clinicalContext('anything'),
        throwsA(isA<KnowledgePackageException>()),
      );
      await expectLater(
        reader.drugRecord(602),
        throwsA(isA<KnowledgePackageException>()),
      );
    },
  );

  test(
    'editing supported scope cannot turn the basic catalog into full coverage',
    () async {
      (manifest['coverage'] as Map)['prescription_details_included'] = true;
      await refreshManifest();
      await expectLater(
        LocalKnowledgePackage.openForReview(directory.path),
        throwsA(isA<KnowledgePackageException>()),
      );
    },
  );

  test(
    'invalid delta index fails closed instead of returning a different item',
    () async {
      final db = sqlite3.open(path('knowledge.sqlite3'));
      db.execute('UPDATE drug_lookup SET record_ids=? WHERE item_seq=?', [
        Uint8List.fromList([128]),
        'TEST-2',
      ]);
      db.close();
      await refreshManifest();
      final reader = await LocalKnowledgePackage.openForReview(directory.path);
      await expectLater(
        reader.lookupDrug('TEST-2'),
        throwsA(isA<KnowledgePackageException>()),
      );
    },
  );
}
