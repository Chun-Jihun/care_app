part of 'care_database.dart';

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

extension SelectiveBackupStorage on CareDatabase {
  bool hasImportedBackup(String id) {
    final imported = _db.select('SELECT * FROM imported_backup WHERE id=?', [
      id,
    ]).firstOrNull;
    if (imported == null) return false;
    final pids = Set<String>.from(
      jsonDecode(imported['patient_ids'] as String) as List,
    );
    final checkinIds = Set<String>.from(
      jsonDecode(imported['checkin_ids'] as String) as List,
    );
    return patients().any((p) => pids.contains(p.id)) ||
        checkins().any((r) => checkinIds.contains(r['id']));
  }

  /// Import IDs and links together. Existing records are never updated.
  Map<String, String> importBackupRows(
    BackupRows rows,
    String backupId,
    Map<String, String> ids,
  ) {
    if (hasImportedBackup(backupId)) {
      throw const CareError('이미 복원한 백업입니다. 중복 추가하지 않았습니다.');
    }
    final tables = [..._backupTables, ...EntryKind.values.map((k) => k.table)];
    if (rows.length != tables.length ||
        tables.any((t) => !rows.containsKey(t))) {
      throw const CareError('백업의 기록 종류가 올바르지 않습니다.');
    }
    String mapped(Object? id) {
      if (id is! String || !ids.containsKey(id)) {
        throw const CareError('백업의 원본 연결이 누락되었습니다.');
      }
      return ids[id]!;
    }

    final patients = <String, String>{};
    final headings = {for (final r in rows['care_entry']!) r['id']: r['kind']};
    for (final kind in EntryKind.values) {
      if (rows[kind.table]!.any((r) => headings[r['entry_id']] != kind.name)) {
        throw const CareError('백업의 기록 종류와 상세 내용이 일치하지 않습니다.');
      }
    }
    return _transaction(() {
      // Detail tables precede revision/visit/attachment rows only for clarity;
      // all references are checked again before this transaction commits.
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
        final parts = table.split('.');
        final columnInfo = _db.select(
          'PRAGMA ${parts.length == 2 ? '${parts.first}.' : ''}table_info(${parts.last})',
        );
        final columns = columnInfo.map((r) => r['name'] as String).toList();
        for (final source in rows[table]!) {
          if (source.length != columns.length ||
              columns.any((c) => !source.containsKey(c)) ||
              source.values.any(
                (v) => v != null && v is! String && v is! int,
              )) {
            throw const CareError('백업 항목의 형식이 올바르지 않습니다.');
          }
          final row = Map<String, Object?>.from(source);
          for (final info in columnInfo) {
            final name = info['name'] as String, value = row[name];
            final integer = info['type'] == 'INTEGER';
            if ((value == null && (info['notnull'] == 1 || info['pk'] != 0)) ||
                (value != null &&
                    (integer ? value is! int : value is! String))) {
              throw const CareError('백업 항목의 값 형식이 올바르지 않습니다.');
            }
            if (integer && value is int) {
              if (name.endsWith('_at') &&
                  (value < DateTime(1900).millisecondsSinceEpoch ||
                      value >= DateTime(2201).millisecondsSinceEpoch)) {
                throw const CareError('백업의 기록 시각이 올바르지 않습니다.');
              }
              if (['version', 'revision', 'entry_version'].contains(name) &&
                  value < 1) {
                throw const CareError('백업의 수정 버전이 올바르지 않습니다.');
              }
            }
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
              throw const CareError('수첩 역할 정보가 올바르지 않습니다.');
            }
            patients[source['id'] as String] = row['id'] as String;
          }
          if (table == 'identity.patient_identity') {
            row['alias'] =
                '${(row['alias'] as String).isEmpty ? '복원한 수첩' : row['alias']} (복원)';
          }
          if (table == 'care_entry') {
            if (!EntryKind.values.any((k) => k.name == row['kind'])) {
              throw const CareError('지원하지 않는 간병기록 종류입니다.');
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
              throw const CareError('처방 시각 정보가 올바르지 않습니다.');
            }
          }
          if (table == 'care_entry_revision') {
            final revision = Map<String, dynamic>.from(
              jsonDecode(row['snapshot'] as String) as Map,
            );
            revision['id'] = mapped(revision['id']);
            if (revision['id'] != row['entry_id']) {
              throw const CareError('수정 이력의 원본 연결이 일치하지 않습니다.');
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
          _db.execute(
            'INSERT INTO $table(${columns.join(',')}) VALUES(${List.filled(columns.length, '?').join(',')})',
            columns.map((c) => row[c]).toList(),
          );
        }
      }
      for (final pid in patients.values) {
        for (final entry in entries(pid)) {
          validateEntry(entry.kind, entry.fields, entry.note);
        }
        final meds = _db.select(
          'SELECT id FROM medication WHERE patient_id=?',
          [pid],
        );
        if (medications(pid, includeArchived: true).length != meds.length) {
          throw const CareError('약 목록의 현재 처방 연결이 누락되었습니다.');
        }
        // Imported reminders require review. Keep their original instructions,
        // times and task flags intact while suppressing scheduling per notebook.
        setSetting('imported_muted:$pid', 'true');
      }
      verifyIntegrity();
      _db.execute(
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
      _patient(pid);
    }
    final result = <String, List<Map<String, Object?>>>{};
    List<Map<String, Object?>> select(String sql, List<Object?> args) =>
        _db.select(sql, args).map((r) => Map<String, Object?>.from(r)).toList();
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
    // Work per patient so large archives do not exceed SQLite parameter limits.
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
    return result;
  }
}
