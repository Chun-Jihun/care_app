import 'dart:typed_data';

import '../../domain/backup.dart';
import '../ports.dart';
import '../session_access.dart';

final class BackupService {
  BackupService(
    this._scope,
    this._vault,
    this._platform, {
    required this._onReplace,
  });
  final void Function() _onReplace;
  final SessionAccess _scope;
  final NotebookVault _vault;
  final PlatformServices _platform;
  BackupPreview preview(BackupSelection selection) {
    _scope.capture();
    return _vault.previewSelection(selection);
  }

  Future<void> export(String password, BackupSelection selection) =>
      _scope.run((epoch) async {
        final data = await _vault.backupSelection(password, selection);
        _scope.check(epoch);
        await _scope.external(() => _platform.saveBackup(data));
      });
  Future<void> exportLegacy(String password) => _scope.run((epoch) async {
    final data = await _vault.backup(password);
    _scope.check(epoch);
    await _scope.external(() => _platform.saveBackup(data));
  });
  Future<BackupPreview> inspect(Uint8List data, String password) =>
      _scope.run((epoch) async {
        final result = await _vault.inspectBackup(data, password);
        _scope.check(epoch);
        return result;
      });
  Future<void> importSelection(Uint8List data, String password) =>
      _scope.run((epoch) async {
        await _vault.importSelection(
          data,
          password,
          beforeCommit: () => _scope.check(epoch),
        );
        await _scope.changed(ChangeImpact.all);
      });
  Future<Uint8List?> choose() => _scope.run((epoch) async {
    final data = await _scope.external(_platform.pickBackup);
    _scope.check(epoch);
    return data;
  });
  Future<void> restore(Uint8List data, String password) =>
      _scope.run((epoch) async {
        await _vault.restore(
          data,
          password,
          beforeCommit: () => _scope.check(epoch),
        );
        _onReplace();
        await _scope.changed(ChangeImpact.all);
      });
}
