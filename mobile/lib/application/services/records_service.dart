import 'dart:convert';

import '../../domain/records.dart';
import '../session_access.dart';

final class RecordsService {
  RecordsService(this._scope);
  final SessionAccess _scope;
  final _cache = QueryCache();
  void invalidate() => _cache.clear();
  CareEntry? entry(String pid, String id) {
    _scope.requirePatient(pid);
    return _cache.get(
      jsonEncode(['entry', pid.toString(), id.toString()]),
      () => _scope.repository.entry(pid, id),
    );
  }

  List<CareEntry> entries(
    String patientId, {
    EntryKind? kind,
    String query = '',
    DateTime? day,
    int? limit,
    String Function(CareEntry)? displayText,
  }) {
    _scope.requirePatient(patientId);
    return query.isNotEmpty
        ? List<CareEntry>.unmodifiable(
            _scope.repository.entries(
              patientId,
              kind: kind,
              query: query,
              day: day,
              limit: limit,
              displayText: displayText,
            ),
          )
        : _cache.get(
            jsonEncode([
              'entries',
              patientId.toString(),
              kind.toString(),
              query.toString(),
              day == null ? null : '${day.year}-${day.month}-${day.day}',
              limit.toString(),
            ]),
            () => List<CareEntry>.unmodifiable(
              _scope.repository.entries(
                patientId,
                kind: kind,
                query: query,
                day: day,
                limit: limit,
                displayText: displayText,
              ),
            ),
          );
  }

  List<CareEntry> revisions(String pid, String id) {
    _scope.requirePatient(pid);
    return _cache.get(
      jsonEncode(['revisions', pid.toString(), id.toString()]),
      () => List<CareEntry>.unmodifiable(_scope.repository.revisions(pid, id)),
    );
  }

  List<Attachment> attachments(String pid, String eid) {
    _scope.requirePatient(pid);
    return _cache.get(
      jsonEncode(['attachments', pid.toString(), eid.toString()]),
      () => List<Attachment>.unmodifiable(
        _scope.repository.attachments(pid, eid),
      ),
    );
  }

  Future<CareEntry> saveEntry(
    String patientId, {
    String? id,
    int? expectedVersion,
    required EntryKind kind,
    required DateTime occurredAt,
    String note = '',
    Map<String, String> fields = const {},
  }) => _scope.write(
    patientId,
    ChangeImpact.records,
    (repository) => repository.saveEntry(
      patientId,
      id: id,
      expectedVersion: expectedVersion,
      kind: kind,
      occurredAt: occurredAt,
      note: note,
      fields: fields,
    ),
  );
  Future<void> deleteEntry(String pid, String id) => _scope.write(
    pid,
    ChangeImpact.records,
    (repository) => repository.deleteEntry(pid, id),
  );
  Future<void> deleteAttachment(String pid, String id) => _scope.write(
    pid,
    ChangeImpact.photos,
    (repository) => repository.deleteAttachment(pid, id),
  );
}
