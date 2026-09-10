import '../../domain/records.dart';
import '../sqlite_session.dart';

final class SqliteProfiles {
  SqliteProfiles(this._store);
  final SqliteSession _store;

  String? setting(String key) =>
      _store.connection.select('SELECT value FROM settings WHERE key=?', [
            key,
          ]).firstOrNull?['value']
          as String?;

  void setSetting(String key, String value) => _store.connection.execute(
    'INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );

  List<Patient> patients() => _store.connection
      .select(
        'SELECT c.*,i.alias,i.contact FROM patient_context c LEFT JOIN identity.patient_identity i ON i.patient_id=c.id ORDER BY c.created_at,c.id',
      )
      .map(
        (r) => Patient(
          r['id'] as String,
          (r['alias'] ?? '') as String,
          r['role'] as String,
          r['context'] as String,
          (r['contact'] ?? '') as String,
        ),
      )
      .toList();

  Patient createPatient({
    String alias = '',
    String role = 'family',
    String context = '',
    String contact = '',
  }) {
    if (!['self', 'family', 'cohabitant', 'caregiver'].contains(role)) {
      throw CareError(CareErrorCode.invalidAuthorRole);
    }
    final id = RecordIds.next();
    _store.transaction(() {
      _store.connection.execute('INSERT INTO patient_context VALUES(?,?,?,?)', [
        id,
        role,
        context,
        DateTime.now().millisecondsSinceEpoch,
      ]);
      _store.connection.execute(
        'INSERT INTO identity.patient_identity VALUES(?,?,?)',
        [id, alias.trim(), contact.trim()],
      );
    });
    return patients().firstWhere((p) => p.id == id);
  }

  void updatePatient(
    String id, {
    required String alias,
    required String role,
    required String context,
    required String contact,
  }) {
    _store.patient(id);
    if (!['self', 'family', 'cohabitant', 'caregiver'].contains(role)) {
      throw CareError(CareErrorCode.invalidAuthorRole);
    }
    _store.transaction(() {
      _store.connection.execute(
        'UPDATE patient_context SET role=?,context=? WHERE id=?',
        [role, context, id],
      );
      _store.connection.execute(
        'UPDATE identity.patient_identity SET alias=?,contact=? WHERE patient_id=?',
        [alias.trim(), contact.trim(), id],
      );
    });
  }

  void deletePatient(String id) {
    _store.patient(id);
    _store.transaction(() {
      _store.connection.execute(
        'INSERT OR IGNORE INTO pending_file_delete SELECT id FROM attachment WHERE patient_id=?',
        [id],
      );
      _store.connection.execute('DELETE FROM patient_context WHERE id=?', [id]);
      _store.connection.execute(
        'DELETE FROM identity.patient_identity WHERE patient_id=?',
        [id],
      );
      _store.connection.execute(
        "DELETE FROM settings WHERE key='selected_patient' AND value=?",
        [id],
      );
    });
  }

  void addCheckin({
    required String fatigue,
    required String sleep,
    required String stress,
    String note = '',
  }) {
    _store.connection.execute(
      'INSERT INTO caregiver_checkin VALUES(?,?,?,?,?,?)',
      [
        RecordIds.next(),
        DateTime.now().millisecondsSinceEpoch,
        fatigue,
        sleep,
        stress,
        note,
      ],
    );
  }

  List<CaregiverCheckin> checkins() => _store.connection
      .select('SELECT * FROM caregiver_checkin ORDER BY occurred_at DESC')
      .map(
        (r) => CaregiverCheckin(
          id: r['id'] as String,
          occurredAt: DateTime.fromMillisecondsSinceEpoch(
            r['occurred_at'] as int,
          ),
          fatigue: r['fatigue'] as String,
          sleep: r['sleep'] as String,
          stress: r['stress'] as String,
          note: r['note'] as String,
        ),
      )
      .toList();

  void deleteCheckin(String id) => _store.connection.execute(
    'DELETE FROM caregiver_checkin WHERE id=?',
    [id],
  );
}
