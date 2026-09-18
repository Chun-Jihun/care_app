// PC-only probe against actual, locally generated public-data packages.
// Does not expose medical text or open network connections.
import 'dart:convert';
import 'dart:io';

import 'package:care_notebook/infrastructure/knowledge_package.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    throw ArgumentError('Pass one or more package directories.');
  }
  for (final directory in args) {
    final timer = Stopwatch()..start();
    final reader = await LocalKnowledgePackage.openForReview(directory);
    final sources = await reader.sources();
    var checked = 0;
    if (reader.kind == 'documents') {
      for (final source in sources) {
        for (final number in {1, source.pageCount}) {
          final page = await reader.document(source.id, number);
          await reader.resolve(page.citation);
          checked++;
        }
      }
      final hits = await reader.searchDocuments('care');
      if (hits.isEmpty) throw StateError('Document search unexpectedly empty.');
      for (final hit in hits) {
        await reader.resolve(hit.citation);
      }
    } else {
      final db = sqlite3.open(
        p.join(directory, 'knowledge.sqlite3'),
        mode: OpenMode.readOnly,
      );
      late List<int> ids;
      try {
        final packed = db
            .select("SELECT name FROM sqlite_schema WHERE name='record_groups'")
            .isNotEmpty;
        ids = [
          for (final row in db.select(
            packed
                ? '''SELECT min(first_record) AS first,max(first_record+record_count-1) AS last
          FROM record_groups GROUP BY source_id'''
                : '''SELECT min(id) AS first,max(id) AS last
          FROM drug_records GROUP BY source_id''',
          )) ...[row['first'] as int, row['last'] as int],
        ];
      } finally {
        db.close();
      }
      for (final id in ids.toSet()) {
        final record = await reader.drugRecord(id);
        final code = (record['ITEM_SEQ'] ?? record['itemSeq']) as String;
        if ((await reader.lookupDrug(code)).isEmpty) {
          throw StateError('Drug lookup unexpectedly empty.');
        }
        checked++;
      }
    }
    stdout.writeln(
      jsonEncode({
        'package': p.basename(directory),
        'sources': sources.length,
        'content_checked': checked,
        'package_sha256': reader.packageHash,
        'elapsed_ms': timer.elapsedMilliseconds,
        'clinical_enabled': false,
        'passed': true,
      }),
    );
  }
}
