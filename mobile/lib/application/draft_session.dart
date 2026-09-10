import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/drafts.dart';
import '../domain/records.dart';
import 'care_controller.dart';

/// One editor owns one session. Timers never outlive its private route.
class DraftSession {
  DraftSession(
    CareController c, {
    required this.patientId,
    required this.type,
    required DraftPayload Function() snapshot,
    this.targetId,
    CareDraft? restored,
  }) : _c = c,
       _snapshot = snapshot,
       id = restored?.id ?? c.drafts.newId(),
       base = restored?.base ?? c.drafts.base(type, patientId, targetId),
       _saved = restored != null {
    _session = c.captureSession();
    if (restored != null &&
        (restored.patientId != patientId ||
            restored.type != type ||
            restored.targetId != targetId)) {
      throw CareError(CareErrorCode.draftEditorMismatch);
    }
    _last = snapshot().encode();
    _status.value = _saved ? DraftStatus.restored : DraftStatus.waiting;
    c.drafts.registerFlusher(flush);
  }
  final CareController _c;
  final String id;
  final String? patientId, targetId, base;
  final DraftType type;
  final DraftPayload Function() _snapshot;
  final _status = ValueNotifier<DraftStatus>(DraftStatus.waiting);
  ValueListenable<DraftStatus> get status => _status;
  Timer? _timer;
  late String _last;
  late final int _session;
  bool _saved, _finished = false, _disposed = false;

  void changed() {
    if (_finished || _disposed) return;
    _timer?.cancel();
    if (_snapshot().encode() == _last) return;
    _status.value = DraftStatus.saving;
    _timer = Timer(const Duration(milliseconds: 400), () {
      try {
        flush();
      } catch (_) {
        /* Status remains visible in the editor. */
      }
    });
  }

  void flush({bool force = false}) {
    _timer?.cancel();
    if (_finished || _disposed) return;
    try {
      final payload = _snapshot();
      final encoded = payload.encode();
      if (!force && encoded == _last) return;
      _c.drafts.saveNow(
        id: id,
        patientId: patientId,
        targetId: targetId,
        base: base,
        payload: payload,
        session: _session,
        create: !_saved,
      );
      _last = encoded;
      _saved = true;
      _status.value = DraftStatus.saved;
    } catch (_) {
      _status.value = DraftStatus.failed;
      rethrow;
    }
  }

  Future<void> complete() async {
    flush(force: true);
    await _c.drafts.complete(patientId, id, _session);
    _finished = true;
    _timer?.cancel();
  }

  Future<void> discard() async {
    _c.requireSession(_session);
    _timer?.cancel();
    _finished = true;
    try {
      await _c.drafts.delete(patientId, id);
    } catch (_) {
      _finished = false;
      rethrow;
    }
  }

  bool get saved => _saved;
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _c.drafts.unregisterFlusher(flush);
    _status.dispose();
  }
}
