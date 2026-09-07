import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../domain/drafts.dart';
import '../domain/records.dart';
import '../infrastructure/care_database.dart';
import 'care_controller.dart';

/// One editor owns one session. Timers never outlive its private route.
class DraftSession {
  DraftSession(
    this.c, {
    required this.patientId,
    required this.type,
    required this.snapshot,
    this.targetId,
    CareDraft? restored,
  }) : id = restored?.id ?? CareDatabase.newId(),
       base = restored?.base ?? c.db.draftBase(type, patientId, targetId),
       _saved = restored != null {
    _session = c.captureSession();
    if (restored != null &&
        (restored.patientId != patientId ||
            restored.type != type ||
            restored.targetId != targetId)) {
      throw const CareError('현재 작성 화면의 초안이 아닙니다.');
    }
    _last = jsonEncode(snapshot());
    status.value = _saved
        ? '암호화 초안을 불러왔어요. 확인 후 저장해 주세요.'
        : '입력하면 기기에 암호화 초안으로 보관해요.';
    c.addDraftFlusher(flush);
  }
  final CareController c;
  final String id;
  final String? patientId, targetId, base;
  final DraftType type;
  final Map<String, dynamic> Function() snapshot;
  final status = ValueNotifier<String>('');
  Timer? _timer;
  late String _last;
  late final int _session;
  bool _saved, _finished = false, _disposed = false;

  void changed() {
    if (_finished || _disposed) return;
    _timer?.cancel();
    if (jsonEncode(snapshot()) == _last) return;
    status.value = '초안을 저장하고 있어요…';
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
      final values = snapshot();
      final encoded = jsonEncode(values);
      if (!force && encoded == _last) return;
      c.saveDraftNow(
        id: id,
        patientId: patientId,
        type: type,
        targetId: targetId,
        base: base,
        values: values,
        session: _session,
        create: !_saved,
      );
      _last = encoded;
      _saved = true;
      status.value = '기기에 암호화 초안으로 보관했어요. 기록 확정은 저장을 눌러 주세요.';
    } catch (_) {
      status.value =
          '초안 저장에 실패했어요. 저장 공간을 확인해 주세요. 이전 자동 저장 이후 입력은 복구되지 않을 수 있어요.';
      rethrow;
    }
  }

  Future<T> complete<T>(T Function() action) async {
    flush(force: true);
    return c.mutate(() {
      final result = c.db.completeDraft(patientId, id, action);
      _finished = true;
      _timer?.cancel();
      return result;
    });
  }

  Future<void> discard() async {
    c.requireSession(_session);
    _timer?.cancel();
    c.db.deleteDraft(patientId, id);
    _finished = true;
  }

  bool get saved => _saved;
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    c.removeDraftFlusher(flush);
    status.dispose();
  }
}
