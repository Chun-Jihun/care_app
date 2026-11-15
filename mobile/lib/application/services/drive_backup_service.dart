import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../domain/backup.dart';
import '../../domain/records.dart';
import '../ports.dart';
import '../session_access.dart';

typedef DriveBackupFile = ({
  String id,
  DateTime modifiedAt,
  String accountEmail,
});

abstract interface class BackupDrive {
  Future<String> connect();
  Future<void> reconnect(String email);
  Future<void> disconnect(String email);
  Future<String> reserveFile(String email);
  Future<void> upload(
    String email,
    String fileId,
    Uint8List data,
    void Function() check,
  );
  Future<List<DriveBackupFile>> files(String email);
  Future<Uint8List> download(String email, String fileId);
}

typedef DriveBackupStatus = ({String email, DateTime? lastSuccess});

final class DriveBackupService {
  DriveBackupService(
    this._scope,
    this._vault,
    this._secrets,
    this._drive,
    this._snapshot,
  );

  final SessionAccess _scope;
  final NotebookVault _vault;
  final SecretStore _secrets;
  final BackupDrive _drive;
  final SessionRun _snapshot;
  static const _key = 'drive.backup';
  bool _running = false;
  Object? _failure;
  Object? get failure => _failure;
  final _changes = ValueNotifier(0);
  ValueListenable<int> get changes => _changes;
  bool _disposed = false;
  void dispose() {
    _disposed = true;
    _revision++;
    _changes.dispose();
  }

  void _notify() {
    if (!_disposed) _changes.value++;
  }

  int _revision = 0;
  Future<void> _pendingWrite = Future.value();

  Future<void> _persist(Map<String, dynamic>? settings) {
    final write = _pendingWrite.then(
      (_) => settings == null
          ? _secrets.delete(_key)
          : _secrets.write(_key, jsonEncode(settings)),
    );
    _pendingWrite = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  Future<Map<String, dynamic>?> _settings() async {
    final data = await _secrets.read(_key);
    return data == null ? null : jsonDecode(data) as Map<String, dynamic>;
  }

  Future<DriveBackupStatus?> status() async {
    final epoch = _scope.capture();
    final settings = await _settings();
    _scope.check(epoch);
    if (settings == null) return null;
    return (
      email: settings['email'] as String,
      lastSuccess: DateTime.tryParse(settings['lastSuccess'] as String? ?? ''),
    );
  }

  Future<T> _run<T>(Future<T> Function(int epoch) action) async {
    if (_running) throw CareError(CareErrorCode.busy);
    final epoch = _scope.capture();
    _running = true;
    try {
      return await action(epoch);
    } finally {
      _running = false;
      _notify();
    }
  }

  Future<void> enable(String password) => _run((epoch) async {
    final revision = _revision;
    if (password.length < 12) {
      throw CareError(CareErrorCode.backupPasswordTooShort);
    }
    if (await _settings() != null) throw CareError(CareErrorCode.busy);
    _scope.check(epoch);
    final email = await _scope.external(_drive.connect);
    _scope.check(epoch);
    if (revision != _revision) throw CareError(CareErrorCode.locked);
    await _persist({'email': email, 'password': password});
    _failure = null;
  });

  Future<void> reconnect() => _run((epoch) async {
    final email = (await _settings())?['email'] as String?;
    _scope.check(epoch);
    if (email == null) {
      throw CareError(CareErrorCode.driveAuthorizationRequired);
    }
    await _scope.external(() => _drive.reconnect(email));
    _scope.check(epoch);
    _failure = null;
  });

  Future<void> disconnect() => _run((epoch) async {
    final email = (await _settings())?['email'] as String?;
    _scope.check(epoch);
    await clearLocalSettings();
    if (email != null) await _drive.disconnect(email);
  });

  Future<void> clearLocalSettings() async {
    _revision++;
    await _persist(null);
    _failure = null;
  }

  Future<void> backup({bool now = false}) async {
    if (_running && !now) return;
    if (_running) throw CareError(CareErrorCode.busy);
    try {
      await _run((epoch) async {
        final revision = _revision;
        final settings = await _settings();
        if (settings == null) return;
        final today = DateTime.now();
        final last = DateTime.tryParse(settings['lastSuccess'] as String? ?? '')
            ?.toLocal();
        if (!now &&
            last != null &&
            last.year == today.year &&
            last.month == today.month &&
            last.day == today.day) {
          return;
        }
        void check() {
          _scope.check(epoch);
          if (revision != _revision) throw CareError(CareErrorCode.locked);
        }

        final account = settings['email'] as String;
        var fileId = settings['fileId'] as String?;
        check();
        if (fileId == null) {
          fileId = await _drive.reserveFile(account);
          check();
          settings['fileId'] = fileId;
          await _persist(settings);
        }
        check();
        final encrypted = await _snapshot((snapshotEpoch) async {
          check();
          final data = await _vault.backupSelection(
            settings['password'] as String,
            BackupSelection(
              patientIds: _scope.repository.patients().map((p) => p.id).toSet(),
            ),
          );
          _scope.check(snapshotEpoch);
          return data;
        });
        check();
        await _drive.upload(account, fileId, encrypted, check);
        if (revision != _revision) return;
        settings['lastSuccess'] = DateTime.now().toUtc().toIso8601String();
        await _persist(settings);
        _failure = null;
      });
    } catch (error, stackTrace) {
      final reported = switch (error) {
        CareError(
          code: CareErrorCode.backupPhotosTooLarge ||
              CareErrorCode.backupSelectionTooLarge,
        ) =>
          CareError(CareErrorCode.driveBackupTooLarge),
        _ => error,
      };
      _failure = reported;
      _notify();
      if (now) Error.throwWithStackTrace(reported, stackTrace);
    }
  }

  Future<List<DriveBackupFile>> availableFiles() => _run((epoch) async {
    final settings = await _settings();
    _scope.check(epoch);
    final account = settings == null
        ? await _scope.external<String>(_drive.connect)
        : settings['email'] as String;
    _scope.check(epoch);
    final files = await _drive.files(account);
    _scope.check(epoch);
    return files;
  });

  Future<Uint8List> download(DriveBackupFile file) => _run((epoch) async {
    final data = await _drive.download(file.accountEmail, file.id);
    _scope.check(epoch);
    return data;
  });
}
