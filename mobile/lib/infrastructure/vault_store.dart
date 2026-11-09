import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import '../application/notebook_repository.dart';
import '../application/ports.dart';
import '../domain/backup.dart';
import 'vault_state.dart';
import 'vault_photos.dart';
import 'vault_backups.dart';
import 'local_credentials.dart';
import 'local_preferences.dart';
export '../application/ports.dart' show SecretStore;

/// Implements the application vault port without exposing its keys or database.
final class VaultStore implements NotebookVault {
  VaultStore(
    Directory root,
    SecretStore secrets, {
    Future<int> Function()? availableBytes,
  }) : _state = VaultState(root, secrets, availableBytes),
       credentials = LocalCredentials(secrets),
       preferences = LocalPreferences(secrets);
  final VaultState _state;
  @override
  final Credentials credentials;
  @override
  final DevicePreferences preferences;
  late final _photos = VaultPhotos(_state);
  late final _backups = VaultBackups(_state);
  @override
  NotebookRepository get repository => _state.database;
  @override
  bool get maintenancePending => _state.maintenancePending;
  static const maxBackupBytes = VaultState.maxBackupBytes;
  static Uint8List normalizePhoto(Uint8List source) =>
      VaultPhotos.normalizePhoto(source);
  @override
  Future<void> open() => _state.open();
  @override
  Future<void> cleanup({bool removeOrphans = true}) =>
      _state.cleanup(removeOrphans: removeOrphans);
  @override
  Future<void> wipe() => _state.wipe();
  @override
  Future<int> compactStorage({void Function()? beforeCommit}) =>
      _state.compactStorage(beforeCommit: beforeCommit);
  @override
  void close() => _state.close();
  @override
  Future<void> validatePhoto(Uint8List data) =>
      Isolate.run(() => VaultPhotos.validatePhoto(data));
  @override
  Future<void> addPhoto(
    String pid,
    String eid,
    Uint8List source, {
    void Function()? beforeCommit,
  }) => _photos.addPhoto(pid, eid, source, beforeCommit: beforeCommit);
  @override
  Future<void> completeDraftWithPhoto(
    String pid,
    String draftId,
    Uint8List data, {
    void Function()? beforeCommit,
  }) => _photos.completeDraftWithPhoto(
    pid,
    draftId,
    data,
    beforeCommit: beforeCommit,
  );
  @override
  Future<Uint8List> photo(String pid, String eid, String id) =>
      _photos.photo(pid, eid, id);
  @override
  Future<void> restore(
    Uint8List encrypted,
    String password, {
    void Function()? beforeCommit,
  }) => _backups.restore(encrypted, password, beforeCommit: beforeCommit);
  @override
  Future<Uint8List> backupSelection(
    String password,
    BackupSelection selection,
  ) => _backups.backupSelection(password, selection);
  @override
  Future<BackupPreview> inspectBackup(Uint8List encrypted, String password) =>
      _backups.inspectBackup(encrypted, password);
  @override
  Future<void> importSelection(
    Uint8List encrypted,
    String password, {
    void Function()? beforeCommit,
  }) =>
      _backups.importSelection(encrypted, password, beforeCommit: beforeCommit);
  @override
  BackupPreview previewSelection(BackupSelection selection) =>
      _backups.previewSelection(selection);
}
