import '../domain/backup.dart';
import '../domain/records.dart';

typedef BackupRows = Map<String, List<Map<String, Object?>>>;

/// Frozen document v1 contract (also the adapter target for format 2/schema 3).
/// Never derive these fields from the live database. Storage migrations map
/// between this contract and SQL; document changes require a new codec version.
class BackupColumn {
  const BackupColumn({this.integer = false, this.required = true});
  final bool integer, required;
}

final class BackupDocument {
  static const format = 3;
  static const version = 1;

  static BackupRows decode(Map<String, dynamic> archive) {
    final supported =
        archive['format'] == format && archive['document_version'] == version ||
        archive['format'] == 2 && archive['schema'] == 3;
    if (!supported || archive['rows'] is! Map) {
      throw CareError(CareErrorCode.unsupportedBackupVersion);
    }
    final rows = Map<String, dynamic>.from(archive['rows'] as Map).map(
      (name, value) => MapEntry(
        name,
        (value as List)
            .map((r) => Map<String, Object?>.from(r as Map))
            .toList(),
      ),
    );
    validate(rows);
    return rows;
  }

  static void validate(BackupRows rows) {
    if (rows.length != backupColumnsV1.length ||
        backupColumnsV1.keys.any((t) => !rows.containsKey(t))) {
      throw CareError(CareErrorCode.invalidBackupTables);
    }
    for (final table in rows.entries) {
      final columns = backupColumnsV1[table.key]!;
      for (final row in table.value) {
        if (row.length != columns.length ||
            columns.keys.any((c) => !row.containsKey(c))) {
          throw CareError(CareErrorCode.invalidBackupFields);
        }
        for (final column in columns.entries) {
          final value = row[column.key], definition = column.value;
          if (value == null
              ? definition.required
              : definition.integer
              ? value is! int
              : value is! String) {
            throw CareError(CareErrorCode.invalidBackupValue);
          }
          if (value is int) {
            if (column.key.endsWith('_at') &&
                (value < DateTime(1900).millisecondsSinceEpoch ||
                    value >= DateTime(2201).millisecondsSinceEpoch)) {
              throw CareError(CareErrorCode.invalidBackupTimestamp);
            }
            if (['version', 'revision', 'entry_version'].contains(column.key) &&
                value < 1) {
              throw CareError(CareErrorCode.invalidBackupRevision);
            }
          }
        }
      }
    }
  }

  // Explicit projection prevents new SQL-only fields entering old documents.
  static BackupRows project(BackupRows rows) => {
    for (final table in backupColumnsV1.entries)
      table.key: [
        for (final row in rows[table.key]!)
          {for (final key in table.value.keys) key: row[key]},
      ],
  };

  static Map<BackupCategory, int> counts(BackupRows rows) => {
    for (final e in const {
      BackupCategory.notebooks: 'patient_context',
      BackupCategory.records: 'care_entry',
      BackupCategory.medications: 'medication',
      BackupCategory.tasks: 'care_task',
      BackupCategory.visits: 'visit_preparation',
      BackupCategory.photos: 'attachment',
      BackupCategory.chats: 'chat_message',
      BackupCategory.checkins: 'caregiver_checkin',
    }.entries)
      e.key: rows[e.value]?.length ?? 0,
  };
}

