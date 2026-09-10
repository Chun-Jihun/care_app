import 'dart:convert';

import '../../domain/records.dart';
import '../session_access.dart';

final class MedicationService {
  MedicationService(this._scope);
  final SessionAccess _scope;
  final _cache = QueryCache();
  void invalidate() => _cache.clear();
  List<Medication> medications(String pid, {bool includeArchived = false}) {
    _scope.requirePatient(pid);
    return _cache.get(
      jsonEncode(['medications', pid.toString(), includeArchived.toString()]),
      () => List<Medication>.unmodifiable(
        _scope.repository.medications(pid, includeArchived: includeArchived),
      ),
    );
  }

  List<MedicationPlan> medicationPlans(String pid, String id) {
    _scope.requirePatient(pid);
    return _cache.get(
      jsonEncode(['medicationPlans', pid.toString(), id.toString()]),
      () => List<MedicationPlan>.unmodifiable(
        _scope.repository.medicationPlans(pid, id),
      ),
    );
  }

  Future<Medication> saveMedication(
    String pid, {
    String? id,
    int? expectedVersion,
    required String name,
    required String instruction,
    required List<String> times,
  }) => _scope.write(
    pid,
    ChangeImpact.medications,
    (repository) => repository.saveMedication(
      pid,
      id: id,
      expectedVersion: expectedVersion,
      name: name,
      instruction: instruction,
      times: times,
    ),
  );
  Future<void> archiveMedication(String pid, String id, bool archive) =>
      _scope.write(
        pid,
        ChangeImpact.medications,
        (repository) => repository.archiveMedication(pid, id, archive),
      );
  Future<CareEntry> recordIntake(
    String pid,
    String medId,
    String status,
    DateTime at, {
    String reason = '',
    String reaction = '',
    DateTime? scheduledAt,
  }) => _scope.write(
    pid,
    ChangeImpact.records,
    (repository) => repository.recordIntake(
      pid,
      medId,
      status,
      at,
      reason: reason,
      reaction: reaction,
      scheduledAt: scheduledAt,
    ),
  );
}
