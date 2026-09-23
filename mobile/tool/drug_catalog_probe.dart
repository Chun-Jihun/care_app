import 'dart:convert';
import 'dart:io';

import 'package:care_notebook/domain/knowledge_installation.dart';
import 'package:care_notebook/infrastructure/knowledge_store.dart';
import 'package:care_notebook/infrastructure/local_drug_catalog.dart';
import 'package:care_notebook/infrastructure/knowledge_package.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError('descriptor installed-directory raw-dur-directory');
  }
  final release = KnowledgeRelease(await File(args[0]).readAsBytes());
  final store = KnowledgeStore(Directory(args[1]), [
    release,
  ], allowPreview: true);
  final catalog = LocalDrugCatalog(store);
  final products = await catalog.search('타이레놀');
  final dur = await LocalKnowledgePackage.openForReview(args[2]);
  final batch = await dur.drugSafetyRows({'195700013', '196900031'});
  var blocked = false;
  try {
    await catalog.records({'195700013'}, release.id);
  } on FormatException {
    blocked = true;
  }
  stdout.writeln(
    jsonEncode({
      'state': products.info.state.name,
      'product_candidates': products.products.length,
      'preview_clinical_lookup_blocked': blocked,
      'debug_dur_rows': batch.records.length,
      'complete': batch.complete,
      'exact_pair_present': batch.records.any(
        (r) => r.item == '195700013' && r.counterpart == '196900031',
      ),
    }),
  );
  if (!blocked || products.products.isEmpty || batch.records.isEmpty) {
    throw StateError('Probe failed');
  }
}
