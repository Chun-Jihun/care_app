import 'dart:typed_data';

import '../../domain/ai.dart';
import '../../domain/records.dart';
import '../../domain/visit_recording.dart';
import '../sqlite_session.dart';

final class SqliteVisitRecordings {
  SqliteVisitRecordings(this._store);

  final SqliteSession _store;

  List<VisitRecording> list(String pid) {
    _store.patient(pid);
    return _store.connection
        .select(
          '''
      SELECT id, started_at, byte_count, kept FROM visit_recording
      WHERE patient_id=? AND byte_count>0 ORDER BY started_at DESC, id DESC
    ''',
          [pid],
        )
        .map(
          (row) => VisitRecording(
            row['id'] as String,
            DateTime.fromMillisecondsSinceEpoch(row['started_at'] as int),
            row['byte_count'] as int,
            row['kept'] == 1,
          ),
        )
        .toList();
  }

  VisitRecording begin(String pid) => _store.transaction(() {
    _store.patient(pid);
    final db = _store.connection;
    db.execute(
      'DELETE FROM visit_recording WHERE patient_id=? AND byte_count=0',
      [pid],
    );
    final id = RecordIds.next(), at = DateTime.now();
    db.execute(
      'INSERT INTO visit_recording(id, patient_id, started_at) VALUES(?,?,?)',
      [id, pid, at.millisecondsSinceEpoch],
    );
    return VisitRecording(id, at, 0, false);
  });

  void append(String pid, String id, Uint8List pcm) {
    if (pcm.isEmpty ||
        pcm.length.isOdd ||
        pcm.length > VisitRecording.bytesPerSecond) {
      throw const AiException(AiFailure.invalidInput);
    }
    _store.transaction(() {
      final db = _store.connection;
      final row = db.select(
        'SELECT byte_count, kept FROM visit_recording WHERE patient_id=? AND id=?',
        [pid, id],
      ).firstOrNull;
      if (row == null) throw CareError(CareErrorCode.scopeMismatch);
      final offset = row['byte_count'] as int;
      if (row['kept'] == 1 || offset + pcm.length > VisitRecording.maxBytes) {
        throw const AiException(AiFailure.invalidInput);
      }
      db.execute('INSERT INTO visit_audio_chunk VALUES(?,?,?,?)', [
        pid,
        id,
        offset,
        pcm,
      ]);
      db.execute(
        'UPDATE visit_recording SET byte_count=? WHERE patient_id=? AND id=?',
        [offset + pcm.length, pid, id],
      );
    });
  }

  Uint8List? read(String pid, String id, int offset) {
    final db = _store.connection;
    final recording = db.select(
      'SELECT byte_count FROM visit_recording WHERE patient_id=? AND id=?',
      [pid, id],
    ).firstOrNull;
    if (recording == null) throw CareError(CareErrorCode.scopeMismatch);
    if (offset == recording['byte_count']) return null;
    final row = db.select(
      'SELECT pcm FROM visit_audio_chunk WHERE patient_id=? AND recording_id=? AND byte_offset=?',
      [pid, id, offset],
    ).firstOrNull;
    if (row == null) throw CareError(CareErrorCode.storageIntegrityFailed);
    return row['pcm'] as Uint8List;
  }

  void keep(String pid, String id) {
    _store.scoped('visit_recording', pid, id);
    _store.connection.execute(
      'UPDATE visit_recording SET kept=1 WHERE patient_id=? AND id=? AND byte_count>0',
      [pid, id],
    );
  }

  void delete(String pid, String id) {
    _store.scoped('visit_recording', pid, id);
    _store.connection.execute(
      'DELETE FROM visit_recording WHERE patient_id=? AND id=?',
      [pid, id],
    );
  }
}
