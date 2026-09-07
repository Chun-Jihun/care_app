import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;

import '../domain/records.dart';
import 'care_database.dart';
import 'crypto.dart';

abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class VaultStore {
  VaultStore(this.root, this.secrets);
  final Directory root;
  final SecretStore secrets;
  late CareDatabase db;
  late String _generation;
  late Map<String, String> _keys;
  bool _opened = false;
  bool maintenancePending = false;
  static const maxBackupBytes = 100 * 1024 * 1024;
  static final _id = RegExp(r'^[0-9a-fA-F-]{36}$');
  Directory get _directory => Directory(p.join(root.path, _generation));
  Uint8List _key(String name) => base64Decode(_keys[name]!);

  Future<void> open() async {
    await root.create(recursive: true);
    if (await File(p.join(root.path, 'wipe.pending')).exists()) {
      await _finishWipe();
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
      _generation = CareDatabase.newId();
      _keys = {
        for (final k in ['care', 'identity', 'files'])
          k: base64Encode(VaultCrypto.randomBytes()),
      };
      await secrets.write('vault.$_generation', jsonEncode(_keys));
      db = CareDatabase.open(
        _directory.path,
        key: _key('care'),
        identityKey: _key('identity'),
      );
      await _commit(_generation);
    } else {
      _generation = (await File(markers.last.path).readAsString()).trim();
      if (!_id.hasMatch(_generation)) {
        throw const CareError('저장소 위치를 확인할 수 없습니다.');
      }
      final encoded = await secrets.read('vault.$_generation');
      if (encoded == null) {
        throw const CareError('기기 보안 키를 찾을 수 없습니다. 암호화 백업이 필요합니다.');
      }
      _keys = Map<String, String>.from(jsonDecode(encoded));
      for (final file in ['care.db', 'identity.db']) {
        if (!await File(p.join(_directory.path, file)).exists()) {
          throw const CareError('저장소 파일이 없습니다. 기존 데이터를 보존했습니다.');
        }
      }
      db = CareDatabase.open(
        _directory.path,
        key: _key('care'),
        identityKey: _key('identity'),
      );
    }
    _opened = true;
    await _maintain();
  }

  Future<void> _maintain() async {
    maintenancePending = false;
    try {
      await cleanup();
      await _prune();
    } catch (_) {
      // The selected generation is already committed. Maintenance failure must
      // not report a failed restore or leave the controller on the old patient.
      maintenancePending = true;
    }
  }

  Future<void> _commit(String id) async {
    final dir = await Directory(p.join(root.path, 'commits'))
        .create(recursive: true);
    // Legacy UUIDv7 markers sort by wall clock and can go backwards. New
    // markers use a persisted sequence and sort after every legacy marker.
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

  Future<void> _prune() async {
    await for (final entity in root.list()) {
      final name = p.basename(entity.path);
      if (entity is Directory && _id.hasMatch(name) && name != _generation) {
        await secrets.delete('vault.$name');
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
    final directory = await Directory(p.join(_directory.path, 'attachments'))
        .create(recursive: true);
    for (final id in db.pendingFileDeletes) {
      if (!_id.hasMatch(id)) {
        throw const CareError('삭제할 첨부파일을 확인할 수 없습니다.');
      }
      final file = File(p.join(directory.path, '$id.enc'));
      if (await file.exists()) {
        await file.delete();
      }
      db.finishFileDelete(id);
    }
    if (!removeOrphans) return;
    final allowed = db.allAttachmentIds.toSet();
    await for (final entity in directory.list()) {
      if (entity is File &&
          !allowed.contains(p.basenameWithoutExtension(entity.path))) {
        await entity.delete();
      }
    }
  }

  Future<void> addPhoto(
    String pid,
    String eid,
    Uint8List source, {
    void Function()? beforeCommit,
  }) async {
    if (source.length > 20 * 1024 * 1024) {
      throw const CareError('사진은 20MB 이하로 선택해 주세요.');
    }
    db.attachments(pid, eid); // Resolve scope before doing any file work.
    final normalized = await Isolate.run(() => normalizePhoto(source));
    final id = CareDatabase.newId();
    final key = VaultCrypto.randomBytes();
    final encrypted = await VaultCrypto.seal(
      normalized,
      key,
      context: 'photo:$id',
    );
    final wrapped = await VaultCrypto.seal(
      key,
      _key('files'),
      context: 'key:$id',
    );
    final dir = await Directory(p.join(_directory.path, 'attachments'))
        .create(recursive: true);
    final file = File(p.join(dir.path, '$id.enc'));
    try {
      await file.writeAsBytes(encrypted, flush: true);
      beforeCommit?.call();
      db.addAttachment(pid, eid, id, base64Encode(wrapped), encrypted.length);
    } catch (_) {
      if (await file.exists()) {
        await file.delete();
      }
      rethrow;
    }
  }

  static Uint8List normalizePhoto(Uint8List source) {
    if (source.length > 20 * 1024 * 1024) {
      throw const CareError('사진은 20MB 이하로 선택해 주세요.');
    }
    // Restrict to the supported still-photo formats; inspect dimensions before
    // allocating pixels, and never decode all frames of an animation.
    final img.Decoder decoder;
    if (img.JpegDecoder().isValidFile(source)) {
      decoder = img.JpegDecoder();
    } else if (img.PngDecoder().isValidFile(source)) {
      decoder = img.PngDecoder();
    } else {
      throw const CareError('사진을 읽을 수 없습니다. JPG 또는 PNG 사진을 선택해 주세요.');
    }
    final info = decoder.startDecode(source);
    if (info == null || info.width <= 0 || info.height <= 0) {
      throw const CareError('사진 파일이 올바르지 않습니다.');
    }
    if (info.width * info.height > 24000000) {
      throw const CareError('사진 크기가 너무 큽니다. 2,400만 화소 이하의 사진을 선택해 주세요.');
    }
    if (info.numFrames != 1) {
      throw const CareError('움직이는 사진은 지원하지 않습니다. 정지 사진을 선택해 주세요.');
    }
    final decoded = decoder.decodeFrame(0);
    if (decoded == null) throw const CareError('사진을 읽을 수 없습니다.');
    final oriented = img.bakeOrientation(decoded);
    // A fresh raster has no EXIF, GPS, original name, embedded thumbnail or text chunks.
    final clean = img.Image(
      width: oriented.width,
      height: oriented.height,
      numChannels: 3,
    );
    img.compositeImage(clean, oriented);
    return Uint8List.fromList(img.encodeJpg(clean, quality: 94));
  }

  Future<Uint8List> photo(String pid, String eid, String id) async {
    final item = db.attachments(pid, eid).where((a) => a.id == id).firstOrNull;
    if (item == null || !_id.hasMatch(id)) {
      throw const CareError('현재 기록의 사진을 찾을 수 없습니다.');
    }
    final key = await VaultCrypto.open(
      base64Decode(item.wrappedKey),
      _key('files'),
      context: 'key:$id',
    );
    return VaultCrypto.open(
      await File(p.join(_directory.path, 'attachments', '$id.enc'))
          .readAsBytes(),
      key,
      context: 'photo:$id',
    );
  }

  Future<Uint8List> backup(String password) async {
    if (password.length < 12) {
      throw const CareError('백업 비밀번호는 12자 이상으로 입력해 주세요.');
    }
    db.pruneChats();
    await cleanup();
    db.verifyIntegrity();
    final files = <String, String>{};
    var size = 0;
    for (final id in db.allAttachmentIds) {
      final data = await File(p.join(_directory.path, 'attachments', '$id.enc'))
          .readAsBytes();
      size += data.length;
      if (size > maxBackupBytes / 2) {
        throw const CareError('현재 버전은 사진을 포함해 50MB까지 한 번에 백업할 수 있습니다.');
      }
      files[id] = base64Encode(data);
    }
    final payload = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 1,
          'keys': _keys,
          'care': base64Encode(
            await File(p.join(_directory.path, 'care.db')).readAsBytes(),
          ),
          'identity': base64Encode(
            await File(p.join(_directory.path, 'identity.db')).readAsBytes(),
          ),
          'files': files,
        }),
      ),
    );
    if (payload.length > maxBackupBytes) {
      throw const CareError('백업 크기가 현재 버전의 한도를 초과했습니다.');
    }
    return Isolate.run(() => VaultCrypto.passwordSeal(payload, password));
  }

  Future<void> restore(
    Uint8List encrypted,
    String password, {
    void Function()? beforeCommit,
  }) async {
    if (encrypted.length > maxBackupBytes + 128) {
      throw const CareError('백업 파일이 너무 큽니다.');
    }
    final clear = await Isolate.run(
      () => VaultCrypto.passwordOpen(encrypted, password),
    );
    final data = jsonDecode(utf8.decode(clear));
    if (data is! Map ||
        data['format'] != 1 ||
        data['keys'] is! Map ||
        data['files'] is! Map) {
      throw const CareError('지원하지 않는 백업 형식입니다.');
    }
    final keys = Map<String, String>.from(data['keys'] as Map);
    if (![
      'care',
      'identity',
      'files',
    ].every((k) => keys[k] != null && base64Decode(keys[k]!).length == 32)) {
      throw const CareError('백업 키 형식이 올바르지 않습니다.');
    }
    final generation = CareDatabase.newId();
    final stage = await Directory(p.join(root.path, generation))
        .create(recursive: true);
    CareDatabase? candidate;
    var committed = false;
    try {
      for (final name in ['care', 'identity']) {
        final bytes = base64Decode(data[name] as String);
        if (bytes.length < 512) {
          throw const CareError('백업 저장소가 불완전합니다.');
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
          files.keys.any((k) => !_id.hasMatch(k) || !expected.contains(k))) {
        throw const CareError('백업의 사진 연결이 일치하지 않습니다.');
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
      await secrets.write('vault.$generation', jsonEncode(keys));
      beforeCommit?.call();
      await _commit(
        generation,
      ); // Nothing affecting the old generation changes before this point.
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
        if (await stage.exists()) {
          await stage.delete(recursive: true);
        }
        await secrets.delete('vault.$generation');
      }
    }
  }

  Future<void> wipe() async {
    await File(p.join(root.path, 'wipe.pending'))
        .writeAsString('1', flush: true);
    if (_opened) {
      close();
    }
    await _finishWipe();
  }

  Future<void> _finishWipe() async {
    await for (final entity in root.list()) {
      if (p.basename(entity.path) == 'wipe.pending') {
        continue;
      }
      final name = p.basename(entity.path);
      if (entity is Directory && _id.hasMatch(name)) {
        await secrets.delete('vault.$name');
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
      db.close();
      _opened = false;
      _keys.clear();
    }
  }
}
