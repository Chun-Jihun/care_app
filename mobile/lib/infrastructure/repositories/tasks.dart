import 'package:sqlite3/sqlite3.dart';

import '../../domain/records.dart';
import '../sqlite_session.dart';

final class SqliteTasks {
  SqliteTasks(this._store);
  final SqliteSession _store;

  List<CareTask> tasks(String pid, {bool? done, int? limit}) {
    _store.patient(pid);
    return _store.connection
        .select(
          'SELECT * FROM care_task WHERE patient_id=?${done == null ? '' : ' AND done=?'} ORDER BY done,due_at,id${limit == null ? '' : ' LIMIT ?'}',
          [
            pid,
            if (done != null) done ? 1 : 0,
            if (limit != null) limit < 0 ? 0 : limit,
          ],
        )
        .map(_read)
        .toList();
  }

  int taskCount(String pid, {bool? done}) {
    _store.patient(pid);
    return _store.connection.select(
          'SELECT count(*) AS total FROM care_task WHERE patient_id=?${done == null ? '' : ' AND done=?'}',
          [pid, if (done != null) done ? 1 : 0],
        ).single['total']
        as int;
  }

  CareTask _read(Row r) => CareTask(
    r['id'] as String,
    r['title'] as String,
    r['note'] as String,
    DateTime.fromMillisecondsSinceEpoch(r['due_at'] as int),
    r['done'] == 1,
    r['reminder'] == 1,
  );

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
    if (title.length > 2000) {
      throw CareError(CareErrorCode.fieldTooLong, labels: ['할 일']);
    }
    if (note.length > 20000) throw CareError(CareErrorCode.noteTooLong);
    if (dueAt.year < 1900 || dueAt.year > 2200) {
      throw CareError(CareErrorCode.invalidEntryTime);
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
    return _read(
      _store.connection.select(
        'SELECT * FROM care_task WHERE patient_id=? AND id=?',
        [pid, taskId],
      ).single,
    );
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
