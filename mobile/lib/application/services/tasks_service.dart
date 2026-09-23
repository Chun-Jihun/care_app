import 'dart:convert';

import '../../domain/records.dart';
import '../session_access.dart';

final class TaskService {
  TaskService(this._scope);
  final SessionAccess _scope;
  final _cache = QueryCache();
  void invalidate() => _cache.clear();
  List<CareTask> tasks(String pid, {bool? done, int? limit}) {
    _scope.requirePatient(pid);
    return _cache.get(
      jsonEncode(['tasks', pid, done, limit]),
      () => List<CareTask>.unmodifiable(
        _scope.repository.tasks(pid, done: done, limit: limit),
      ),
    );
  }

  int count(String pid, {bool? done}) {
    _scope.requirePatient(pid);
    return _cache.get(
      jsonEncode(['taskCount', pid, done]),
      () => _scope.repository.taskCount(pid, done: done),
    );
  }

  Future<CareTask> saveTask(
    String pid, {
    String? id,
    required String title,
    String note = '',
    required DateTime dueAt,
    bool reminder = false,
  }) => _scope.write(
    pid,
    ChangeImpact.tasks,
    (repository) => repository.saveTask(
      pid,
      id: id,
      title: title,
      note: note,
      dueAt: dueAt,
      reminder: reminder,
    ),
  );
  Future<void> completeTask(String pid, String id, bool done) => _scope.write(
    pid,
    ChangeImpact.tasks,
    (repository) => repository.completeTask(pid, id, done),
  );
  Future<void> deleteTask(String pid, String id) => _scope.write(
    pid,
    ChangeImpact.tasks,
    (repository) => repository.deleteTask(pid, id),
  );
}
