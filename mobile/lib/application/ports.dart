import 'dart:typed_data';

import '../domain/backup.dart';
import '../l10n/app_strings.dart';
import 'notebook_repository.dart';

abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Typed access to authentication preferences; raw key storage stays private.
abstract interface class Credentials {
  Future<bool> hasPin();
  Future<void> setPin(String pin, {required void Function() beforeCommit});
  Future<void> verifyPin(String pin);
  Future<bool> deviceEnabled();
  Future<void> setDeviceEnabled(bool value);
  Future<String?> language();
  Future<void> setLanguage(String code);
  Future<void> clearAuthentication();
}

abstract interface class NotebookVault {
  NotebookRepository get repository;
  Credentials get credentials;
  bool get maintenancePending;
  Future<void> open();
  void close();
  Future<void> cleanup({bool removeOrphans = true});
  Future<void> wipe();
  Future<void> addPhoto(
    String pid,
    String eid,
    Uint8List data, {
    void Function()? beforeCommit,
  });
  Future<Uint8List> photo(String pid, String eid, String id);
  Future<Uint8List> backup(String password);
  Future<Uint8List> backupSelection(String password, BackupSelection selection);
  BackupPreview previewSelection(BackupSelection selection);
  Future<BackupPreview> inspectBackup(Uint8List data, String password);
  Future<void> importSelection(
    Uint8List data,
    String password, {
    void Function()? beforeCommit,
  });
  Future<void> restore(
    Uint8List data,
    String password, {
    void Function()? beforeCommit,
  });
}

abstract class PlatformServices {
  AppStrings strings = const AppStrings(AppLanguage.korean);
  Future<String> timeZone();
  Future<bool> authenticate();
  Future<bool> requestNotifications();
  Future<void> schedule(List<Reminder> reminders);
  Future<Uint8List?> pickPhoto({bool camera = false});
  Future<void> saveBackup(Uint8List data);
  Future<Uint8List?> pickBackup();
  Future<void> dial(String number);
}

class Reminder {
  const Reminder(this.id, this.at, {this.daily = false});
  final int id;
  final DateTime at;
  final bool daily;
  static int idFor(String source) {
    var hash = 0x811c9dc5;
    for (final unit in source.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }
}
