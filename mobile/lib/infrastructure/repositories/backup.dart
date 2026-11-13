import '../backup_document.dart';

import 'dart:convert';

import '../../domain/records.dart';
import '../../domain/backup.dart';
import '../../application/notebook_repository.dart';
import '../sqlite_session.dart';
import '../../domain/ai.dart';

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
        final columns = backupColumnsV2[table]!.keys.toList();
        for (final source in rows[table]!) {
          final row = Map<String, Object?>.from(source);
          if (table == 'chat_message' && row['reply'] != null) {
            final reply = AiReply.decode(row['reply'] as String);
            final references = <AiReference>[];
            for (final ref in reply.sources) {
              final entry = rows['care_entry']!
                  .where((e) => e['id'] == ref.id)
                  .firstOrNull;
              if (entry == null) {
                continue; // Source omitted from selective backup or deleted.
              }
              if (entry['patient_id'] != source['patient_id']) {
                throw CareError(CareErrorCode.recordPatientMismatch);
              }
              references.add(AiReference(mapped(ref.id), ref.version));
            }
            row['reply'] = AiReply(
              reply.kind == AiReplyKind.records && references.isEmpty
                  ? AiReplyKind.unavailable
                  : reply.kind,
              sources: references,
              model: reply.model,
              citations: reply.citations,
              evidenceHold: reply.evidenceHold,
              lookup: reply.kind == AiReplyKind.records && references.isEmpty
                  ? null
                  : reply.lookup,
              hasMore: reply.hasMore && references.length == 8,
            ).encode();
          }
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

  Map<BackupCategory, int> countBackup(BackupSelection selection) {
    final scope = _BackupScope(selection);
    final counts = {
      for (final category in BackupDocument.categoryTables.keys) category: 0,
    };
    int count((String, List<Object?>) query) =>
        _store.connection
                .select('SELECT COUNT(*) AS total ${query.$1}', query.$2)
                .single['total']
            as int;

    for (final pid in scope.patientIds) {
      _store.patient(pid);
      final queries = scope.patientQueries(pid);
      for (final e in BackupDocument.categoryTables.entries) {
        if (queries[e.value] case final query?) {
          counts[e.key] = counts[e.key]! + count(query);
        }
      }
    }
    if (selection.checkins) {
      counts[BackupCategory.checkins] = count(scope.checkins);
    }
    return counts;
  }

  BackupRows selectBackup(BackupSelection selection) {
    final scope = _BackupScope(selection);
    for (final pid in selection.patientIds) {
      _store.patient(pid);
    }
    final result = <String, List<Map<String, Object?>>>{};
    List<Map<String, Object?>> select(String sql, List<Object?> args) => _store
        .connection
        .select(sql, args)
        .map((r) => Map<String, Object?>.from(r))
        .toList();
    List<Map<String, Object?>> rows((String, List<Object?>) query) =>
        select('SELECT d.* ${query.$1}', query.$2);
    for (final table in [
      ..._backupTables,
      ...EntryKind.values.map((k) => k.table),
    ]) {
      result[table] = [];
    }
    for (final pid in scope.patientIds) {
      final identity = select(
        'SELECT * FROM identity.patient_identity WHERE patient_id=?',
        [pid],
      ).single;
      if (!selection.identities) {
        identity['alias'] = '';
        identity['contact'] = '';
      }
      result['identity.patient_identity']!.add(identity);
      final selected = scope
          .patientQueries(pid)
          .map((table, query) => MapEntry(table, rows(query)));
      for (final table in [
        'care_entry_revision',
        ...EntryKind.values.map((k) => k.table),
      ]) {
        result[table]!.addAll(rows(scope.entryChildren(table, pid)));
      }
      if (selection.chats) {
        result['chat_policy']!.addAll(
          select('SELECT * FROM chat_policy WHERE patient_id=?', [pid]),
        );
      }
      final entryIds = selected['care_entry']!.map((r) => r['id']).toSet();
      final sources = select(
        'SELECT s.* FROM visit_source s JOIN visit_preparation v ON s.patient_id=v.patient_id AND s.visit_id=v.id WHERE v.patient_id=?${scope.range('v.created_at')}',
        [pid, ...scope.dates],
      );
      final incomplete = sources
          .where((r) => !entryIds.contains(r['entry_id']))
          .map((r) => r['visit_id'])
          .toSet();
      for (final visit in selected['visit_preparation']!) {
        if (incomplete.contains(visit['id'])) visit['stale'] = 1;
      }
      for (final e in selected.entries) {
        result[e.key]!.addAll(e.value);
      }
      result['visit_source']!.addAll(
        sources.where((r) => entryIds.contains(r['entry_id'])),
      );
    }
    if (selection.checkins) {
      result['caregiver_checkin'] = rows(scope.checkins);
    }
    return BackupDocument.project(result);
  }
}

final class _BackupScope {
  _BackupScope(this.selection);
  final BackupSelection selection;
  final _now = DateTime.now().millisecondsSinceEpoch;
  late final patientIds = selection.patientIds.toList()..sort();
  late final dates = [
    if (selection.from case final from?) from.millisecondsSinceEpoch,
    if (selection.until case final until?) until.millisecondsSinceEpoch,
  ];

  String range(String column) =>
      '${selection.from != null ? ' AND $column>=?' : ''}${selection.until != null ? ' AND $column<?' : ''}';

  Map<String, (String, List<Object?>)> patientQueries(String pid) {
    final period = [pid, ...dates];
    return {
      'patient_context': ('FROM patient_context d WHERE d.id=?', [pid]),
      'medication': ('FROM medication d WHERE d.patient_id=?', [pid]),
      'medication_plan': ('FROM medication_plan d WHERE d.patient_id=?', [pid]),
      'care_entry': (
        'FROM care_entry d WHERE d.patient_id=?${range('d.occurred_at')}',
        period,
      ),
      'care_task': (
        'FROM care_task d WHERE d.patient_id=?${range('d.due_at')}',
        period,
      ),
      'visit_preparation': (
        'FROM visit_preparation d WHERE d.patient_id=?${range('d.created_at')}',
        period,
      ),
      if (selection.photos) 'attachment': entryChildren('attachment', pid),
      if (selection.chats)
        'chat_message': (
          'FROM chat_message d WHERE d.patient_id=?${range('d.created_at')} AND (d.expires_at IS NULL OR d.expires_at>?)',
          [...period, _now],
        ),
    };
  }

  (String, List<Object?>) entryChildren(String table, String pid) => (
    'FROM $table d JOIN care_entry e ON d.patient_id=e.patient_id AND d.entry_id=e.id WHERE e.patient_id=?${range('e.occurred_at')}',
    [pid, ...dates],
  );

  (String, List<Object?>) get checkins =>
      ('FROM caregiver_checkin d WHERE 1=1${range('d.occurred_at')}', dates);
}
