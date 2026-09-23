import 'dart:convert';
import 'dart:io';

import 'package:care_notebook/application/knowledge_search.dart';
import 'package:care_notebook/domain/knowledge_installation.dart';
import 'package:care_notebook/infrastructure/knowledge_store.dart';

/// PC-only diagnostic: imports actual UNREVIEWED material and tests retrieval.
/// It does not call an LLM, create clinical grants, or contact a server.
Future<void> main(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError('descriptor bundle output-directory');
  }
  final release = KnowledgeRelease(await File(args[0]).readAsBytes());
  final store = KnowledgeStore(Directory(args[2]), [
    release,
  ], allowPreview: true);
  final watch = Stopwatch()..start();
  await store.install(args[1], (_) {}, () {});
  final status = await store.status();
  final reader = (await store.reader())!;
  final results = <String, Object?>{};
  for (final query in [
    '자꾸 넘어질까 걱정돼요',
    '간병하다 너무 지쳐요',
    '밥 먹을 때 삼키기 힘들어요',
    '퇴원하고 집에 돌아왔어요',
    '욕창이 걱정돼요',
  ]) {
    final hits = await KnowledgeSearch(reader).search(query);
    for (final hit in hits) {
      await reader.resolve(hit.citation);
    }
    results[query] = {
      'hits': hits.length,
      'sources': hits.map((h) => h.source.title).toSet().toList(),
    };
  }
  final permits = await store.reader(kind: 'permits');
  final drug = await permits!.findDrugName('타이레놀');
  stdout.writeln(
    jsonEncode({
      'version': status.active!.version,
      'bytes': release.payloadBytes,
      'preview': status.active!.preview,
      'search': results,
      'partial_drug_name': {
        'candidates': drug.candidates.length,
        'identified': drug.identified != null,
        'truncated': drug.truncated,
      },
      'elapsed_ms': watch.elapsedMilliseconds,
    }),
  );
}
