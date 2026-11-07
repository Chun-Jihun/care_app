import 'dart:typed_data';

import '../../domain/records.dart';
import '../../domain/visit_recording.dart';
import '../session_access.dart';

final class VisitRecordingService {
  VisitRecordingService(this._scope, this._busy);

  final SessionAccess _scope;
  final bool Function() _busy;

  void _write(String pid) {
    _scope.requirePatient(pid);
    if (_busy()) throw CareError(CareErrorCode.busy);
  }

  List<VisitRecording> list(String pid) {
    _scope.requirePatient(pid);
    return _scope.repository.visitRecordings(pid);
  }

  VisitRecording begin(String pid) {
    _write(pid);
    return _scope.repository.beginVisitRecording(pid);
  }

  void append(String pid, String id, Uint8List pcm) {
    _write(pid);
    _scope.repository.appendVisitAudio(pid, id, pcm);
  }

  Uint8List? read(String pid, String id, int offset) {
    _scope.requirePatient(pid);
    return _scope.repository.readVisitAudio(pid, id, offset);
  }

  void keep(String pid, String id) {
    _write(pid);
    _scope.repository.keepVisitRecording(pid, id);
  }

  void delete(String pid, String id) {
    _write(pid);
    _scope.repository.deleteVisitRecording(pid, id);
  }
}
