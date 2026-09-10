import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../domain/records.dart';
export 'record_tables.dart';

class RecordIds {
  static String next() => const Uuid().v7();
}

/// Infrastructure-only connection and transaction owner, shared by repositories.
final class SqliteSession {
  SqliteSession(this.connection, this.directory);
  final Database connection;
  final String directory;
  int _transactionDepth = 0;
  T transaction<T>(T Function() body) {
    final depth = _transactionDepth++;
    final savepoint = 'care_$depth';
    try {
      connection.execute(
        depth == 0 ? 'BEGIN IMMEDIATE' : 'SAVEPOINT $savepoint',
      );
      final result = body();
      connection.execute(depth == 0 ? 'COMMIT' : 'RELEASE $savepoint');
      return result;
    } catch (_) {
      connection.execute(depth == 0 ? 'ROLLBACK' : 'ROLLBACK TO $savepoint');
      if (depth != 0) connection.execute('RELEASE $savepoint');
      rethrow;
    } finally {
      _transactionDepth--;
    }
  }

  void patient(String id) {
    if (connection.select('SELECT id FROM patient_context WHERE id=?', [
      id,
    ]).isEmpty) {
      throw CareError(CareErrorCode.selectedPatientMissing);
    }
  }

  void scoped(String table, String patientId, String id) {
    patient(patientId);
    if (connection.select('SELECT id FROM $table WHERE patient_id=? AND id=?', [
      patientId,
      id,
    ]).isEmpty) {
      throw CareError(CareErrorCode.scopeMismatch);
    }
  }

  String? setting(String key) =>
      connection.select('SELECT value FROM settings WHERE key=?', [
            key,
          ]).firstOrNull?['value']
          as String?;
  void setSetting(String key, String value) => connection.execute(
    'INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );
}
