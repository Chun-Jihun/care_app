import 'dart:convert';

import '../../domain/records.dart';
import '../session_access.dart';

final class CheckinService {
  CheckinService(this._scope);
  final SessionAccess _scope;
  final _cache = QueryCache();
  void invalidate() => _cache.clear();
  List<CaregiverCheckin> checkins() {
    _scope.requirePatient(null);
    return _cache.get(
      jsonEncode(['checkins']),
      () => List<CaregiverCheckin>.unmodifiable(_scope.repository.checkins()),
    );
  }

  Future<void> addCheckin({
    required String fatigue,
    required String sleep,
    required String stress,
    String note = '',
  }) => _scope.write(
    null,
    ChangeImpact.checkins,
    (repository) => repository.addCheckin(
      fatigue: fatigue,
      sleep: sleep,
      stress: stress,
      note: note,
    ),
  );
  Future<void> deleteCheckin(String id) => _scope.write(
    null,
    ChangeImpact.checkins,
    (repository) => repository.deleteCheckin(id),
  );
}
