import 'dart:convert';

import '../../domain/records.dart';
import '../session_access.dart';

final class ProfileService {
  ProfileService(this._scope);
  final SessionAccess _scope;
  final _cache = QueryCache();
  void invalidate() => _cache.clear();
  List<Patient> patients() {
    _scope.requirePatient(null);
    return _cache.get(
      jsonEncode(['patients']),
      () => List<Patient>.unmodifiable(_scope.repository.patients()),
    );
  }

  Future<Patient> createPatient({
    String alias = '',
    String role = 'family',
    String context = '',
    String contact = '',
  }) => _scope.write(
    null,
    ChangeImpact.profiles,
    (repository) => repository.createPatient(
      alias: alias,
      role: role,
      context: context,
      contact: contact,
    ),
  );
  Future<void> updatePatient(
    String id, {
    required String alias,
    required String role,
    required String context,
    required String contact,
  }) => _scope.write(
    null,
    ChangeImpact.profiles,
    (repository) => repository.updatePatient(
      id,
      alias: alias,
      role: role,
      context: context,
      contact: contact,
    ),
  );
  Future<void> deletePatient(String id) => _scope.write(
    null,
    ChangeImpact.profiles,
    (repository) => repository.deletePatient(id),
  );
}
