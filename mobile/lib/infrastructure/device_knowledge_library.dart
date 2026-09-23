import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/knowledge.dart';
import '../domain/knowledge_installation.dart';
import 'knowledge_store.dart';
import 'local_drug_catalog.dart';
import '../domain/drug_safety.dart';

final class DeviceKnowledgeLibrary implements KnowledgeLibrary {
  Future<DrugCatalog> drugCatalog() async => LocalDrugCatalog(await _store);
  Future<KnowledgeStore>? _future;
  Future<KnowledgeStore> get _store => _future ??= _prepare();
  Future<KnowledgeStore> _prepare() async {
    final root = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'knowledge'),
    );
    await root.create(recursive: true);
    if (Platform.isIOS) {
      await const MethodChannel('org.carenotebook/privacy')
          .invokeMethod<void>('protectDirectory', {'path': root.path});
    }
    // Production allowlist is intentionally EMPTY until clinical approval.
    final releases = <KnowledgeRelease>[];
    if (kDebugMode) {
      final assets = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final name in assets.listAssets().where(
        (name) =>
            name.startsWith('assets/knowledge/releases/') &&
            name.endsWith('.json'),
      )) {
        final data = await rootBundle.load(name);
        releases.add(
          KnowledgeRelease(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          ),
        );
      }
    }
    return KnowledgeStore(root, releases, allowPreview: kDebugMode);
  }

  @override
  Future<KnowledgeInstallation> status() async => (await _store).status();
  @override
  Future<String?> pickBundle() async => (await FilePicker.pickFile())?.path;
  @override
  Future<void> install(
    String path,
    void Function(double) progress,
    void Function() check,
  ) async {
    try {
      await (await _store).install(path, progress, check);
    } finally {
      try {
        await FilePicker.clearTemporaryFiles();
      } on Object {
        /* best effort */
      }
    }
  }

  @override
  Future<void> rollback() async => (await _store).rollback();
  @override
  Future<KnowledgeReviewReader?> reader({String? packageHash}) async =>
      (await _store).reader(packageHash: packageHash);
}
