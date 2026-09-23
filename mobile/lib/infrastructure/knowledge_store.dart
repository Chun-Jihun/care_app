import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/knowledge.dart';
import '../domain/knowledge_installation.dart';
import 'knowledge_package.dart';

/// Immutable versions + append-only activation journal. No network access.
/// Import bytes must match an application-pinned descriptor BEFORE DB parsing.
final class KnowledgeStore {
  KnowledgeStore(
    this.root,
    List<KnowledgeRelease> allowed, {
    this.allowPreview = false,
  }) : releases = Map.unmodifiable({for (final r in allowed) r.id: r});
  final Directory root;
  final Map<String, KnowledgeRelease> releases;
  final bool allowPreview;
  bool _busy = false;
  Never _fail() => throw const KnowledgePackageException(
    '근거 자료를 확인할 수 없습니다. 파일과 저장 공간을 확인해 주세요.',
  );

  KnowledgeRelease _allowed(String id) {
    final r = releases[id];
    if (r == null || (r.preview && !allowPreview)) _fail();
    return r;
  }

  Directory _version(String id) {
    _allowed(id);
    return Directory(p.join(root.path, id));
  }

  Future<List<String>> _history() async {
    if (!await root.exists()) return [];
    final files = await root
        .list(followLinks: false)
        .where(
          (e) =>
              e is File &&
              RegExp(r'^active-[0-9]{12}-[a-f0-9]{64}$')
                  .hasMatch(p.basename(e.path)),
        )
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    final ids = <String>[];
    for (final file in files) {
      final id = p.basename(file.path).substring(20);
      // An unrecognized/revoked active ID must not silently activate old data.
      if (!ids.contains(id)) ids.add(id);
    }
    return ids;
  }

  Future<KnowledgeInstallation> status() async {
    final history = await _history();
    if (history.isEmpty) return const KnowledgeInstallation();
    KnowledgeRelease? active, previous;
    var damaged = false;
    try {
      active = _allowed(history.first);
      await verify(active);
    } on Object {
      damaged = true;
    }
    for (final id in history.skip(1)) {
      try {
        final candidate = _allowed(id);
        await verify(candidate);
        previous = candidate;
        break;
      } on Object {
        // A damaged or withdrawn previous version is not a rollback target.
      }
    }
    return KnowledgeInstallation(
      active: active,
      previous: previous,
      damaged: damaged,
    );
  }

  Future<void> verify(KnowledgeRelease release, {Directory? directory}) async {
    _allowed(release.id);
    final dir = directory ?? _version(release.id);
    await Isolate.run(() => _verifyFiles(dir.path, release.files));
  }

