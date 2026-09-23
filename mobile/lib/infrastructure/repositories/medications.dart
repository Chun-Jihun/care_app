import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../domain/records.dart';
import '../../domain/drug_safety.dart';
import '../sqlite_session.dart';
import 'records.dart';

final class SqliteMedications {
  SqliteMedications(this._store, this._records);
  final SqliteSession _store;
  final SqliteRecords _records;

  List<Medication> medications(String pid, {bool includeArchived = false}) {
    _store.patient(pid);
    return _select(pid, includeArchived: includeArchived).map(_read).toList();
  }

  List<Row> _select(
    String pid, {
    bool includeArchived = true,
    String? id,
  }) => _store.connection.select(
    "SELECT m.*,p.id AS plan_id,p.instruction,p.times,c.item_code,c.product_name,c.release_id,c.confirmed_at FROM medication m JOIN medication_plan p ON p.patient_id=m.patient_id AND p.medication_id=m.id AND p.status='active' LEFT JOIN medication_product c ON c.patient_id=m.patient_id AND c.medication_id=m.id AND c.medication_version=m.version WHERE m.patient_id=? ${includeArchived ? '' : 'AND m.active=1'} ${id == null ? '' : 'AND m.id=?'} ORDER BY m.name,m.id",
    [pid, ?id],
  );

  Medication _read(Row r) => Medication(
    r['id'] as String,
    r['name'] as String,
    r['instruction'] as String,
    List<String>.from(jsonDecode(r['times'] as String)),
    r['active'] == 1,
    r['plan_id'] as String,
    r['version'] as int,
    product: r['item_code'] == null
        ? null
        : MedicationProduct(
            r['item_code'] as String,
            r['product_name'] as String,
            r['release_id'] as String,
            DateTime.fromMillisecondsSinceEpoch(r['confirmed_at'] as int),
          ),
  );

  Medication _medication(String pid, String id) {
    final row = _select(pid, id: id).firstOrNull;
    if (row == null) throw CareError(CareErrorCode.scopeMismatch);
    return _read(row);
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
    validateEntry(EntryKind.medicationIntake, {
      'medicine': name,
      'instruction': instruction,
      'status': 'unknown',
    }, '');
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
        final old = _medication(pid, id);
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
    return _medication(pid, medId);
  }

  void confirmProduct(
    String pid,
    String id,
    int version,
    MedicationProduct? product,
  ) {
    _store.scoped('medication', pid, id);
    final med = _medication(pid, id);
    if (!med.active || med.version != version) {
      throw CareError(CareErrorCode.medicationConflict);
    }
    if (product != null &&
        (!RegExp(r'^\d{9}$').hasMatch(product.code) ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(product.releaseId) ||
            product.name.isEmpty ||
            product.name.length > 1000)) {
      throw const FormatException('Invalid product confirmation');
    }
    _store.transaction(() {
      _store.connection.execute(
        'DELETE FROM medication_product WHERE patient_id=? AND medication_id=?',
        [pid, id],
      );
      if (product != null) {
        _store.connection.execute(
          'INSERT INTO medication_product VALUES(?,?,?,?,?,?,?)',
          [
            pid,
            id,
            version,
            product.code,
            product.name,
            product.releaseId,
            product.confirmedAt.millisecondsSinceEpoch,
          ],
        );
      }
    });
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

  List<CareEntry> medicationIntakes(String pid, String medId, DateTime day) {
    _store.scoped('medication', pid, medId);
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(day.year, day.month, day.day + 1);
    return _records
        .readEntries(
          _store.connection.select(
            'SELECT e.* FROM care_entry e JOIN medication_intake i ON i.entry_id=e.id AND i.patient_id=e.patient_id WHERE e.patient_id=? AND e.kind=? AND i.medication_id=? AND e.occurred_at>=? AND e.occurred_at<? ORDER BY e.occurred_at DESC,e.id DESC',
            [
              pid,
              EntryKind.medicationIntake.name,
              medId,
              start.millisecondsSinceEpoch,
              end.millisecondsSinceEpoch,
            ],
          ),
        )
        .toList();
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
    final med = _medication(pid, medId);
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
      return _records.entry(pid, result.id)!;
    });
  }
}
