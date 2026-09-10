import 'package:flutter/foundation.dart';

import '../../domain/drafts.dart';
import '../../domain/records.dart';
import '../session_access.dart';

final class DraftService {
  DraftService(this._scope, {required this._busy, required this._notify});
  final SessionAccess _scope;
  final bool Function() _busy;
  final VoidCallback _notify;
  final _flushers = <VoidCallback>{};
  bool _locking = false, _failedFlush = false;
  void registerFlusher(VoidCallback flush) => _flushers.add(flush);
  void unregisterFlusher(VoidCallback flush) => _flushers.remove(flush);
  void changed() => _notify();
  void flushAll({bool locking = false}) {
    _locking = locking;
    try {
      for (final flush in List<VoidCallback>.of(_flushers)) {
        try {
          flush();
        } catch (_) {
          if (!locking) rethrow;
          _failedFlush = true;
        }
      }
    } finally {
      _locking = false;
    }
  }

  bool takeFlushFailure() {
    final failed = _failedFlush;
    _failedFlush = false;
    return failed;
  }

  String newId() => _scope.newId();
  int capture() => _scope.capture();
  DraftRetention? get retention => _scope.repository.draftRetention;
  List<CareDraft> list(String? pid) {
    _scope.requirePatient(pid);
    return List.unmodifiable(_scope.repository.drafts(pid));
  }

  int count(String? pid) {
    _scope.requirePatient(pid);
    return _scope.repository.draftCount(pid);
  }

  String? base(DraftType type, String? pid, String? targetId) {
    _scope.requirePatient(pid);
    return _scope.repository.draftBase(type, pid, targetId);
  }

  Future<void> setRetention(DraftRetention value) => _scope.write(
    null,
    ChangeImpact.drafts,
    (repository) => repository.setDraftRetention(value),
  );
  void saveNow({
    required String id,
    required String? patientId,
    required DraftPayload payload,
    required int session,
    required bool create,
    String? targetId,
    String? base,
  }) {
    _scope.check(session);
    _scope.requirePatient(patientId);
    if (_busy() && !_locking) {
      throw CareError(CareErrorCode.busy);
    }
    _scope.repository.saveDraft(
      id: id,
      patientId: patientId,
      type: payload.type,
      payload: payload,
      targetId: targetId,
      base: base,
      create: create,
    );
  }

  Future<void> complete(String? pid, String id, int session) async {
    _scope.check(session);
    final draft = list(pid).where((d) => d.id == id).firstOrNull;
    final impact = switch (draft?.type) {
      DraftType.medication => ChangeImpact.medications,
      DraftType.task => ChangeImpact.tasks,
      DraftType.visit => ChangeImpact.visits,
      DraftType.checkin => ChangeImpact.checkins,
      _ => ChangeImpact.records,
    };
    return _scope.write(
      pid,
      impact,
      (repository) => repository.completeDraft(pid, id),
    );
  }

  Future<void> delete(String? pid, String id) => _scope.write(
    pid,
    ChangeImpact.drafts,
    (repository) => repository.deleteDraft(pid, id),
  );
}
