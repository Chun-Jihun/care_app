import 'dart:async';

import '../domain/records.dart';
import 'notebook_repository.dart';

enum ChangeImpact {
  all,
  profiles,
  records,
  medications,
  tasks,
  visits,
  drafts,
  chat,
  photos,
  checkins,
}

typedef SessionRun = Future<T> Function<T>(
  Future<T> Function(int epoch) action,
);
typedef SessionExternal = Future<T> Function<T>(Future<T> Function() action);

/// Internal collaborator. Feature APIs never expose this object to their callers.
final class SessionAccess {
  SessionAccess({
    required this._repository,
    required this._patient,
    required this.capture,
    required this.check,
    required this._run,
    required this._external,
    required this._changed,
    required this._newId,
  });
  final NotebookRepository Function() _repository;
  final String? Function() _patient;
  final SessionRun _run;
  final SessionExternal _external;
  final Future<void> Function(ChangeImpact) _changed;
  final String Function() _newId;
  final int Function() capture;
  final void Function(int) check;
  String newId() => _newId();
  String? get patientId => _patient();
  NotebookRepository get repository => _repository();

  void requirePatient(String? pid) {
    capture();
    if (pid != null && pid != _patient()) {
      throw CareError(CareErrorCode.scopeMismatch);
    }
  }

  /// Serializes application operations, not a transaction around arbitrary work.
  /// Repository commands themselves own their short synchronous transactions.
  Future<T> write<T>(
    String? pid,
    ChangeImpact impact,
    T Function(NotebookRepository repository) action,
  ) async {
    requirePatient(pid);
    return _run((epoch) async {
      check(epoch);
      final value = action(repository);
      // All callers here are private application implementations. Public feature
      // commands accept data only; no caller-provided work reaches SQL commits.
      await _changed(impact);
      return value;
    });
  }

  Future<T> run<T>(Future<T> Function(int epoch) action) => _run(action);
  Future<T> external<T>(Future<T> Function() action) => _external(action);
  Future<void> changed(ChangeImpact impact) => _changed(impact);
}

final class QueryCache {
  final _values = <String, Object?>{};
  T get<T>(String key, T Function() load) {
    if (!_values.containsKey(key)) {
      if (_values.length >= 64) _values.remove(_values.keys.first);
      _values[key] = load();
    }
    return _values[key] as T;
  }

  void clear() => _values.clear();
}
