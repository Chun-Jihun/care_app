part of 'vault_store.dart';

extension SelectiveVaultBackup on VaultStore {
  Future<Uint8List> backupSelection(
    String password,
    BackupSelection selection,
  ) async {
    if (password.length < 12) {
      throw const CareError('백업 비밀번호는 12자 이상으로 입력해 주세요.');
    }
    db.pruneChats();
    db.pruneDrafts();
    await cleanup();
    db.verifyIntegrity();
    final rows = db.selectBackup(selection);
    final files = <String, String>{}, fileKeys = <String, String>{};
    var size = 0;
    for (final row in rows['attachment']!) {
      final id = row['id'] as String;
      final file = File(p.join(_directory.path, 'attachments', '$id.enc'));
      size += await file.length();
      if (size > VaultStore.maxBackupBytes ~/ 2) {
        throw const CareError('사진 합계가 50MB를 넘습니다. 기간을 줄이거나 사진을 제외해 주세요.');
      }
      final key = await VaultCrypto.open(
        base64Decode(row['wrapped_key'] as String),
        _key('files'),
        context: 'key:$id',
      );
      final bytes = await file.readAsBytes();
      // Verify each selected photo before producing a supposedly usable backup.
      await VaultCrypto.open(bytes, key, context: 'photo:$id');
      files[id] = base64Encode(bytes);
      fileKeys[id] = base64Encode(key);
      row['wrapped_key'] =
          ''; // The original master key never leaves the vault.
    }
    final payload = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 2,
          'schema': CareDatabase.schemaVersion,
          'id': CareDatabase.newId(),
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'selection': selection.toJson(),
          'rows': rows,
          'files': files,
          'file_keys': fileKeys,
        }),
      ),
    );
    if (payload.length > VaultStore.maxBackupBytes) {
      throw const CareError('백업 크기가 한도를 넘습니다. 선택 기간을 줄여 주세요.');
    }
    return Isolate.run(() => VaultCrypto.passwordSeal(payload, password));
  }

  Future<Map<String, dynamic>> _readArchive(
    Uint8List encrypted,
    String password,
  ) async {
    if (encrypted.length > VaultStore.maxBackupBytes + 128) {
      throw const CareError('백업 파일이 너무 큽니다.');
    }
    final clear = await Isolate.run(
      () => VaultCrypto.passwordOpen(encrypted, password),
    );
    if (clear.length > VaultStore.maxBackupBytes) {
      throw const CareError('백업 파일이 너무 큽니다.');
    }
    final value = jsonDecode(utf8.decode(clear));
    if (value is! Map<String, dynamic> || ![1, 2].contains(value['format'])) {
      throw const CareError('지원하지 않는 백업 형식입니다.');
    }
    return value;
  }

  BackupRows _archiveRows(Map<String, dynamic> archive) {
    if (archive['format'] != 2 ||
        archive['schema'] != CareDatabase.schemaVersion ||
        archive['id'] is! String ||
        !VaultStore._id.hasMatch(archive['id'] as String) ||
        archive['rows'] is! Map ||
        archive['files'] is! Map ||
        archive['file_keys'] is! Map) {
      throw const CareError('백업 형식이 올바르지 않거나 더 새 버전의 앱이 필요합니다.');
    }
    return Map<String, dynamic>.from(archive['rows'] as Map).map(
      (table, values) => MapEntry(
        table,
        (values as List)
            .map((r) => Map<String, Object?>.from(r as Map))
            .toList(),
      ),
    );
  }

  Future<BackupPreview> inspectBackup(
    Uint8List encrypted,
    String password,
  ) async {
    final archive = await _readArchive(encrypted, password);
    if (archive['format'] == 1) return const BackupPreview(legacy: true);
    final rows = _archiveRows(archive);
    if (db.hasImportedBackup(archive['id'] as String)) {
      throw const CareError('이미 복원한 백업입니다. 중복 추가하지 않았습니다.');
    }
    return BackupPreview(
      legacy: false,
      counts: rows.map((k, v) => MapEntry(k, v.length)),
    );
  }

  Future<void> importSelection(
    Uint8List encrypted,
    String password, {
    void Function()? beforeCommit,
  }) async {
    final archive = await _readArchive(encrypted, password);
    final rows = _archiveRows(archive);
    final archiveId = archive['id'] as String;
    if (db.hasImportedBackup(archiveId)) {
      throw const CareError('이미 복원한 백업입니다. 중복 추가하지 않았습니다.');
    }
    if (rows['patient_context'] == null || rows['patient_context']!.isEmpty) {
      throw const CareError('복원할 수첩이 없습니다.');
    }
    final files = Map<String, String>.from(archive['files'] as Map);
    final fileKeys = Map<String, String>.from(archive['file_keys'] as Map);
    final attachments = rows['attachment'] ?? [];
    final expected = attachments.map((r) => r['id']).toSet();
    if (expected.length != attachments.length ||
        files.length != expected.length ||
        fileKeys.length != expected.length ||
        files.keys.any(
          (id) => !VaultStore._id.hasMatch(id) || !expected.contains(id),
        ) ||
        fileKeys.keys.any((id) => !expected.contains(id))) {
      throw const CareError('백업의 사진 연결이 일치하지 않습니다.');
    }
    final ids = <String, String>{};
    for (final table in rows.values) {
      for (final row in table) {
        if (row['id'] case final String id) {
          if (!VaultStore._id.hasMatch(id) || ids.containsKey(id)) {
            throw const CareError('백업의 기록 식별자가 중복되거나 올바르지 않습니다.');
          }
          ids[id] = CareDatabase.newId();
        }
      }
    }
    // Build on an encrypted copy of the current vault. Nothing in the active
    // generation is changed until all rows, keys and photos pass verification.
    final generation = CareDatabase.newId();
    final stage = await Directory(p.join(root.path, generation))
        .create(recursive: true);
    final keys = Map<String, String>.from(_keys);
    CareDatabase? candidate;
    var committed = false;
    try {
      await cleanup();
      for (final name in ['care', 'identity']) {
        await File(p.join(_directory.path, '$name.db'))
            .copy(p.join(stage.path, '$name.db'));
      }
      final dir = await Directory(p.join(stage.path, 'attachments')).create();
      for (final id in db.allAttachmentIds) {
        await File(p.join(_directory.path, 'attachments', '$id.enc'))
            .copy(p.join(dir.path, '$id.enc'));
      }
      candidate = CareDatabase.open(
        stage.path,
        key: _key('care'),
        identityKey: _key('identity'),
      );
      var size = 0;
      for (final row in attachments) {
        final oldId = row['id'] as String, id = ids[oldId]!;
        final data = base64Decode(files[oldId]!);
        size += data.length;
        if (size > VaultStore.maxBackupBytes ~/ 2 ||
            row['size'] != data.length) {
          throw const CareError('백업의 사진 크기가 올바르지 않습니다.');
        }
        final sourceKey = base64Decode(fileKeys[oldId]!);
        if (sourceKey.length != 32) {
          throw const CareError('백업 사진 키가 올바르지 않습니다.');
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
          _key('files'),
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
      await secrets.write('vault.$generation', jsonEncode(keys));
      beforeCommit?.call();
      await _commit(generation);
      committed = true;
      db.close();
      db = candidate;
      candidate = null;
      _generation = generation;
      _keys = keys;
      await _maintain();
    } finally {
      candidate?.close();
      if (!committed) {
        if (await stage.exists()) await stage.delete(recursive: true);
        await secrets.delete('vault.$generation');
      }
    }
  }
}
