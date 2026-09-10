import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../domain/records.dart';
import '../sqlite_session.dart';

final class SqliteRecords {
  SqliteRecords(this._store);
  final SqliteSession _store;

  CareEntry readRow(Row r, {Row? detailRow}) {
    final kind = EntryKind.values.byName(r['kind'] as String);
    final detail =
        detailRow ??
        _store.connection.select(
          'SELECT * FROM ${kind.table} WHERE patient_id=? AND entry_id=?',
          [r['patient_id'], r['id']],
        ).single;
    return CareEntry(
      id: r['id'] as String,
      patientId: r['patient_id'] as String,
      kind: kind,
      occurredAt: DateTime.fromMillisecondsSinceEpoch(
        r['occurred_at'] as int,
        isUtc: true,
      ).toLocal(),
      offsetMinutes: r['offset_minutes'] as int,
      note: r['note'] as String,
      fields: {
        for (final field in detail.keys.where(
          (k) => k != 'patient_id' && k != 'entry_id',
        ))
          field: detail[field]?.toString() ?? '',
      },
      version: r['version'] as int,
    );
  }

  CareEntry? entry(String pid, String id) {
    _store.patient(pid);
    final row = _store.connection.select(
      'SELECT * FROM care_entry WHERE patient_id=? AND id=?',
      [pid, id],
    ).firstOrNull;
    return row == null ? null : readRow(row);
  }

  Iterable<CareEntry> _readEntries(List<Row> rows) sync* {
    for (var start = 0; start < rows.length; start += 200) {
      final batch = rows.skip(start).take(200).toList();
      final details = <String, Row>{};
      for (final kind in batch.map((r) => r['kind'] as String).toSet()) {
        final ids = batch
            .where((r) => r['kind'] == kind)
            .map((r) => r['id'])
            .toList();
        final table = EntryKind.values.byName(kind).table;
        for (final detail in _store.connection.select(
          'SELECT * FROM $table WHERE entry_id IN (${List.filled(ids.length, '?').join(',')}) AND patient_id=?',
          [...ids, batch.first['patient_id']],
        )) {
          details[detail['entry_id'] as String] = detail;
        }
      }
      for (final row in batch) {
        yield readRow(row, detailRow: details[row['id']]);
      }
    }
  }

  List<CareEntry> entries(
    String patientId, {
    EntryKind? kind,
    String query = '',
    DateTime? day,
    int? limit,
    String Function(CareEntry)? displayText,
  }) {
    _store.patient(patientId);
    final args = <Object?>[patientId];
    var where = 'patient_id=?';
    if (kind != null) {
      where += ' AND kind=?';
      args.add(kind.name);
    }
    if (day != null) {
      final start = DateTime(day.year, day.month, day.day);
      where += ' AND occurred_at>=? AND occurred_at<?';
      args.addAll([
        start.millisecondsSinceEpoch,
        DateTime(day.year, day.month, day.day + 1).millisecondsSinceEpoch,
      ]);
    }
    if (limit != null && limit <= 0) return [];
    final term = query.trim().toLowerCase();
    final sqlLimit = limit != null && term.isEmpty ? ' LIMIT ?' : '';
    if (sqlLimit.isNotEmpty) args.add(limit);
    var result =
        _readEntries(
          _store.connection.select(
            'SELECT * FROM care_entry WHERE $where ORDER BY occurred_at DESC,id DESC$sqlLimit',
            args,
          ),
        ).where(
          (e) =>
              term.isEmpty ||
              (displayText?.call(e) ?? e.summary).toLowerCase().contains(term),
        );
    if (limit != null) {
      result = result.take(limit);
    }
    return result.toList();
  }

  CareEntry saveEntry(
    String patientId, {
    String? id,
    int? expectedVersion,
    required EntryKind kind,
    required DateTime occurredAt,
    String note = '',
    Map<String, String> fields = const {},
  }) {
    _store.patient(patientId);
    validateEntry(kind, fields, note);
    if (occurredAt.year < 1900 || occurredAt.year > 2200) {
      throw CareError(CareErrorCode.invalidEntryTime);
    }
    final entryId = id ?? RecordIds.next();
    return _store.transaction(
      () => writeEntry(
        patientId,
        id: entryId,
        isNew: id == null,
        expectedVersion: expectedVersion,
        kind: kind,
        occurredAt: occurredAt,
        note: note.trim(),
        fields: fields,
      ),
    );
  }

