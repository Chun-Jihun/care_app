import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:care_notebook/application/knowledge_search.dart';
import 'package:care_notebook/application/reviewed_knowledge_catalog.dart';
import 'package:care_notebook/domain/knowledge.dart';
import 'package:care_notebook/domain/knowledge_installation.dart';
import 'package:care_notebook/infrastructure/knowledge_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/knowledge_delivery_fixture.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-delivery-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'install, restart, update, historical citation and explicit rollback',
    () async {
      final a = await makeDelivery(root, 'a');
      final b = await makeDelivery(
        root,
        'b',
        body: '$syntheticText Second version.',
      );
      final location = Directory('${root.path}/installed');
      var store = KnowledgeStore(location, [
        a.release,
        b.release,
      ], allowPreview: true);
      await store.install(a.bundle.path, (_) {}, () {});
      expect((await store.status()).active!.id, a.release.id);
      store = KnowledgeStore(location, [
        a.release,
        b.release,
      ], allowPreview: true);
      await store.install(b.bundle.path, (_) {}, () {});
      expect((await store.status()).previous!.id, a.release.id);
      final historical = await store.reader(
        packageHash: a.citation.packageHash,
      );
      expect((await historical!.resolve(a.citation)).text, syntheticText);
      await store.rollback();
      expect((await store.status()).active!.id, a.release.id);
    },
  );

  test('truncation, append, corruption, foreign descriptor and cancellation preserve active version', () async {
    final a = await makeDelivery(root, 'a');
    final b = await makeDelivery(root, 'b');
    final store = KnowledgeStore(Directory('${root.path}/installed'), [
      a.release,
      b.release,
    ], allowPreview: true);
    await store.install(a.bundle.path, (_) {}, () {});
    final bytes = await b.bundle.readAsBytes();
    for (final bad in [
      bytes.sublist(0, bytes.length - 1),
      [...bytes, 0],
      [...bytes.take(bytes.length - 1), bytes.last ^ 1],
    ]) {
      final file = await File('${root.path}/bad').writeAsBytes(bad);
      await expectLater(
        store.install(file.path, (_) {}, () {}),
        throwsA(isA<KnowledgePackageException>()),
      );
      expect((await store.status()).active!.id, a.release.id);
    }
    final c = await makeDelivery(root, 'unknown');
    await expectLater(
      store.install(c.bundle.path, (_) {}, () {}),
      throwsA(isA<KnowledgePackageException>()),
    );
    var calls = 0;
    await expectLater(
      store.install(b.bundle.path, (_) {}, () {
        if (++calls == 3) throw StateError('cancel');
      }),
      throwsStateError,
    );
    expect((await store.status()).active!.id, a.release.id);
    expect(
      await store.root.list().where((e) => e.path.contains('stage-')).isEmpty,
      isTrue,
    );
  });

  test('incomplete activation is ignored; committed corruption is detected, never silently used', () async {
    final a = await makeDelivery(root, 'a');
    final store = KnowledgeStore(Directory('${root.path}/installed'), [
      a.release,
    ], allowPreview: true);
    await store.install(a.bundle.path, (_) {}, () {});
    await File('${store.root.path}/activation.pending')
        .writeAsString('incomplete');
    await Directory('${store.root.path}/stage-interrupted').create();
    expect((await store.status()).active!.id, a.release.id);
    final file = File(
      '${store.root.path}/${a.release.id}/documents/knowledge.sqlite3',
    );
    final handle = await file.open(mode: FileMode.append);
    await handle.writeByte(0);
    await handle.close();
    expect((await store.status()).damaged, isTrue);
    await expectLater(
      store.reader(),
      throwsA(isA<KnowledgePackageException>()),
    );
  });

  test('cancellation at the final activation boundary preserves the previous release', () async {
    final a = await makeDelivery(root, 'a');
    final b = await makeDelivery(root, 'b');
    final store = KnowledgeStore(Directory('${root.path}/installed'), [
      a.release,
      b.release,
    ], allowPreview: true);
    await store.install(a.bundle.path, (_) {}, () {});
    var commits = 0;
    await expectLater(
      store.install(
        b.bundle.path,
        (v) {
          if (v == 1) commits++;
        },
        () {
          if (File('${store.root.path}/activation.pending').existsSync()) {
            throw StateError('cancel-before-commit');
          }
        },
      ),
      throwsStateError,
    );
    expect(commits, 0);
    expect((await store.status()).active!.id, a.release.id);
  });

  test('preview is rejected by production store and by clinical allowlist even with a rule', () async {
    final a = await makeDelivery(root, 'a');
    final production = KnowledgeStore(Directory('${root.path}/prod'), [
      a.release,
    ]);
    await expectLater(
      production.install(a.bundle.path, (_) {}, () {}),
      throwsA(isA<KnowledgePackageException>()),
    );
    final dev = KnowledgeStore(Directory('${root.path}/dev'), [
      a.release,
    ], allowPreview: true);
    await dev.install(a.bundle.path, (_) {}, () {});
    final catalog = ReviewedKnowledgeCatalog(TestKnowledgeLibrary(dev), [
      syntheticPassage(a.citation),
    ]);
    expect(await catalog.passages(), isEmpty);
  });

  test('unsafe descriptor paths, duplicates, oversize, invalid dates fail before filesystem writes', () async {
    final a = await makeDelivery(root, 'a');
    for (final mode in ['path', 'duplicate', 'size', 'date']) {
      final data = jsonDecode(utf8.decode(a.release.bytes)) as Map;
      final files = data['files'] as List;
      if (mode == 'path') files[0]['path'] = '../escape';
      if (mode == 'duplicate') files.add(files[0]);
      if (mode == 'size') files[0]['bytes'] = 60 * 1024 * 1024;
      if (mode == 'date') data['recheck_after'] = data['checked_at'];
      expect(
        () =>
            KnowledgeRelease(Uint8List.fromList(utf8.encode(jsonEncode(data)))),
        throwsFormatException,
      );
    }
    expect(a.release.stale(DateTime.utc(2099)), isTrue);
  });

  test(
    'Korean everyday question retrieves an English passage and exact location',
    () async {
      final a = await makeDelivery(root, 'a');
      final store = KnowledgeStore(Directory('${root.path}/installed'), [
        a.release,
      ], allowPreview: true);
      await store.install(a.bundle.path, (_) {}, () {});
      final reader = (await store.reader())!;
      for (final question in [syntheticQuestion, '낙상을 예방하려면', '미끄러질까 걱정']) {
        final hits = await KnowledgeSearch(reader).search(question);
        expect(hits, isNotEmpty, reason: question);
        expect(
          (await reader.resolve(hits.first.citation)).citation.excerpt,
          syntheticText,
        );
      }
      expect(await KnowledgeSearch(reader).search('관계없는 문장 xyzzy'), isEmpty);
      expect(await KnowledgeSearch(reader).search('" OR NOT *'), isEmpty);
    },
  );
}