  static Future<void> _verifyFiles(
    String directory,
    List<KnowledgeReleaseFile> files,
  ) async {
    void fail() =>
        throw const KnowledgePackageException('근거 자료 무결성을 확인하지 못했습니다.');
    if (await FileSystemEntity.type(directory, followLinks: false) !=
        FileSystemEntityType.directory) {
      fail();
    }
    for (final entry in files) {
      final file = File(p.join(directory, entry.name));
      if (await FileSystemEntity.type(file.parent.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() != entry.bytes ||
          (await sha256.bind(file.openRead()).first).toString() !=
              entry.sha256) {
        fail();
      }
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    if (_busy) throw const KnowledgePackageException('근거 자료 작업이 진행 중입니다.');
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }

  Future<void> install(
    String path,
    void Function(double) progress,
    void Function() check,
  ) => _exclusive(() async {
    await root.create(recursive: true);
    // Interrupted stages can never be activated. Cleanup is restricted to this
    // store's direct staging children and never follows links.
    await for (final e in root.list(followLinks: false)) {
      if (e is Directory && p.basename(e.path).startsWith('stage-')) {
        await _deleteStage(e);
      }
    }
    final input = await File(path).open();
    Directory? stage;
    try {
      final header = await input.read(12);
      if (header.length != 12 ||
          ascii.decode(header.sublist(0, 8), allowInvalid: true) !=
              'CAREKB01') {
        _fail();
      }
      final length = ByteData.sublistView(header).getUint32(8, Endian.little);
      if (length < 1 || length > 65536) _fail();
      final bytes = await input.read(length);
      if (bytes.length != length) _fail();
      final release = _allowed(sha256.convert(bytes).toString());
      if (await input.length() != 12 + length + release.payloadBytes) _fail();
      check();
      stage = await root.createTemp('stage-');
      var done = 0;
      for (final entry in release.files) {
        final file = File(p.join(stage.path, entry.name));
        await file.parent.create(recursive: true);
        final output = await file.open(mode: FileMode.write);
        try {
          var remaining = entry.bytes;
          while (remaining > 0) {
            check();
            final chunk = await input.read(remaining.clamp(1, 1024 * 1024));
            if (chunk.isEmpty) _fail();
            await output.writeFrom(chunk);
            remaining -= chunk.length;
            done += chunk.length;
            progress(done / release.payloadBytes * .8);
          }
          await output.flush();
        } finally {
          await output.close();
        }
      }
      await verify(release, directory: stage);
      // All bytes have been authenticated to the app's catalog before SQLite.
      for (final entry in release.files.where(
        (f) => f.name.endsWith('.sqlite3'),
      )) {
        final directory = p.dirname(p.join(stage.path, entry.name));
        if (release.preview) {
          await LocalKnowledgePackage.openForReview(
            directory,
            expectedHash: entry.sha256,
          );
        } else {
          await LocalKnowledgePackage.openApproved(
            directory,
            expectedHash: entry.sha256,
          );
        }
      }
      check();
      final destination = _version(release.id);
      if (await destination.exists()) {
        // Never delete an installed version under a historical citation.
        await verify(release);
      } else {
        await stage.rename(destination.path);
      }
      check();
      await _activate(
        release,
        beforeCommit: () {
          check();
          // After this point the atomic rename is submitted; the UI must stop
          // accepting cancellation instead of claiming a committed install stopped.
          progress(1);
        },
      );
      progress(1);
    } finally {
      await input.close();
      if (stage != null && await stage.exists()) await _deleteStage(stage);
    }
  });

  Future<void> _deleteStage(Directory stage) async {
    final base = p.normalize(p.absolute(root.path));
    final target = p.normalize(p.absolute(stage.path));
    if (p.dirname(target) != base ||
        !p.basename(target).startsWith('stage-') ||
        await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.directory) {
      _fail();
    }
    await stage.delete(recursive: true);
  }

  Future<void> _activate(
    KnowledgeRelease release, {
    void Function()? beforeCommit,
  }) async {
    var sequence = 0;
    await for (final e in root.list(followLinks: false)) {
      final m = RegExp(r'^active-([0-9]{12})-[a-f0-9]{64}$')
          .firstMatch(p.basename(e.path));
      if (m != null) {
        final n = int.parse(m[1]!);
        if (n > sequence) sequence = n;
      }
    }
    if (sequence >= 999999999998) _fail();
    final pending = File(p.join(root.path, 'activation.pending'));
    await pending.writeAsString(release.id, flush: true);
    beforeCommit?.call();
    await pending.rename(
      p.join(
        root.path,
        'active-${(sequence + 1).toString().padLeft(12, '0')}-${release.id}',
      ),
    );
  }

  Future<void> rollback() => _exclusive(() async {
    final previous = (await status()).previous;
    if (previous == null) _fail();
    await verify(previous);
    await _activate(previous);
  });

  Future<LocalKnowledgePackage?> reader({
    String? packageHash,
    String kind = 'documents',
  }) async {
    final history = await _history();
    for (final id in packageHash == null ? history.take(1) : history) {
      final release = _allowed(id);
      final file = release.files
          .where((f) => f.name == '$kind/knowledge.sqlite3')
          .firstOrNull;
      if (file == null || (packageHash != null && file.sha256 != packageHash)) {
        continue;
      }
      await verify(release);
      final directory = p.join(_version(id).path, kind);
      return release.preview
          ? LocalKnowledgePackage.openForReview(
              directory,
              expectedHash: file.sha256,
            )
          : LocalKnowledgePackage.openApproved(
              directory,
              expectedHash: file.sha256,
            );
    }
    return null;
  }
}
