import '../backup_document.dart';

import 'dart:convert';

import '../../domain/records.dart';
import '../../domain/backup.dart';
import '../../application/notebook_repository.dart';
import '../sqlite_session.dart';

/// The allowlist is also the insertion order for a self-contained snapshot.
const _backupTables = [
  'patient_context',
  'identity.patient_identity',
  'medication',
  'medication_plan',
  'care_entry',
  'care_entry_revision',
  'care_task',
  'visit_preparation',
  'visit_source',
  'attachment',
  'chat_policy',
  'chat_message',
  'caregiver_checkin',
];

final class SqliteBackup {
  SqliteBackup(this._store, this._repository, this._verify);
  final SqliteSession _store;
  final NotebookRepository _repository;
  final void Function() _verify;

  bool hasImportedBackup(String id) {
    final imported = _store.connection.select(
      'SELECT * FROM imported_backup WHERE id=?',
      [id],
    ).firstOrNull;
    if (imported == null) return false;
    final pids = Set<String>.from(
      jsonDecode(imported['patient_ids'] as String) as List,
    );
    final checkinIds = Set<String>.from(
      jsonDecode(imported['checkin_ids'] as String) as List,
    );
    return _repository.patients().any((p) => pids.contains(p.id)) ||
        _repository.checkins().any((r) => checkinIds.contains(r.id));
  }

  Map<String, String> importBackupRows(
    BackupRows rows,
    String backupId,
    Map<String, String> ids,
  ) {
    if (hasImportedBackup(backupId)) {
      throw CareError(CareErrorCode.duplicateBackup);
    }
    BackupDocument.validate(rows);
    String mapped(Object? id) {
      if (id is! String || !ids.containsKey(id)) {
        throw CareError(CareErrorCode.backupSourceMissing);
      }
      return ids[id]!;
    }

    final patients = <String, String>{};
    final headings = {for (final r in rows['care_entry']!) r['id']: r['kind']};
    for (final kind in EntryKind.values) {
      if (rows[kind.table]!.any((r) => headings[r['entry_id']] != kind.name)) {
        throw CareError(CareErrorCode.backupKindMismatch);
      }
    }
    return _store.transaction(() {
      final order = [
        'patient_context',
        'identity.patient_identity',
        'medication',
        'medication_plan',
        'care_entry',
        ...EntryKind.values.map((k) => k.table),
        ..._backupTables.where(
          (t) => ![
            'patient_context',
            'identity.patient_identity',
            'medication',
            'medication_plan',
            'care_entry',
          ].contains(t),
        ),
      ];
      for (final table in order) {
        final columns = backupColumnsV1[table]!.keys.toList();
        for (final source in rows[table]!) {
          final row = Map<String, Object?>.from(source);
          for (final key in [
            'id',
            'patient_id',
            'entry_id',
            'medication_id',
            'plan_id',
            'visit_id',
          ]) {
            if (row[key] != null) row[key] = mapped(row[key]);
          }
          if (table == 'patient_context') {
            if (![
              'self',
              'family',
              'cohabitant',
              'caregiver',
            ].contains(row['role'])) {
              throw CareError(CareErrorCode.invalidBackupRole);
            }
            patients[source['id'] as String] = row['id'] as String;
          }
          if (table == 'identity.patient_identity') {
            row['alias'] =
                '${(row['alias'] as String).isEmpty ? '복원한 수첩' : row['alias']} (복원)';
          }
          if (table == 'care_entry') {
            if (!EntryKind.values.any((k) => k.name == row['kind'])) {
              throw CareError(CareErrorCode.unsupportedEntryKind);
            }
          }
          if (table == 'medication_plan') {
            final times = jsonDecode(row['times'] as String);
            if (times is! List ||
                times.any(
                  (t) =>
                      t is! String ||
                      !RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(t),
                )) {
              throw CareError(CareErrorCode.invalidPlanTimes);
            }
          }
          if (table == 'care_entry_revision') {
            final revision = Map<String, dynamic>.from(
              jsonDecode(row['snapshot'] as String) as Map,
            );
            revision['id'] = mapped(revision['id']);
            if (revision['id'] != row['entry_id']) {
              throw CareError(CareErrorCode.revisionSourceMismatch);
            }
            final fields = Map<String, dynamic>.from(revision['fields'] as Map);
            for (final key in ['medication_id', 'plan_id']) {
              if (fields[key] != null && fields[key] != '') {
                fields[key] = mapped(fields[key]);
              }
            }
            revision['fields'] = fields;
            row['snapshot'] = jsonEncode(revision);
          }
          _store.connection.execute(
            'INSERT INTO $table(${columns.join(',')}) VALUES(${List.filled(columns.length, '?').join(',')})',
            columns.map((c) => row[c]).toList(),
          );
        }
      }
      for (final pid in patients.values) {
        for (final entry in _repository.entries(pid)) {
          validateEntry(entry.kind, entry.fields, entry.note);
        }
        final meds = _store.connection.select(
          'SELECT id FROM medication WHERE patient_id=?',
          [pid],
        );
        if (_repository.medications(pid, includeArchived: true).length !=
            meds.length) {
          throw CareError(CareErrorCode.currentPlanMissing);
        }
        _repository.setSetting('imported_muted:$pid', 'true');
      }
      _verify();
      _store.connection.execute(
        'INSERT INTO imported_backup VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET imported_at=excluded.imported_at,patient_ids=excluded.patient_ids,checkin_ids=excluded.checkin_ids',
        [
          backupId,
          DateTime.now().millisecondsSinceEpoch,
          jsonEncode(patients.values.toList()),
          jsonEncode(
            rows['caregiver_checkin']!.map((r) => mapped(r['id'])).toList(),
          ),
        ],
      );
      return patients;
    });
  }