  CareEntry writeEntry(
    String patientId, {
    required String id,
    required bool isNew,
    int? expectedVersion,
    required EntryKind kind,
    required DateTime occurredAt,
    required String note,
    required Map<String, String> fields,
  }) {
    if (!isNew) {
      _store.scoped('care_entry', patientId, id);
      final old = readRow(
        _store.connection.select(
          'SELECT * FROM care_entry WHERE patient_id=? AND id=?',
          [patientId, id],
        ).single,
      );
      if (old.version != expectedVersion) {
        throw CareError(CareErrorCode.entryConflict);
      }
      if (old.kind != kind) {
        throw CareError(CareErrorCode.entryKindImmutable);
      }
      _store.connection.execute(
        'INSERT INTO care_entry_revision VALUES(?,?,?,?,?)',
        [
          patientId,
          id,
          old.version,
          jsonEncode(old.toJson()),
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
      _markVisitsStale(patientId, id);
      _store.connection.execute(
        'UPDATE care_entry SET occurred_at=?,offset_minutes=?,note=?,version=version+1 WHERE patient_id=? AND id=?',
        [
          occurredAt.millisecondsSinceEpoch,
          occurredAt.timeZoneOffset.inMinutes,
          note,
          patientId,
          id,
        ],
      );
      final columns = kind.fields.map((f) => f.key).toList();
      if (columns.isNotEmpty) {
        _store.connection.execute(
          'UPDATE ${kind.table} SET ${columns.map((c) => '$c=?').join(',')} WHERE patient_id=? AND entry_id=?',
          [...columns.map((c) => fields[c]?.trim() ?? ''), patientId, id],
        );
      }
    } else {
      _store.connection.execute(
        'INSERT INTO care_entry(id,patient_id,kind,occurred_at,offset_minutes,note,created_at) VALUES(?,?,?,?,?,?,?)',
        [
          id,
          patientId,
          kind.name,
          occurredAt.millisecondsSinceEpoch,
          occurredAt.timeZoneOffset.inMinutes,
          note,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
      final keys = kind.fields.map((f) => f.key).toList();
      _store.connection.execute(
        'INSERT INTO ${kind.table}(patient_id,entry_id${keys.isEmpty ? '' : ',${keys.join(',')}'}) VALUES(${List.filled(2 + keys.length, '?').join(',')})',
        [patientId, id, ...keys.map((k) => fields[k]?.trim() ?? '')],
      );
    }
    return readRow(
      _store.connection.select(
        'SELECT * FROM care_entry WHERE patient_id=? AND id=?',
        [patientId, id],
      ).single,
    );
  }

  void _markVisitsStale(String pid, String eid) => _store.connection.execute(
    'UPDATE visit_preparation SET stale=1 WHERE patient_id=? AND id IN(SELECT visit_id FROM visit_source WHERE patient_id=? AND entry_id=?)',
    [pid, pid, eid],
  );

  List<CareEntry> revisions(String pid, String id) {
    _store.patient(pid);
    return _store.connection
        .select(
          'SELECT snapshot FROM care_entry_revision WHERE patient_id=? AND entry_id=? ORDER BY revision DESC',
          [pid, id],
        )
        .map(
          (r) => CareEntry.fromSnapshot(
            pid,
            jsonDecode(r['snapshot'] as String) as Map<String, dynamic>,
          ),
        )
        .toList();
  }

  void deleteEntry(String pid, String id) {
    _store.scoped('care_entry', pid, id);
    _store.transaction(() {
      _markVisitsStale(pid, id);
      _store.connection.execute(
        'INSERT OR IGNORE INTO pending_file_delete SELECT id FROM attachment WHERE patient_id=? AND entry_id=?',
        [pid, id],
      );
      _store.connection.execute(
        'DELETE FROM care_entry WHERE patient_id=? AND id=?',
        [pid, id],
      );
    });
  }

  List<Attachment> attachments(String pid, String eid) {
    _store.scoped('care_entry', pid, eid);
    return _store.connection
        .select('SELECT * FROM attachment WHERE patient_id=? AND entry_id=?', [
          pid,
          eid,
        ])
        .map(
          (r) => Attachment(
            r['id'] as String,
            eid,
            r['wrapped_key'] as String,
            r['size'] as int,
          ),
        )
        .toList();
  }

  void addAttachment(
    String pid,
    String eid,
    String id,
    String wrappedKey,
    int size,
  ) {
    _store.scoped('care_entry', pid, eid);
    _store.connection.execute('INSERT INTO attachment VALUES(?,?,?,?,?)', [
      id,
      pid,
      eid,
      wrappedKey,
      size,
    ]);
  }

  void deleteAttachment(String pid, String id) {
    _store.scoped('attachment', pid, id);
    _store.transaction(() {
      _store.connection.execute(
        'INSERT OR IGNORE INTO pending_file_delete VALUES(?)',
        [id],
      );
      _store.connection.execute(
        'DELETE FROM attachment WHERE patient_id=? AND id=?',
        [pid, id],
      );
    });
  }

  List<String> get pendingFileDeletes => _store.connection
      .select('SELECT id FROM pending_file_delete')
      .map((r) => r['id'] as String)
      .toList();

  void finishFileDelete(String id) => _store.connection.execute(
    'DELETE FROM pending_file_delete WHERE id=?',
    [id],
  );

  List<String> get allAttachmentIds => _store.connection
      .select('SELECT id FROM attachment')
      .map((r) => r['id'] as String)
      .toList();
}
