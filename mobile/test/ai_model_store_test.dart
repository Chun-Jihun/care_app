import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/domain/ai.dart';
import 'package:care_notebook/infrastructure/ai/model_store.dart';

void main() {
  test('feature verification checks only requested files; removing models preserves other data', () async {
    final root = await Directory.systemTemp.createTemp(
      'care-model-management-',
    );
    addTearDown(() => root.delete(recursive: true));
    final manifest = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 'test',
          'files': [
            for (final name in ['chat/model.gguf', 'ocr/ko.onnx'])
              {
                'path': name,
                'bytes': 4,
                'sha256': sha256.convert(utf8.encode('test')).toString(),
              },
          ],
        }),
      ),
    );
    final store = ModelStore(Directory('${root.path}/models'), manifest);
    await store.directory.create(recursive: true);
    for (final name in ['chat/model.gguf', 'ocr/ko.onnx']) {
      final file = File(store.path(name));
      await file.parent.create(recursive: true);
      await file.writeAsString(name.startsWith('ocr/') ? 'test' : 'FAIL');
    }
    await File('${store.directory.path}/complete').writeAsString(store.id);
    await store.verify(names: ['ocr/ko.onnx']);
    await expectLater(
      store.verify(names: ['chat/model.gguf']),
      throwsA(isA<AiException>()),
    );
    await expectLater(
      store.verify(names: ['../private']),
      throwsA(isA<AiException>()),
    );
    final retained = File('${root.path}/notebook')
      ..writeAsStringSync('retained');
    await store.remove();
    expect(await store.installed(), false);
    expect(await retained.readAsString(), 'retained');
    await expectLater(
      store.verify(names: ['ocr/ko.onnx']),
      throwsA(isA<AiException>()),
    );
    await store.remove(); // Repeated removal is harmless.
  });

  test('model pack rejects tampering and incomplete writes; cancellation leaves no active install', () async {
    final root = await Directory.systemTemp.createTemp('care-model-pack-');
    addTearDown(() => root.delete(recursive: true));
    final contents = utf8.encode('public test weights');
    final manifest = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 'test',
          'files': [
            {
              'path': 'chat/model.gguf',
              'bytes': contents.length,
              'sha256': sha256.convert(contents).toString(),
            },
          ],
        }),
      ),
    );
    final header = Uint8List(12)..setRange(0, 8, ascii.encode('CAREAI01'));
    ByteData.sublistView(header).setUint32(8, manifest.length, Endian.little);
    final pack = File('${root.path}/sample.careai');
    await pack.writeAsBytes([...header, ...manifest, ...contents]);
    final store = ModelStore(Directory('${root.path}/models'), manifest);
    await expectLater(
      store.install(
        pack.path,
        (_) {},
        () => throw const AiException(AiFailure.cancelled),
      ),
      throwsA(isA<AiException>()),
    );
    expect(await store.installed(), false);
    await pack.writeAsBytes([
      ...header,
      ...manifest,
      ...List.filled(contents.length, 0),
    ]);
    await expectLater(
      store.install(pack.path, (_) {}, () {}),
      throwsA(isA<AiException>()),
    );
    expect(await store.installed(), false);
    await pack.writeAsBytes([...header, ...manifest, ...contents]);
    await store.install(pack.path, (_) {}, () {});
    expect(await store.installed(), true);
    await ModelStore(store.root, manifest).verify();
    // Reinstall in the same process must not trust its earlier hash cache.
    // Cancellation must also apply when a complete installation already exists.
    await expectLater(
      store.install(
        pack.path,
        (_) {},
        () => throw const AiException(AiFailure.cancelled),
      ),
      throwsA(isA<AiException>()),
    );
    await File(store.path('chat/model.gguf'))
        .writeAsBytes(List.filled(contents.length, 0));
    await expectLater(
      ModelStore(store.root, manifest).verify(),
      throwsA(isA<AiException>()),
    );
    final interrupted = Directory('${store.root.path}/install-abandoned');
    await interrupted.create();
    await File('${interrupted.path}/partial').writeAsString('partial');
    await store.install(pack.path, (_) {}, () {});
    await ModelStore(store.root, manifest).verify();
    expect(await interrupted.exists(), false);
    expect(await File(store.path('chat/model.gguf')).readAsBytes(), contents);
    await File('${store.directory.path}/complete').writeAsString('partial');
    expect(await store.installed(), false);
  });
}
