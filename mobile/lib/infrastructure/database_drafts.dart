part of 'care_database.dart';

extension DraftStorage on CareDatabase {
  void _upgradeDraftSchema() {
    final backups = <File>[];
    try {
      for (final name in ['care', 'identity']) {
        backups.add(
          File(p.join(directory, '$name.db'))
              .copySync(p.join(directory, '$name.migration-v2.bak')),
        );
      }
      _transaction(() {
        _db.execute('''
          CREATE TABLE record_draft(
            id TEXT PRIMARY KEY, patient_id TEXT, type TEXT NOT NULL
              CHECK(type IN ('entry','medication','intake','task','visit','checkin')),
            target_id TEXT, base TEXT, payload TEXT NOT NULL,
            updated_at INTEGER NOT NULL, expires_at INTEGER,
            CHECK((type='checkin' AND patient_id IS NULL) OR (type!='checkin' AND patient_id IS NOT NULL)),
            FOREIGN KEY(patient_id) REFERENCES patient_context(id) ON DELETE CASCADE);
          CREATE INDEX draft_scope ON record_draft(patient_id,updated_at DESC);
          CREATE TABLE imported_backup(id TEXT PRIMARY KEY, imported_at INTEGER NOT NULL, patient_ids TEXT NOT NULL, checkin_ids TEXT NOT NULL);
          PRAGMA user_version=3;
          PRAGMA identity.user_version=3;
        ''');
      });
      verifyIntegrity();
    } finally {
      for (final file in backups) {
        if (file.existsSync()) file.deleteSync();
      }
    }
  }

  DraftRetention? get draftRetention {
    final code = setting('draft_retention');
    return DraftRetention.values.where((v) => v.code == code).firstOrNull;
  }

  void setDraftRetention(DraftRetention value, {DateTime? now}) {
    pruneDrafts(now: now);
    _transaction(() {
      setSetting('draft_retention', value.code);
      _db.execute(
        value.days == null
            ? 'UPDATE record_draft SET expires_at=NULL'
            : 'UPDATE record_draft SET expires_at=updated_at+?',
        value.days == null ? [] : [Duration(days: value.days!).inMilliseconds],
      );
      pruneDrafts(now: now);
    });
  }

  void pruneDrafts({DateTime? now}) => _db.execute(
    'DELETE FROM record_draft WHERE expires_at IS NOT NULL AND expires_at<=?',
    [(now ?? DateTime.now()).millisecondsSinceEpoch],
  );

  List<CareDraft> drafts(String? pid, {DateTime? now}) {
    if (pid != null) _patient(pid);
    return _db
        .select(
          'SELECT * FROM record_draft WHERE patient_id IS ? AND (expires_at IS NULL OR expires_at>?) ORDER BY updated_at DESC,id',
          [pid, (now ?? DateTime.now()).millisecondsSinceEpoch],
        )
        .map(
          (r) => CareDraft(
            id: r['id'] as String,
            patientId: r['patient_id'] as String?,
            type: DraftType.values.byName(r['type'] as String),
            targetId: r['target_id'] as String?,
            base: r['base'] as String?,
            values: Map<String, dynamic>.from(
              jsonDecode(r['payload'] as String) as Map,
            ),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              r['updated_at'] as int,
            ),
            expiresAt: r['expires_at'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(r['expires_at'] as int),
          ),
        )
        .toList();
  }

  int draftCount(String? pid) {
    if (pid != null) _patient(pid);
    return _db.select(
          'SELECT count(*) AS n FROM record_draft WHERE patient_id IS ? AND (expires_at IS NULL OR expires_at>?)',
          [pid, DateTime.now().millisecondsSinceEpoch],
        ).single['n']
        as int;
  }

