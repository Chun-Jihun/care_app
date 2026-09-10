import 'dart:convert';

import '../../domain/records.dart';
import '../sqlite_session.dart';
import 'records.dart';

final class SqliteMedications {
  SqliteMedications(this._store, this._records);
  final SqliteSession _store;
  final SqliteRecords _records;

  List<Medication> medications(String pid, {bool includeArchived = false}) {
    _store.patient(pid);
    return _store.connection
        .select(
          "SELECT m.*,p.id AS plan_id,p.instruction,p.times FROM medication m JOIN medication_plan p ON p.patient_id=m.patient_id AND p.medication_id=m.id AND p.status='active' WHERE m.patient_id=? ${includeArchived ? '' : 'AND m.active=1'} ORDER BY m.name",
          [pid],
        )
        .map(
          (r) => Medication(
            r['id'] as String,
            r['name'] as String,
            r['instruction'] as String,
            List<String>.from(jsonDecode(r['times'] as String)),
            r['active'] == 1,
            r['plan_id'] as String,
            r['version'] as int,
          ),
        )
        .toList();
  }

  Medication saveMedication(
    String pid, {
    String? id,
    int? expectedVersion,
    required String name,
    required String instruction,
    required List<String> times,
  }) {
    _store.patient(pid);
    if (name.trim().isEmpty) {
      throw CareError(CareErrorCode.medicationNameRequired);
    }
    final normalized =
        times.map((t) => t.trim()).where((t) => t.isNotEmpty).toSet().toList()
          ..sort();
    if (normalized.any(
      (t) => !RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(t),
    )) {
      throw CareError(CareErrorCode.invalidIntakeTimes);
    }
    final medId = id ?? RecordIds.next();
    _store.transaction(() {
      if (id == null) {
        _store.connection.execute(
          'INSERT INTO medication(id,patient_id,name) VALUES(?,?,?)',
          [medId, pid, name.trim()],
        );
      } else {
        _store.scoped('medication', pid, id);
        final old = medications(
          pid,
          includeArchived: true,
        ).firstWhere((m) => m.id == id);
        if (expectedVersion != null && old.version != expectedVersion) {
          throw CareError(CareErrorCode.medicationConflict);
        }
        _store.connection.execute(
          'UPDATE medication SET name=?,version=version+1 WHERE patient_id=? AND id=?',
          [name.trim(), pid, id],
        );
        _store.connection.execute(
          "UPDATE medication_plan SET status='superseded' WHERE patient_id=? AND medication_id=? AND status='active'",
          [pid, id],
        );
      }
      _store.connection.execute(
        "INSERT INTO medication_plan VALUES(?,?,?,?,?,?,'active',?)",
        [
          RecordIds.next(),
          pid,
          medId,
          name.trim(),
          instruction.trim(),
          jsonEncode(normalized),
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    });
    return medications(
      pid,
      includeArchived: true,
    ).firstWhere((m) => m.id == medId);
  }

  List<MedicationPlan> medicationPlans(String pid, String id) {
    _store.scoped('medication', pid, id);
    return _store.connection
        .select(
          'SELECT * FROM medication_plan WHERE patient_id=? AND medication_id=? ORDER BY created_at DESC,id DESC',
          [pid, id],
        )
        .map(
          (r) => MedicationPlan(
            id: r['id'] as String,
            name: r['name'] as String,
            instruction: r['instruction'] as String,
            times: List<String>.from(jsonDecode(r['times'] as String) as List),
            active: r['status'] == 'active',
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              r['created_at'] as int,
            ),
          ),
        )
        .toList();
  }

  void archiveMedication(String pid, String id, bool archive) {
    _store.scoped('medication', pid, id);
    _store.connection.execute(
      'UPDATE medication SET active=?,version=version+1 WHERE patient_id=? AND id=?',
      [archive ? 0 : 1, pid, id],
    );
  }

  CareEntry recordIntake(
    String pid,
    String medId,
    String status,
    DateTime at, {
    String reason = '',
    String reaction = '',
    DateTime? scheduledAt,
  }) {
    _store.scoped('medication', pid, medId);
    final med = medications(
      pid,
      includeArchived: true,
    ).firstWhere((m) => m.id == medId);
    if (!intakeLabels.containsKey(status)) {
      throw CareError(CareErrorCode.intakeStatusRequired);
    }
    final scheduled = scheduledAt?.toUtc().toIso8601String();
    if (scheduled != null &&
        _store.connection.select(
          'SELECT entry_id FROM medication_intake WHERE patient_id=? AND plan_id=? AND scheduled_at=?',
          [pid, med.planId, scheduled],
        ).isNotEmpty) {
      throw CareError(CareErrorCode.duplicateScheduledIntake);
    }
    return _store.transaction(() {
      final result = _records.writeEntry(
        pid,
        id: RecordIds.next(),
        isNew: true,
        kind: EntryKind.medicationIntake,
        occurredAt: at,
        note: '',
        fields: {
          'medicine': med.name,
          'status': status,
          'reason': reason,
          'reaction': reaction,
          'instruction': med.instruction,
        },
      );
      _store.connection.execute(
        'UPDATE medication_intake SET medication_id=?,plan_id=?,scheduled_at=? WHERE patient_id=? AND entry_id=?',
        [med.id, med.planId, scheduled, pid, result.id],
      );
      return result;
    });
  }
}
