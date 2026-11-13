import 'dart:typed_data';

import '../ports.dart';
import '../session_access.dart';

typedef PickedPhoto = ({Uint8List bytes, int pixels});

final class PhotoService {
  PhotoService(this._scope, this._vault, this._platform);
  final SessionAccess _scope;
  final NotebookVault _vault;
  final PlatformServices _platform;
  Future<PickedPhoto?> pick(String pid, {bool camera = false}) {
    _scope.requirePatient(pid);
    return _scope.run((epoch) async {
      final data = await _scope.external(
        () => _platform.pickPhoto(camera: camera),
      );
      _scope.check(epoch);
      if (data == null) return null;
      final pixels = await _vault.validatePhoto(data);
      _scope.check(epoch);
      return (bytes: data, pixels: pixels);
    });
  }

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

  /// Read-only thumbnail loads need not block unrelated controls or each other.
  /// A lock/patient change invalidates their result before it reaches the UI.
  Future<Uint8List> preview(String pid, String eid, String id) async {
    _scope.requirePatient(pid);
    final epoch = _scope.capture();
    final data = await _vault.photo(pid, eid, id);
    _scope.check(epoch);
    return data;
  }

  Future<Uint8List> open(
    String pid,
    String eid,
    String id, {
    bool forOcr = false,
  }) async {
    _scope.requirePatient(pid);
    return _scope.run((epoch) async {
      final data = await _vault.photo(pid, eid, id);
      _scope.check(epoch);
      if (forOcr) {
        await _vault.validatePhoto(data, forOcr: true);
        _scope.check(epoch);
      }
      return data;
    });
  }
}