  void saveDraft({
    required String id,
    required String? patientId,
    required DraftType type,
    required Map<String, dynamic> values,
    String? targetId,
    String? base,
    bool create = true,
    DateTime? now,
  }) {
    if (patientId != null) _patient(patientId);
    if ((type == DraftType.checkin) != (patientId == null)) {
      throw const CareError('초안의 수첩 연결을 확인해 주세요.');
    }
    final retention = draftRetention;
    if (retention == null) throw const CareError('초안 보관기간을 먼저 선택해 주세요.');
    final payload = jsonEncode(values);
    // A valid symptom record can contain eight 4,000-character Korean fields
    // plus a 20,000-character note. Do not reject those inputs as drafts.
    if (utf8.encode(payload).length > 256 * 1024) {
      throw const CareError('초안 내용이 너무 길어 자동 저장하지 못했습니다. 내용을 줄여 주세요.');
    }
    final old = _db.select('SELECT * FROM record_draft WHERE id=?', [
      id,
    ]).firstOrNull;
    final at = now ?? DateTime.now();
    if ((!create && old == null) ||
        (old != null &&
            old['expires_at'] != null &&
            (old['expires_at'] as int) <= at.millisecondsSinceEpoch)) {
      throw const CareError('초안이 삭제되거나 만료되었습니다. 다시 열어 주세요.');
    }
    if (old != null &&
        (old['patient_id'] != patientId ||
            old['type'] != type.name ||
            old['target_id'] != targetId ||
            old['base'] != base)) {
      throw const CareError('초안의 원본 연결이 일치하지 않습니다.');
    }
    _db.execute(
      '''INSERT INTO record_draft VALUES(?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at,expires_at=excluded.expires_at''',
      [
        id,
        patientId,
        type.name,
        targetId,
        base,
        payload,
        at.millisecondsSinceEpoch,
        retention.days == null
            ? null
            : at.add(Duration(days: retention.days!)).millisecondsSinceEpoch,
      ],
    );
  }

  void deleteDraft(String? pid, String id) {
    if (pid != null) _patient(pid);
    final row = _db.select('SELECT patient_id FROM record_draft WHERE id=?', [
      id,
    ]).firstOrNull;
    if (row != null && row['patient_id'] != pid) {
      throw const CareError('현재 수첩의 초안이 아닙니다.');
    }
    _db.execute('DELETE FROM record_draft WHERE patient_id IS ? AND id=?', [
      pid,
      id,
    ]);
  }

  /// Fingerprint is encrypted with the draft. It includes the original record,
  /// not the user's unfinished edits, so resuming never silently rebases edits.
  String? draftBase(DraftType type, String? pid, String? targetId) {
    if (targetId == null) return null;
    final table = switch (type) {
      DraftType.entry => 'care_entry',
      DraftType.medication || DraftType.intake => 'medication',
      DraftType.task => 'care_task',
      DraftType.visit => 'visit_preparation',
      DraftType.checkin => throw const CareError('내 상태 초안은 새 기록만 지원합니다.'),
    };
    _scoped(table, pid!, targetId);
    final rows = <Object?>[
      Map<String, Object?>.from(
        _db.select('SELECT * FROM $table WHERE patient_id=? AND id=?', [
          pid,
          targetId,
        ]).single,
      ),
    ];
    if (type == DraftType.visit) {
      rows.add(
        _db
            .select(
              'SELECT * FROM visit_source WHERE patient_id=? AND visit_id=? ORDER BY entry_id',
              [pid, targetId],
            )
            .map((r) => Map<String, Object?>.from(r))
            .toList(),
      );
    }
    return jsonEncode(rows);
  }

  T completeDraft<T>(
    String? pid,
    String id,
    T Function() action,
  ) => _transaction(() {
    final draft = drafts(pid).where((d) => d.id == id).firstOrNull;
    if (draft == null) throw const CareError('초안이 삭제되거나 만료되었습니다. 다시 열어 주세요.');
    if (draft.base != draftBase(draft.type, pid, draft.targetId)) {
      throw const CareError('작성 중 원본이나 처방이 바뀌었습니다. 초안을 보관했으니 최신 기록과 비교해 주세요.');
    }
    final result = action();
    deleteDraft(pid, id);
    return result;
  });
}
