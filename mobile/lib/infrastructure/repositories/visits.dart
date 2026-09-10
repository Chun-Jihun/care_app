import '../../domain/records.dart';
import '../sqlite_session.dart';
import 'records.dart';

final class SqliteVisits {
  SqliteVisits(this._store, this._records);
  final SqliteSession _store;
  final SqliteRecords _records;

  List<VisitPreparation> visits(String pid) {
    _store.patient(pid);
    return _store.connection
        .select(
          'SELECT * FROM visit_preparation WHERE patient_id=? ORDER BY created_at DESC',
          [pid],
        )
        .map(
          (r) => VisitPreparation(
            r['id'] as String,
            r['title'] as String,
            r['questions'] as String,
            r['stale'] == 1,
            DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
          ),
        )
        .toList();
  }

  VisitPreparation saveVisit(
    String pid, {
    String? id,
    required String title,
    required String questions,
    required List<String> entryIds,
  }) {
    _store.patient(pid);
    if (title.trim().isEmpty) {
      throw CareError(CareErrorCode.visitTitleRequired);
    }
    final vid = id ?? RecordIds.next();
    _store.transaction(() {
      for (final eid in entryIds) {
        _store.scoped('care_entry', pid, eid);
      }
      if (id != null) {
        _store.scoped('visit_preparation', pid, id);
        _store.connection.execute(
          'UPDATE visit_preparation SET title=?,questions=?,stale=0 WHERE patient_id=? AND id=?',
          [title.trim(), questions.trim(), pid, id],
        );
        _store.connection.execute(
          'DELETE FROM visit_source WHERE patient_id=? AND visit_id=?',
          [pid, id],
        );
      } else {
        _store.connection.execute(
          'INSERT INTO visit_preparation(id,patient_id,title,questions,created_at) VALUES(?,?,?,?,?)',
          [
            vid,
            pid,
            title.trim(),
            questions.trim(),
            DateTime.now().millisecondsSinceEpoch,
          ],
        );
      }
      for (final eid in entryIds.toSet()) {
        _store.connection.execute(
          'INSERT INTO visit_source SELECT patient_id,?,id,version FROM care_entry WHERE patient_id=? AND id=?',
          [vid, pid, eid],
        );
      }
    });
    return visits(pid).firstWhere((v) => v.id == vid);
  }

  List<CareEntry> visitEntries(String pid, String id) {
    _store.scoped('visit_preparation', pid, id);
    return _store.connection
        .select(
          'SELECT e.* FROM care_entry e JOIN visit_source s ON s.patient_id=e.patient_id AND s.entry_id=e.id WHERE s.patient_id=? AND s.visit_id=? ORDER BY e.occurred_at',
          [pid, id],
        )
        .map(_records.readRow)
        .toList();
  }

  void deleteVisit(String pid, String id) {
    _store.scoped('visit_preparation', pid, id);
    _store.connection.execute(
      'DELETE FROM visit_preparation WHERE patient_id=? AND id=?',
      [pid, id],
    );
  }
}
