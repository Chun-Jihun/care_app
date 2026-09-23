import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../domain/ai.dart';

/// Small fixed manifest is shipped with the app. The imported pack is untrusted.
/// CAREAI01 + uint32 LE manifest byte length + exact manifest bytes + ordered files.
/// There are no archive-supplied paths or compression to expand.
final class ModelStore {
  ModelStore(this.root, Uint8List manifestBytes)
    : manifestBytes = Uint8List.fromList(manifestBytes).asUnmodifiableView();
  final Directory root;
  final Uint8List manifestBytes;
  late final Map<String, dynamic> manifest =
      jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
  late final String id = sha256.convert(manifestBytes).toString();
  Directory get directory => Directory(p.join(root.path, id));
  String path(String name) {
    if (!(manifest['files'] as List).any((f) => f['path'] == name)) {
      throw const AiException(AiFailure.modelInvalid);
    }
    return p.join(directory.path, name);
  }

  final _verified = <String>{};
  Future<bool> installed() async {
    final marker = File(p.join(directory.path, 'complete'));
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await FileSystemEntity.type(marker.path, followLinks: false) !=
            FileSystemEntityType.file) {
      return false;
    }
    return await marker.length() == id.length &&
        ascii.decode(await marker.readAsBytes(), allowInvalid: true) == id;
  }

  Future<void> verify({Iterable<String>? names}) async {
    if (!await installed()) throw const AiException(AiFailure.unavailable);
    final requested =
        (names ?? (manifest['files'] as List).map((f) => f['path'] as String))
            .toSet();
    for (final name in requested) {
      path(name);
    }
    final pending = requested.difference(_verified);
    if (pending.isEmpty) return;
    final directoryPath = directory.path, bytes = manifestBytes;
    await Isolate.run(
      () => verifyModelFiles(directoryPath, bytes, names: pending),
    );
    _verified.addAll(pending);
  }

  Future<void> remove() async {
    _verified.clear();
    if (!await directory.exists()) return;
    // Invalidate before deletion, so interrupted cleanup cannot appear usable.
    final marker = File(p.join(directory.path, 'complete'));
    if (await marker.exists()) await marker.delete();
    await directory.delete(recursive: true);
  }

  Future<void> install(
    String source,
    void Function(double) progress,
    void Function() check,
  ) async {
    check();
    await root.create(recursive: true);
    // Only this store writes install-* in its private model root, and runtime
    // serialization guarantees there is no concurrent installation to delete.
    await for (final entry in root.list(followLinks: false)) {
      if (entry is Directory && p.basename(entry.path).startsWith('install-')) {
        await entry.delete(recursive: true);
      }
    }
    if (await installed()) {
      try {
        // Explicit reinstallation is also the repair action. A prior in-memory
        // verification cannot establish that the current disk files are intact.
        _verified.clear();
        await verify();
        check();
        progress(1);
        return;
      } on AiException catch (e) {
        if (e.code != AiFailure.modelInvalid) rethrow;
        // Keep the invalid install until the replacement has passed every hash.
      }
    }
    final stage = await root.createTemp('install-');
    RandomAccessFile? input;
    try {
      input = await File(source).open();
      final header = await input.read(12);
      if (header.length != 12 ||
          utf8.decode(header.sublist(0, 8)) != 'CAREAI01' ||
          ByteData.sublistView(header).getUint32(8, Endian.little) !=
              manifestBytes.length) {
        throw const AiException(AiFailure.modelInvalid);
      }
      final supplied = await input.read(manifestBytes.length);
      if (supplied.length != manifestBytes.length ||
          sha256.convert(supplied).toString() != id) {
        throw const AiException(AiFailure.modelInvalid);
      }
      final files = (manifest['files'] as List).cast<Map>();
      final total = files.fold<int>(0, (sum, f) => sum + (f['bytes'] as int));
      if (await input.length() != 12 + manifestBytes.length + total) {
        throw const AiException(AiFailure.modelInvalid);
      }
      var completed = 0;
      for (final entry in files) {
        check();
        final name = entry['path'] as String;
        _checkName(name);
        final outputFile = File(p.join(stage.path, name));
        await outputFile.parent.create(recursive: true);
        final output = await outputFile.open(mode: FileMode.write);
        try {
          var remaining = entry['bytes'] as int;
          while (remaining > 0) {
            check();
            final chunk = await input.read(remaining.clamp(1, 1024 * 1024));
            if (chunk.isEmpty) throw const AiException(AiFailure.modelInvalid);
            await output.writeFrom(chunk);
            remaining -= chunk.length;
            completed += chunk.length;
            progress(completed / total * .8);
          }
          await output.flush();
        } finally {
          await output.close();
        }
      }
      final stagePath = stage.path, bytes = manifestBytes;
      await Isolate.run(() => verifyModelFiles(stagePath, bytes));
      check();
      await File(p.join(stage.path, 'complete')).writeAsString(id, flush: true);
      check();
      // A crash before this rename leaves an incomplete staging directory only.
      if (await directory.exists()) await directory.delete(recursive: true);
      await stage.rename(directory.path);
      _verified.addAll(files.map((f) => f['path'] as String));
      progress(1);
    } finally {
      await input?.close();
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }
}

void _checkName(String name) {
  if (!RegExp(r'^[a-z0-9_-]+/[a-z0-9_.-]+$').hasMatch(name) ||
      name.contains('..')) {
    throw const AiException(AiFailure.modelInvalid);
  }
}

Future<void> verifyModelFiles(
  String directory,
  Uint8List bytes, {
  Set<String>? names,
}) async {
  final manifest = jsonDecode(utf8.decode(bytes)) as Map;
  if (await FileSystemEntity.type(directory, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const AiException(AiFailure.modelInvalid);
  }
  for (final row in manifest['files'] as List) {
    final name = row['path'] as String;
    if (names != null && !names.contains(name)) continue;
    _checkName(name);
    final file = File(p.join(directory, name));
    if (await FileSystemEntity.type(file.parent.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() != row['bytes'] ||
        (await sha256.bind(file.openRead()).first).toString() !=
            row['sha256']) {
      throw const AiException(AiFailure.modelInvalid);
    }
  }
}