const backupColumnsV1 = <String, Map<String, BackupColumn>>{
  'patient_context': {
    'id': BackupColumn(),
    'role': BackupColumn(),
    'context': BackupColumn(),
    'created_at': BackupColumn(integer: true),
  },
  'identity.patient_identity': {
    'patient_id': BackupColumn(),
    'alias': BackupColumn(),
    'contact': BackupColumn(),
  },
  'medication': {
    'id': BackupColumn(),
    'patient_id': BackupColumn(),
    'name': BackupColumn(),
    'active': BackupColumn(integer: true),
    'version': BackupColumn(integer: true),
  },
  'medication_plan': {
    'id': BackupColumn(),
    'patient_id': BackupColumn(),
    'medication_id': BackupColumn(),
    'name': BackupColumn(),
    'instruction': BackupColumn(),
    'times': BackupColumn(),
    'status': BackupColumn(),
    'created_at': BackupColumn(integer: true),
  },
  'care_entry': {
    'id': BackupColumn(),
    'patient_id': BackupColumn(),
    'kind': BackupColumn(),
    'occurred_at': BackupColumn(integer: true),
    'offset_minutes': BackupColumn(integer: true),
    'note': BackupColumn(),
    'version': BackupColumn(integer: true),
    'source_type': BackupColumn(),
    'confirmation_status': BackupColumn(),
    'created_at': BackupColumn(integer: true),
  },
  'care_entry_revision': {
    'patient_id': BackupColumn(),
    'entry_id': BackupColumn(),
    'revision': BackupColumn(integer: true),
    'snapshot': BackupColumn(),
    'changed_at': BackupColumn(integer: true),
  },
  'care_task': {
    'id': BackupColumn(),
    'patient_id': BackupColumn(),
    'title': BackupColumn(),
    'note': BackupColumn(),
    'due_at': BackupColumn(integer: true),
    'done': BackupColumn(integer: true),
    'reminder': BackupColumn(integer: true),
  },
  'visit_preparation': {
    'id': BackupColumn(),
    'patient_id': BackupColumn(),
    'title': BackupColumn(),
    'questions': BackupColumn(),
    'stale': BackupColumn(integer: true),
    'created_at': BackupColumn(integer: true),
  },
  'visit_source': {
    'patient_id': BackupColumn(),
    'visit_id': BackupColumn(),
    'entry_id': BackupColumn(),
    'entry_version': BackupColumn(integer: true),
  },
  'attachment': {
    'id': BackupColumn(),
    'patient_id': BackupColumn(),
    'entry_id': BackupColumn(),
    'wrapped_key': BackupColumn(),
    'size': BackupColumn(integer: true),
  },
  'chat_policy': {'patient_id': BackupColumn(), 'retention': BackupColumn()},
  'chat_message': {
    'id': BackupColumn(),
    'patient_id': BackupColumn(),
    'text': BackupColumn(),
    'created_at': BackupColumn(integer: true),
    'expires_at': BackupColumn(integer: true, required: false),
  },
  'caregiver_checkin': {
    'id': BackupColumn(),
    'occurred_at': BackupColumn(integer: true),
    'fatigue': BackupColumn(),
    'sleep': BackupColumn(),
    'stress': BackupColumn(),
    'note': BackupColumn(),
  },
  'meal_entry': {
    'patient_id': BackupColumn(),
    'entry_id': BackupColumn(),
    'food': BackupColumn(),
    'amount': BackupColumn(),
    'water_ml': BackupColumn(),
    'appetite': BackupColumn(),
    'swallowing': BackupColumn(),
    'after': BackupColumn(),
  },
  'medication_intake': {
    'patient_id': BackupColumn(),
    'entry_id': BackupColumn(),
    'medicine': BackupColumn(),
    'status': BackupColumn(),
    'reason': BackupColumn(),
    'reaction': BackupColumn(),
    'instruction': BackupColumn(),
    'medication_id': BackupColumn(required: false),
    'plan_id': BackupColumn(required: false),
    'scheduled_at': BackupColumn(required: false),
  },
  'symptom_entry': {
    'patient_id': BackupColumn(),
    'entry_id': BackupColumn(),
    'symptom': BackupColumn(),
    'location': BackupColumn(),
    'severity': BackupColumn(),
    'started': BackupColumn(),
    'duration': BackupColumn(),
    'factors': BackupColumn(),
    'impact': BackupColumn(),
    'action': BackupColumn(),
  },
  'activity_entry': {
    'patient_id': BackupColumn(),
    'entry_id': BackupColumn(),
    'activity': BackupColumn(),
    'minutes': BackupColumn(),
    'assistance': BackupColumn(),
    'completion': BackupColumn(),
    'after': BackupColumn(),
  },
  'measurement_entry': {
    'patient_id': BackupColumn(),
    'entry_id': BackupColumn(),
    'measurement': BackupColumn(),
    'value': BackupColumn(),
    'unit': BackupColumn(),
    'source': BackupColumn(),
  },
  'daily_living_entry': {
    'patient_id': BackupColumn(),
    'entry_id': BackupColumn(),
    'category': BackupColumn(),
    'details': BackupColumn(),
    'assistance': BackupColumn(),
    'after': BackupColumn(),
  },
  'incident_entry': {
    'patient_id': BackupColumn(),
    'entry_id': BackupColumn(),
    'event': BackupColumn(),
    'action': BackupColumn(),
    'contact': BackupColumn(),
    'after': BackupColumn(),
  },
  'medical_contact_entry': {
    'patient_id': BackupColumn(),
    'entry_id': BackupColumn(),
    'contact_type': BackupColumn(),
    'institution': BackupColumn(),
    'instruction': BackupColumn(),
    'followup': BackupColumn(),
  },
  'handoff_entry': {
    'patient_id': BackupColumn(),
    'entry_id': BackupColumn(),
    'completed': BackupColumn(),
    'pending': BackupColumn(),
    'observe': BackupColumn(),
  },
  'general_note_entry': {
    'patient_id': BackupColumn(),
    'entry_id': BackupColumn(),
  },
};
