import 'dart:async';

import '../domain/notebook_context.dart';
import '../domain/records.dart';
import 'session_access.dart';

/// Host-owned jobs run outside the notebook's write lock. No model is installed
/// or invoked here, and returned values are never written to confirmed records.
final class ContextTasks {
  ContextTasks(this._scope);
  final SessionAccess _scope;
  final _active = <ContextTask>{};
  ContextTask create(ContextSelection selection) {
    _scope.requirePatient(selection.patientId);
    late final ContextTask task;
    task = ContextTask._(_scope, selection, () => _active.remove(task));
    _active.add(task);
    return task;
  }

  void cancelAll() {
    for (final task in _active.toList()) {
      task.cancel();
    }
  }
}

final class ContextTask {
  ContextTask._(SessionAccess scope, ContextSelection selection, this._finished)
    : _reader = _ScopedReader(scope, selection, scope.capture());
  final _ScopedReader _reader;
  final void Function() _finished;
  bool _started = false;
  bool get cancelled => _reader.cancelled;

  void cancel() {
    _reader.cancel();
    _finished();
  }

  Future<T> run<T>(
    Future<T> Function(NotebookContextReader reader) work,
  ) async {
    if (_started) throw StateError('A context task can run only once.');
    _started = true;
    try {
      _reader.check();
      final result = await Future.any<T>([
        Future<T>.sync(() => work(_reader)),
        _reader.ended.future.then<T>(
          (_) => throw CareError(CareErrorCode.contextCancelled),
        ),
      ]);
      _reader.check();
      return result;
    } finally {
      cancel();
    }
  }
}

final class _ScopedReader implements NotebookContextReader {
  _ScopedReader(this._scope, this._selection, this._epoch);
  final SessionAccess _scope;
  final ContextSelection _selection;
  final int _epoch;
  final ended = Completer<void>();
  @override
  bool get cancelled => ended.isCompleted;
  void cancel() {
    if (!cancelled) ended.complete();
  }

  void check() {
    if (cancelled) throw CareError(CareErrorCode.contextCancelled);
    _scope.check(_epoch);
    _scope.requirePatient(_selection.patientId);
  }

  @override
  NotebookContext read() {
    check();
    final s = _selection, repository = _scope.repository;
    final records = <ContextRecord>[];
    final medications = <ContextMedication>[];
    var characters = 0;
    void count(String text) {
      characters += text.length;
      if (characters > s.maxCharacters) {
        throw CareError(CareErrorCode.contextTooLarge);
      }
    }

    for (final id in s.entryIds) {
      final entry = repository.entry(s.patientId, id);
      if (entry == null) throw CareError(CareErrorCode.scopeMismatch);
      if (s.from != null && entry.occurredAt.isBefore(s.from!) ||
          s.until != null && !entry.occurredAt.isBefore(s.until!)) {
        continue;
      }
      final fields = {
        for (final e in entry.fields.entries)
          if (s.entryFields.contains(e.key)) e.key: e.value,
      };
      for (final value in fields.values) {
        count(value);
      }
      final note = s.includeNotes ? entry.note : null;
      if (note != null) count(note);
      records.add(
        ContextRecord(
          id: entry.id,
          kind: entry.kind,
          at: entry.occurredAt,
          version: entry.version,
          note: note,
          fields: fields,
        ),
      );
    }
    if (s.medicationIds.isNotEmpty) {
      final selected = repository
          .medications(s.patientId)
          .where((m) => s.medicationIds.contains(m.id))
          .toList();
      if (selected.length != s.medicationIds.length) {
        throw CareError(CareErrorCode.scopeMismatch);
      }
      for (final medication in selected) {
        count(medication.name);
        count(medication.instruction);
        for (final time in medication.times) {
          count(time);
        }
        medications.add(
          ContextMedication(
            id: medication.id,
            name: medication.name,
            instruction: medication.instruction,
            version: medication.version,
            times: medication.times,
          ),
        );
      }
    }
    return NotebookContext(records: records, medications: medications);
  }
}
