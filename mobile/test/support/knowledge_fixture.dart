import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Only accepts the repository's synthetic test fixture, never user input.
void createKnowledgeFixtureDatabase(File file, Map<String, dynamic> fixture) {
  final db = sqlite3.open(file.path);
  try {
    for (final sql in fixture['schema'] as List) {
      db.execute(sql as String);
    }
    for (final table in (fixture['tables'] as Map).entries) {
      for (final row in table.value as List) {
        final map = row as Map;
        final values = [
          for (final value in map.values)
            value is Map ? base64Decode(value['base64'] as String) : value,
        ];
        db.execute(
          'INSERT INTO ${table.key}(${map.keys.join(',')}) VALUES (${List.filled(values.length, '?').join(',')})',
          values,
        );
      }
    }
    for (final row in fixture['search_rows'] as List) {
      db.execute(
        'INSERT INTO document_search(rowid,text) VALUES (?,?)',
        (row as List).cast<Object?>(),
      );
    }
  } finally {
    db.close();
  }
}
