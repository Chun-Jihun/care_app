import '../../domain/records.dart';
import '../sqlite_session.dart';

final class SqliteTasks {
  SqliteTasks(this._store);
  final SqliteSession _store;

  List<CareTask> tasks(String pid) {
    _store.patient(pid);
    return _store.connection
        .select(
          'SELECT * FROM care_task WHERE patient_id=? ORDER BY done,due_at',
          [pid],
        )
        .map(
          (r) => CareTask(
            r['id'] as String,
            r['title'] as String,
            r['note'] as String,
            DateTime.fromMillisecondsSinceEpoch(r['due_at'] as int),
            r['done'] == 1,
            r['reminder'] == 1,
          ),
        )
        .toList();
  }

  CareTask saveTask(
    String pid, {
    String? id,
    required String title,
    String note = '',
    required DateTime dueAt,
    bool reminder = false,
  }) {
    _store.patient(pid);
    if (title.trim().isEmpty) {
      throw CareError(CareErrorCode.taskTitleRequired);
    }
    final taskId = id ?? RecordIds.next();
    if (id != null) {
      _store.scoped('care_task', pid, id);
      _store.connection.execute(
        'UPDATE care_task SET title=?,note=?,due_at=?,reminder=? WHERE patient_id=? AND id=?',
        [
          title.trim(),
          note.trim(),
          dueAt.millisecondsSinceEpoch,
          reminder ? 1 : 0,
          pid,
          id,
        ],
      );
    } else {
      _store.connection.execute(
        'INSERT INTO care_task(id,patient_id,title,note,due_at,reminder) VALUES(?,?,?,?,?,?)',
        [
          taskId,
          pid,
          title.trim(),
          note.trim(),
          dueAt.millisecondsSinceEpoch,
          reminder ? 1 : 0,
        ],
      );
    }
    return tasks(pid).firstWhere((t) => t.id == taskId);
  }

  void completeTask(String pid, String id, bool done) {
    _store.scoped('care_task', pid, id);
    _store.connection.execute(
      'UPDATE care_task SET done=? WHERE patient_id=? AND id=?',
      [done ? 1 : 0, pid, id],
    );
  }

  void deleteTask(String pid, String id) {
    _store.scoped('care_task', pid, id);
    _store.connection.execute(
      'DELETE FROM care_task WHERE patient_id=? AND id=?',
      [pid, id],
    );
  }
}
