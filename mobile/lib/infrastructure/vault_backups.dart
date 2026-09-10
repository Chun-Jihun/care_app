import 'backup_document.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../domain/records.dart';
import '../domain/backup.dart';
import 'care_database.dart';
import 'crypto.dart';
import 'vault_state.dart';

final class VaultBackups {
  VaultBackups(this._state);
  final VaultState _state;
  Future<Uint8List> backup(String password) async {
    if (password.length < 12) {
      throw CareError(CareErrorCode.backupPasswordTooShort);
    }
    _state.database.pruneChats();
    await _state.cleanup();
    _state.database.verifyIntegrity();
    final files = <String, String>{};
    var size = 0;
    for (final id in _state.database.allAttachmentIds) {
      final data = await File(
        p.join(_state.directory.path, 'attachments', '$id.enc'),
      ).readAsBytes();
      size += data.length;
      if (size > VaultState.maxBackupBytes / 2) {
        throw CareError(CareErrorCode.legacyBackupPhotosTooLarge);
      }
      files[id] = base64Encode(data);
    }
    final payload = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 1,
          'keys': _state.keys,
          'care': base64Encode(
            await File(p.join(_state.directory.path, 'care.db')).readAsBytes(),
          ),
          'identity': base64Encode(
            await File(p.join(_state.directory.path, 'identity.db'))
                .readAsBytes(),
          ),
          'files': files,
        }),
      ),
    );
    if (payload.length > VaultState.maxBackupBytes) {
      throw CareError(CareErrorCode.legacyBackupTooLarge);
    }
    return Isolate.run(() => VaultCrypto.passwordSeal(payload, password));
  }

  Future<void> restore(
    Uint8List encrypted,
    String password, {
    void Function()? beforeCommit,
  }) async {
    if (encrypted.length > VaultState.maxBackupBytes + 128) {
      throw CareError(CareErrorCode.backupFileTooLarge);
    }
    final clear = await Isolate.run(
      () => VaultCrypto.passwordOpen(encrypted, password),
    );
    final data = jsonDecode(utf8.decode(clear));
    if (data is! Map ||
        data['format'] != 1 ||
        data['keys'] is! Map ||
        data['files'] is! Map) {
      throw CareError(CareErrorCode.unsupportedBackupFormat);
    }
    final keys = Map<String, String>.from(data['keys'] as Map);
    if (![
      'care',
      'identity',
      'files',
    ].every((k) => keys[k] != null && base64Decode(keys[k]!).length == 32)) {
      throw CareError(CareErrorCode.invalidBackupKeys);
    }
    final generation = CareDatabase.newId();
    final stage = await Directory(p.join(_state.root.path, generation))
        .create(recursive: true);
    CareDatabase? candidate;
    var committed = false;
    try {
      for (final name in ['care', 'identity']) {
        final bytes = base64Decode(data[name] as String);
        if (bytes.length < 512) {
          throw CareError(CareErrorCode.incompleteBackupStorage);
        }
        await File(p.join(stage.path, '$name.db'))
            .writeAsBytes(bytes, flush: true);
      }
      candidate = CareDatabase.open(
        stage.path,
        key: base64Decode(keys['care']!),
        identityKey: base64Decode(keys['identity']!),
      );
      final files = Map<String, String>.from(data['files'] as Map);
      final expected = candidate.allAttachmentIds.toSet();
      if (files.length != expected.length ||
          files.keys.any(
            (k) => !VaultState.idPattern.hasMatch(k) || !expected.contains(k),
          )) {
        throw CareError(CareErrorCode.backupPhotoLinkMismatch);
      }
      final attachments = await Directory(p.join(stage.path, 'attachments'))
          .create(recursive: true);
      for (final entry in files.entries) {
        await File(p.join(attachments.path, '${entry.key}.enc'))
            .writeAsBytes(base64Decode(entry.value), flush: true);
      }
      for (final patient in candidate.patients()) {
        for (final entry in candidate.entries(patient.id)) {
          for (final file in candidate.attachments(patient.id, entry.id)) {
            final key = await VaultCrypto.open(
              base64Decode(file.wrappedKey),
              base64Decode(keys['files']!),
              context: 'key:${file.id}',
            );
            await VaultCrypto.open(
              base64Decode(files[file.id]!),
              key,
              context: 'photo:${file.id}',
            );
          }
        }
      }
      candidate.verifyIntegrity();
      await _state.saveKeys(generation, keys);
      beforeCommit?.call();
      await _state.commit(generation);
      committed = true;
      _state.database.close();
      _state.database = candidate;
      candidate = null;
      _state.generation = generation;
      _state.keys = keys;
      await _state.maintain();
    } finally {
      candidate?.close();
      if (!committed) {
        if (await stage.exists()) {
          await stage.delete(recursive: true);
        }
        await _state.deleteKeys(generation);
      }
    }
  }

  Future<Uint8List> backupSelection(
    String password,
    BackupSelection selection,
  ) async {
    if (password.length < 12) {
      throw CareError(CareErrorCode.backupPasswordTooShort);
    }
    _state.database.pruneChats();
    _state.database.pruneDrafts();
    await _state.cleanup();
    _state.database.verifyIntegrity();
    final rows = _state.database.selectBackup(selection);
    final files = <String, String>{}, fileKeys = <String, String>{};
    var size = 0;
    for (final row in rows['attachment']!) {
      final id = row['id'] as String;
      final file = File(
        p.join(_state.directory.path, 'attachments', '$id.enc'),
      );
      size += await file.length();
      if (size > VaultState.maxBackupBytes ~/ 2) {
        throw CareError(CareErrorCode.backupPhotosTooLarge);
      }
      final key = await VaultCrypto.open(
        base64Decode(row['wrapped_key'] as String),
        _state.key('files'),
        context: 'key:$id',
      );
      final bytes = await file.readAsBytes();
      await VaultCrypto.open(bytes, key, context: 'photo:$id');
      files[id] = base64Encode(bytes);
      fileKeys[id] = base64Encode(key);
      row['wrapped_key'] = '';
    }
    final payload = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': BackupDocument.format,
          'document_version': BackupDocument.version,
          'id': CareDatabase.newId(),
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'selection': selection.toJson(),
          'rows': rows,
          'files': files,
          'file_keys': fileKeys,
        }),
      ),
    );
    if (payload.length > VaultState.maxBackupBytes) {
      throw CareError(CareErrorCode.backupSelectionTooLarge);
    }
    return Isolate.run(() => VaultCrypto.passwordSeal(payload, password));
  }

  Future<Map<String, dynamic>> _readArchive(
    Uint8List encrypted,
    String password,
  ) async {
    if (encrypted.length > VaultState.maxBackupBytes + 128) {
      throw CareError(CareErrorCode.backupFileTooLarge);
    }
    final clear = await Isolate.run(
      () => VaultCrypto.passwordOpen(encrypted, password),
    );
    if (clear.length > VaultState.maxBackupBytes) {
      throw CareError(CareErrorCode.backupFileTooLarge);
    }
    final value = jsonDecode(utf8.decode(clear));
    if (value is! Map<String, dynamic> ||
        ![1, 2, 3].contains(value['format'])) {
      throw CareError(CareErrorCode.unsupportedBackupFormat);
    }
    return value;
  }

  BackupRows _archiveRows(Map<String, dynamic> archive) {
    if (archive['id'] is! String ||
        !VaultState.idPattern.hasMatch(archive['id'] as String) ||
        archive['rows'] is! Map ||
        archive['files'] is! Map ||
        archive['file_keys'] is! Map) {
      throw CareError(CareErrorCode.unsupportedBackupVersion);
    }
    return BackupDocument.decode(archive);
  }

  Future<BackupPreview> inspectBackup(
    Uint8List encrypted,
    String password,
  ) async {
    final archive = await _readArchive(encrypted, password);
    if (archive['format'] == 1) return BackupPreview(legacy: true);
    final rows = _archiveRows(archive);
    if (_state.database.hasImportedBackup(archive['id'] as String)) {
      throw CareError(CareErrorCode.duplicateBackup);
    }
    return BackupPreview(legacy: false, counts: BackupDocument.counts(rows));
  }

  Future<void> importSelection(
    Uint8List encrypted,
    String password, {
    void Function()? beforeCommit,
  }) async {
    final archive = await _readArchive(encrypted, password);
    final rows = _archiveRows(archive);
    final archiveId = archive['id'] as String;
    if (_state.database.hasImportedBackup(archiveId)) {
      throw CareError(CareErrorCode.duplicateBackup);
    }
    if (rows['patient_context'] == null || rows['patient_context']!.isEmpty) {
      throw CareError(CareErrorCode.emptyBackup);
    }
    final files = Map<String, String>.from(archive['files'] as Map);
    final fileKeys = Map<String, String>.from(archive['file_keys'] as Map);
    final attachments = rows['attachment'] ?? [];
    final expected = attachments.map((r) => r['id']).toSet();
    if (expected.length != attachments.length ||
        files.length != expected.length ||
        fileKeys.length != expected.length ||
        files.keys.any(
          (id) => !VaultState.idPattern.hasMatch(id) || !expected.contains(id),
        ) ||
        fileKeys.keys.any((id) => !expected.contains(id))) {
      throw CareError(CareErrorCode.backupPhotoLinkMismatch);
    }
    final ids = <String, String>{};
    for (final table in rows.values) {
      for (final row in table) {
        if (row['id'] case final String id) {
          if (!VaultState.idPattern.hasMatch(id) || ids.containsKey(id)) {
            throw CareError(CareErrorCode.invalidBackupIds);
          }
          ids[id] = CareDatabase.newId();
        }
      }
    }
    final generation = CareDatabase.newId();
    final stage = await Directory(p.join(_state.root.path, generation))
        .create(recursive: true);
    final keys = Map<String, String>.from(_state.keys);
    CareDatabase? candidate;
    var committed = false;
    try {
      await _state.cleanup();
      for (final name in ['care', 'identity']) {
        await File(p.join(_state.directory.path, '$name.db'))
            .copy(p.join(stage.path, '$name.db'));
      }
      final dir = await Directory(p.join(stage.path, 'attachments')).create();
      for (final id in _state.database.allAttachmentIds) {
        await File(p.join(_state.directory.path, 'attachments', '$id.enc'))
            .copy(p.join(dir.path, '$id.enc'));
      }
      candidate = CareDatabase.open(
        stage.path,
        key: _state.key('care'),
        identityKey: _state.key('identity'),
      );
      var size = 0;
      for (final row in attachments) {
        final oldId = row['id'] as String, id = ids[oldId]!;
        final data = base64Decode(files[oldId]!);
        size += data.length;
        if (size > VaultState.maxBackupBytes ~/ 2 ||
            row['size'] != data.length) {
          throw CareError(CareErrorCode.invalidBackupPhotoSize);
        }
        final sourceKey = base64Decode(fileKeys[oldId]!);
        if (sourceKey.length != 32) {
          throw CareError(CareErrorCode.invalidBackupPhotoKey);
        }
        final photo = await VaultCrypto.open(
          data,
          sourceKey,
          context: 'photo:$oldId',
        );
        final key = VaultCrypto.randomBytes();
        final bytes = await VaultCrypto.seal(photo, key, context: 'photo:$id');
        final wrapped = await VaultCrypto.seal(
          key,
          _state.key('files'),
          context: 'key:$id',
        );
        await File(p.join(dir.path, '$id.enc'))
            .writeAsBytes(bytes, flush: true);
        row['wrapped_key'] = base64Encode(wrapped);
        row['size'] = bytes.length;
      }
      candidate.importBackupRows(rows, archiveId, ids);
      candidate.pruneChats();
      candidate.verifyIntegrity();
      await _state.saveKeys(generation, keys);
      beforeCommit?.call();
      await _state.commit(generation);
      committed = true;
      _state.database.close();
      _state.database = candidate;
      candidate = null;
      _state.generation = generation;
      _state.keys = keys;
      await _state.maintain();
    } finally {
      candidate?.close();
      if (!committed) {
        if (await stage.exists()) await stage.delete(recursive: true);
        await _state.deleteKeys(generation);
      }
    }
  }

  BackupPreview previewSelection(BackupSelection selection) => BackupPreview(
    legacy: false,
    counts: BackupDocument.counts(_state.database.selectBackup(selection)),
  );
}