  BackupRows selectBackup(BackupSelection selection) {
    for (final pid in selection.patientIds) {
      _store.patient(pid);
    }
    final result = <String, List<Map<String, Object?>>>{};
    List<Map<String, Object?>> select(String sql, List<Object?> args) => _store
        .connection
        .select(sql, args)
        .map((r) => Map<String, Object?>.from(r))
        .toList();
    final dates = <Object?>[
      if (selection.from != null) selection.from!.millisecondsSinceEpoch,
      if (selection.until != null) selection.until!.millisecondsSinceEpoch,
    ];
    String range(String column) =>
        '${selection.from != null ? ' AND $column>=?' : ''}${selection.until != null ? ' AND $column<?' : ''}';
    final pids = selection.patientIds.toList()..sort();
    for (final table in [
      ..._backupTables,
      ...EntryKind.values.map((k) => k.table),
    ]) {
      result[table] = [];
    }
    for (final pid in pids) {
      result['patient_context']!.addAll(
        select('SELECT * FROM patient_context WHERE id=?', [pid]),
      );
      final identity = select(
        'SELECT * FROM identity.patient_identity WHERE patient_id=?',
        [pid],
      ).single;
      if (!selection.identities) {
        identity['alias'] = '';
        identity['contact'] = '';
      }
      result['identity.patient_identity']!.add(identity);
      for (final table in ['medication', 'medication_plan']) {
        result[table]!.addAll(
          select('SELECT * FROM $table WHERE patient_id=?', [pid]),
        );
      }
      final entries = select(
        'SELECT * FROM care_entry WHERE patient_id=?${range('occurred_at')}',
        [pid, ...dates],
      );
      result['care_entry']!.addAll(entries);
      final entryIds = entries.map((r) => r['id']).toSet();
      for (final table in [
        'care_entry_revision',
        ...EntryKind.values.map((k) => k.table),
        if (selection.photos) 'attachment',
      ]) {
        result[table]!.addAll(
          select(
            'SELECT d.* FROM $table d JOIN care_entry e ON d.patient_id=e.patient_id AND d.entry_id=e.id WHERE e.patient_id=?${range('e.occurred_at')}',
            [pid, ...dates],
          ),
        );
      }
      result['care_task']!.addAll(
        select('SELECT * FROM care_task WHERE patient_id=?${range('due_at')}', [
          pid,
          ...dates,
        ]),
      );
      final visits = select(
        'SELECT * FROM visit_preparation WHERE patient_id=?${range('created_at')}',
        [pid, ...dates],
      );
      final sources = select(
        'SELECT s.* FROM visit_source s JOIN visit_preparation v ON s.patient_id=v.patient_id AND s.visit_id=v.id WHERE v.patient_id=?${range('v.created_at')}',
        [pid, ...dates],
      );
      final incomplete = sources
          .where((r) => !entryIds.contains(r['entry_id']))
          .map((r) => r['visit_id'])
          .toSet();
      for (final visit in visits) {
        if (incomplete.contains(visit['id'])) visit['stale'] = 1;
      }
      result['visit_preparation']!.addAll(visits);
      result['visit_source']!.addAll(
        sources.where((r) => entryIds.contains(r['entry_id'])),
      );
      if (selection.chats) {
        result['chat_policy']!.addAll(
          select('SELECT * FROM chat_policy WHERE patient_id=?', [pid]),
        );
        result['chat_message']!.addAll(
          select(
            'SELECT * FROM chat_message WHERE patient_id=?${range('created_at')} AND (expires_at IS NULL OR expires_at>?)',
            [pid, ...dates, DateTime.now().millisecondsSinceEpoch],
          ),
        );
      }
    }
    if (selection.checkins) {
      result['caregiver_checkin']!.addAll(
        select(
          'SELECT * FROM caregiver_checkin WHERE 1=1${range('occurred_at')}',
          dates,
        ),
      );
    }
    return BackupDocument.project(result);
  }
}
