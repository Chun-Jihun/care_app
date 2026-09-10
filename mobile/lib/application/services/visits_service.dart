import 'dart:convert';

import '../../domain/records.dart';
import '../session_access.dart';

final class VisitService {
  VisitService(this._scope);
  final SessionAccess _scope;
  final _cache = QueryCache();
  void invalidate() => _cache.clear();
  List<VisitPreparation> visits(String pid) {
    _scope.requirePatient(pid);
    return _cache.get(
      jsonEncode(['visits', pid.toString()]),
      () => List<VisitPreparation>.unmodifiable(_scope.repository.visits(pid)),
    );
  }

  List<CareEntry> visitEntries(String pid, String id) {
    _scope.requirePatient(pid);
    return _cache.get(
      jsonEncode(['visitEntries', pid.toString(), id.toString()]),
      () =>
          List<CareEntry>.unmodifiable(_scope.repository.visitEntries(pid, id)),
    );
  }

  Future<VisitPreparation> saveVisit(
    String pid, {
    String? id,
    required String title,
    required String questions,
    required List<String> entryIds,
  }) => _scope.write(
    pid,
    ChangeImpact.visits,
    (repository) => repository.saveVisit(
      pid,
      id: id,
      title: title,
      questions: questions,
      entryIds: entryIds,
    ),
  );
  Future<void> deleteVisit(String pid, String id) => _scope.write(
    pid,
    ChangeImpact.visits,
    (repository) => repository.deleteVisit(pid, id),
  );
}
