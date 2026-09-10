import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../application/ports.dart';
import '../domain/records.dart';
import 'care_database.dart';
import 'crypto.dart';

/// Infrastructure-only owner of active encrypted generations and key material.
final class VaultState {
  VaultState(this.root, this._secrets);
  final Directory root;
  final SecretStore _secrets;
  late CareDatabase database;
  late String generation;
  late Map<String, String> keys;
  bool _opened = false;
  bool maintenancePending = false;
  static const maxBackupBytes = 100 * 1024 * 1024;
  static final idPattern = RegExp(r'^[0-9a-fA-F-]{36}$');
  Directory get directory => Directory(p.join(root.path, generation));
  Uint8List key(String name) => base64Decode(keys[name]!);
  Future<void> saveKeys(String id, Map<String, String> value) =>
      _secrets.write('vault.$id', jsonEncode(value));
  Future<void> deleteKeys(String id) => _secrets.delete('vault.$id');
  Future<void> open() async {
    await root.create(recursive: true);
    if (await File(p.join(root.path, 'wipe.pending')).exists()) {
      await finishWipe();
    }
    final commits = await Directory(p.join(root.path, 'commits'))
        .create(recursive: true);
    final markers =
        (await commits
              .list()
              .where((f) => f is File && f.path.endsWith('.commit'))
              .toList())
          ..sort((a, b) => a.path.compareTo(b.path));
    if (markers.isEmpty) {
      generation = CareDatabase.newId();
      keys = {
        for (final k in ['care', 'identity', 'files'])
          k: base64Encode(VaultCrypto.randomBytes()),
      };
      await _secrets.write('vault.$generation', jsonEncode(keys));
      database = CareDatabase.open(
        directory.path,
        key: key('care'),
        identityKey: key('identity'),
      );
      await commit(generation);
    } else {
      generation = (await File(markers.last.path).readAsString()).trim();
      if (!idPattern.hasMatch(generation)) {
        throw CareError(CareErrorCode.storageLocationInvalid);
      }
      final encoded = await _secrets.read('vault.$generation');
      if (encoded == null) {
        throw CareError(CareErrorCode.storageKeyMissing);
      }
      keys = Map<String, String>.from(jsonDecode(encoded));
      for (final file in ['care.db', 'identity.db']) {
        if (!await File(p.join(directory.path, file)).exists()) {
          throw CareError(CareErrorCode.storageFileMissing);
        }
      }
      database = CareDatabase.open(
        directory.path,
        key: key('care'),
        identityKey: key('identity'),
      );
    }
    _opened = true;
    await maintain();
  }

  Future<void> maintain() async {
    maintenancePending = false;
    try {
      await cleanup();
      await prune();
    } catch (_) {
      maintenancePending = true;
    }
  }

  Future<void> commit(String id) async {
    final dir = await Directory(p.join(root.path, 'commits'))
        .create(recursive: true);
    var sequence = 0;
    await for (final file in dir.list()) {
      final match = RegExp(r'^z-(\d+)\.commit$')
          .firstMatch(p.basename(file.path));
      if (match != null) {
        final value = int.parse(match[1]!);
        if (value > sequence) sequence = value;
      }
    }
    final marker = File(
      p.join(
        dir.path,
        'z-${(sequence + 1).toString().padLeft(20, '0')}.commit',
      ),
    );
    final temp = File('${marker.path}.tmp');
    await temp.writeAsString(id, flush: true);
    await temp.rename(marker.path);
  }

  Future<void> prune() async {
    await for (final entity in root.list()) {
      final name = p.basename(entity.path);
      if (entity is Directory &&
          idPattern.hasMatch(name) &&
          name != generation) {
        await _secrets.delete('vault.$name');
        await entity.delete(recursive: true);
      }
    }
    final markers =
        (await Directory(p.join(root.path, 'commits'))
              .list()
              .where((f) => f is File && f.path.endsWith('.commit'))
              .toList())
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final marker in markers.take(
      markers.length > 1 ? markers.length - 1 : 0,
    )) {
      await marker.delete();
    }
  }

  Future<void> cleanup({bool removeOrphans = true}) async {
    final directory = await Directory(
      p.join(this.directory.path, 'attachments'),
    ).create(recursive: true);
    for (final id in database.pendingFileDeletes) {
      if (!idPattern.hasMatch(id)) {
        throw CareError(CareErrorCode.attachmentDeleteInvalid);
      }
      final file = File(p.join(directory.path, '$id.enc'));
      if (await file.exists()) {
        await file.delete();
      }
      database.finishFileDelete(id);
    }
    if (!removeOrphans) return;
    final allowed = database.allAttachmentIds.toSet();
    await for (final entity in directory.list()) {
      if (entity is File &&
          !allowed.contains(p.basenameWithoutExtension(entity.path))) {
        await entity.delete();
      }
    }
  }

  Future<void> wipe() async {
    await File(p.join(root.path, 'wipe.pending'))
        .writeAsString('1', flush: true);
    if (_opened) {
      close();
    }
    await finishWipe();
  }

  Future<void> finishWipe() async {
    await for (final entity in root.list()) {
      if (p.basename(entity.path) == 'wipe.pending') {
        continue;
      }
      final name = p.basename(entity.path);
      if (entity is Directory && idPattern.hasMatch(name)) {
        await _secrets.delete('vault.$name');
      }
      await entity.delete(recursive: entity is Directory);
    }
    final marker = File(p.join(root.path, 'wipe.pending'));
    if (await marker.exists()) {
      await marker.delete();
    }
  }

  void close() {
    if (_opened) {
      database.close();
      _opened = false;
      keys.clear();
    }
  }
}
