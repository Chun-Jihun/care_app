import 'dart:convert';

import '../../domain/records.dart';
import '../../domain/drafts.dart';
import '../../application/notebook_repository.dart';
import '../sqlite_session.dart';

final class SqliteDrafts {
  SqliteDrafts(this._store, this._repository);
  final SqliteSession _store;
  final NotebookRepository _repository;

  DraftRetention? get draftRetention {
    final code = _store.setting('draft_retention');
    return DraftRetention.values.where((v) => v.code == code).firstOrNull;
  }

  void setDraftRetention(DraftRetention value, {DateTime? now}) {
    pruneDrafts(now: now);
    _store.transaction(() {
      _store.setSetting('draft_retention', value.code);
      _store.connection.execute(
        value.days == null
            ? 'UPDATE record_draft SET expires_at=NULL'
            : 'UPDATE record_draft SET expires_at=updated_at+?',
        value.days == null ? [] : [Duration(days: value.days!).inMilliseconds],
      );
      pruneDrafts(now: now);
    });
  }

  void pruneDrafts({DateTime? now}) => _store.connection.execute(
    'DELETE FROM record_draft WHERE expires_at IS NOT NULL AND expires_at<=?',
    [(now ?? DateTime.now()).millisecondsSinceEpoch],
  );

  List<CareDraft> drafts(String? pid, {DateTime? now}) {
    if (pid != null) _store.patient(pid);
    return _store.connection
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
            payload: DraftPayload.decode(
              DraftType.values.byName(r['type'] as String),
              r['payload'] as String,
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
    if (pid != null) _store.patient(pid);
    return _store.connection.select(
          'SELECT count(*) AS n FROM record_draft WHERE patient_id IS ? AND (expires_at IS NULL OR expires_at>?)',
          [pid, DateTime.now().millisecondsSinceEpoch],
        ).single['n']
        as int;
  }

  void saveDraft({
    required String id,
    required String? patientId,
    required DraftType type,
    required DraftPayload payload,
    String? targetId,
    String? base,
    bool create = true,
    DateTime? now,
  }) {
    if (patientId != null) _store.patient(patientId);
    if ((type == DraftType.checkin) != (patientId == null)) {
      throw CareError(CareErrorCode.invalidDraftScope);
    }
    final retention = draftRetention;
    if (retention == null) {
      throw CareError(CareErrorCode.draftRetentionRequired);
    }
    if (payload.type != type || payload is UnreadableDraftPayload) {
      throw CareError(CareErrorCode.draftSourceMismatch);
    }
    final encoded = payload.encode();
    if (utf8.encode(encoded).length > 256 * 1024) {
      throw CareError(CareErrorCode.draftTooLong);
    }
    final old = _store.connection.select(
      'SELECT * FROM record_draft WHERE id=?',
      [id],
    ).firstOrNull;
    final at = now ?? DateTime.now();
    if ((!create && old == null) ||
        (old != null &&
            old['expires_at'] != null &&
            (old['expires_at'] as int) <= at.millisecondsSinceEpoch)) {
      throw CareError(CareErrorCode.draftExpired);
    }
    if (old != null &&
        (old['patient_id'] != patientId ||
            old['type'] != type.name ||
            old['target_id'] != targetId ||
            old['base'] != base)) {
      throw CareError(CareErrorCode.draftSourceMismatch);
    }
    _store.connection.execute(
      '''INSERT INTO record_draft VALUES(?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at,expires_at=excluded.expires_at''',
      [
        id,
        patientId,
        type.name,
        targetId,
        base,
        encoded,
        at.millisecondsSinceEpoch,
        retention.days == null
            ? null
            : at.add(Duration(days: retention.days!)).millisecondsSinceEpoch,
      ],
    );
  }

  void deleteDraft(String? pid, String id) {
    if (pid != null) _store.patient(pid);
    final row = _store.connection.select(
      'SELECT patient_id FROM record_draft WHERE id=?',
      [id],
    ).firstOrNull;
    if (row != null && row['patient_id'] != pid) {
      throw CareError(CareErrorCode.draftScopeMismatch);
    }
    _store.connection.execute(
      'DELETE FROM record_draft WHERE patient_id IS ? AND id=?',
      [pid, id],
    );
  }

  String? draftBase(DraftType type, String? pid, String? targetId) {
    if (targetId == null) return null;
    final table = switch (type) {
      DraftType.entry => 'care_entry',
      DraftType.medication || DraftType.intake => 'medication',
      DraftType.task => 'care_task',
      DraftType.visit => 'visit_preparation',
      DraftType.checkin => throw CareError(CareErrorCode.checkinDraftMustBeNew),
    };
    _store.scoped(table, pid!, targetId);
    final rows = <Object?>[
      Map<String, Object?>.from(
        _store.connection.select(
          'SELECT * FROM $table WHERE patient_id=? AND id=?',
          [pid, targetId],
        ).single,
      ),
    ];
    if (type == DraftType.visit) {
      rows.add(
        _store.connection
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

  void completeDraft(String? pid, String id) => _store.transaction(() {
    final draft = drafts(pid).where((d) => d.id == id).firstOrNull;
    if (draft == null) throw CareError(CareErrorCode.draftExpired);
    if (draft.base != draftBase(draft.type, pid, draft.targetId)) {
      throw CareError(CareErrorCode.draftConflict);
    }
    switch (draft.payload) {
      case EntryDraftPayload value:
        _repository.saveEntry(
          pid!,
          id: draft.targetId,
          expectedVersion: draft.targetId == null
              ? null
              : _repository.entry(pid, draft.targetId!)!.version,
          kind: value.kind,
          occurredAt: value.at ?? draft.updatedAt,
          note: value.note,
          fields: value.fields,
        );
      case MedicationDraftPayload value:
        _repository.saveMedication(
          pid!,
          id: draft.targetId,
          expectedVersion: draft.targetId == null
              ? null
              : _repository
                    .medications(pid, includeArchived: true)
                    .firstWhere((m) => m.id == draft.targetId)
                    .version,
          name: value.name,
          instruction: value.instruction,
          times: value.times
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList(),
        );
      case IntakeDraftPayload value:
        _repository.recordIntake(
          pid!,
          draft.targetId!,
          value.status,
          value.at ?? draft.updatedAt,
          reason: value.reason,
          reaction: value.reaction,
        );
      case TaskDraftPayload value:
        _repository.saveTask(
          pid!,
          id: draft.targetId,
          title: value.title,
          note: value.note,
          dueAt: value.at ?? draft.updatedAt,
          reminder: value.reminder,
        );
      case VisitDraftPayload value:
        _repository.saveVisit(
          pid!,
          id: draft.targetId,
          title: value.title,
          questions: value.questions,
          entryIds: value.selected,
        );
      case CheckinDraftPayload value:
        if ([
          value.fatigue,
          value.sleep,
          value.stress,
          value.note,
        ].every((s) => s.trim().isEmpty)) {
          throw CareError(CareErrorCode.checkinRequired);
        }
        _repository.addCheckin(
          fatigue: value.fatigue,
          sleep: value.sleep,
          stress: value.stress,
          note: value.note,
        );
      case UnreadableDraftPayload():
        throw CareError(CareErrorCode.draftSourceMismatch);
    }
    deleteDraft(pid, id);
  });
}
