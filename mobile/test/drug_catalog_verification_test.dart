import 'dart:io';

import 'package:care_notebook/infrastructure/knowledge_store.dart';
import 'package:care_notebook/infrastructure/local_drug_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/knowledge_delivery_fixture.dart';

// Reducing repeated I/O must not cache trust or ignore activation changes.
void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-catalog-check-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test('consecutive searches follow activation and rollback', () async {
    final a = await makeDelivery(root, 'a', packageKind: 'permits');
    final b = await makeDelivery(root, 'b', packageKind: 'permits');
    final store = KnowledgeStore(Directory('${root.path}/installed'), [
      a.release,
      b.release,
    ], allowPreview: true);
    final catalog = LocalDrugCatalog(store);
    await store.install(a.bundle.path, (_) {}, () {});
    expect(
      (await catalog.search('synthetic-no-match')).info.releaseId,
      a.release.id,
    );
    await store.install(b.bundle.path, (_) {}, () {});
    expect(
      (await catalog.search('synthetic-no-match')).info.releaseId,
      b.release.id,
    );
    await store.rollback();
    expect(
      (await catalog.search('synthetic-no-match')).info.releaseId,
      a.release.id,
    );
  });
  test('corruption remains blocked after a prior successful search', () async {
    final delivery = await makeDelivery(root, 'a', packageKind: 'permits');
    final store = KnowledgeStore(Directory('${root.path}/installed'), [
      delivery.release,
    ], allowPreview: true);
    await store.install(delivery.bundle.path, (_) {}, () {});
    final catalog = LocalDrugCatalog(store);
    await catalog.search('no-matching-synthetic-product');
    final file = File(
      '${store.root.path}/${delivery.release.id}/permits/knowledge.sqlite3',
    );
    await file.writeAsBytes([0], mode: FileMode.append);
    await expectLater(
      catalog.search('no-matching-synthetic-product'),
      throwsA(anything),
    );
  });
  test(
    'unknown activation refuses search instead of using older data',
    () async {
      final delivery = await makeDelivery(root, 'a', packageKind: 'permits');
      final store = KnowledgeStore(Directory('${root.path}/installed'), [
        delivery.release,
      ], allowPreview: true);
      await store.install(delivery.bundle.path, (_) {}, () {});
      await File('${store.root.path}/active-999999999999-${'f' * 64}')
          .writeAsString('');
      await expectLater(
        LocalDrugCatalog(store).search('no-matching-synthetic-product'),
        throwsA(anything),
      );
    },
  );
}
