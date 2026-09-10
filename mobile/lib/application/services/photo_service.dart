import 'dart:typed_data';

import '../ports.dart';
import '../session_access.dart';

final class PhotoService {
  PhotoService(this._scope, this._vault, this._platform);
  final SessionAccess _scope;
  final NotebookVault _vault;
  final PlatformServices _platform;
  Future<void> add(String pid, String eid, {bool camera = false}) async {
    _scope.requirePatient(pid);
    return _scope.run((epoch) async {
      final data = await _scope.external(
        () => _platform.pickPhoto(camera: camera),
      );
      _scope.check(epoch);
      if (data == null) return;
      await _vault.addPhoto(
        pid,
        eid,
        data,
        beforeCommit: () => _scope.check(epoch),
      );
      await _scope.changed(ChangeImpact.photos);
    });
  }

  Future<Uint8List> open(String pid, String eid, String id) async {
    _scope.requirePatient(pid);
    return _scope.run((epoch) async {
      final data = await _vault.photo(pid, eid, id);
      _scope.check(epoch);
      return data;
    });
  }
}
