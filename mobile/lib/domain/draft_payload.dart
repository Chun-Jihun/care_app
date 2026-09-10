import 'dart:convert';

import 'draft_types.dart';
import 'immutable.dart';
import 'records.dart';

/// Incomplete input is allowed. Shape validation is separate from confirmation.
sealed class DraftPayload {
  const DraftPayload();
  DraftType get type;
  Map<String, Object?> toFields();
  String encode() => jsonEncode({'version': 1, 'fields': toFields()});

  static DraftPayload decode(DraftType type, String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) throw const FormatException();
      final fields = value.containsKey('version')
          ? value['version'] == 1 && value['fields'] is Map<String, dynamic>
                ? value['fields'] as Map<String, dynamic>
                : throw const FormatException()
          : value; // Existing unversioned drafts remain readable.
      return fromFields(type, fields);
    } on Object {
      return UnreadableDraftPayload(type, raw);
    }
  }

  static DraftPayload fromFields(DraftType type, Map<String, dynamic> data) {
    String text(String key) => (data[key] ?? '') as String;
    DateTime? time(String key) {
      final value = data[key];
      if (value == null) return null;
      if (value is! int || value < -2208988800000 || value >= 7289654400000) {
        throw const FormatException('Invalid draft timestamp');
      }
      return DateTime.fromMillisecondsSinceEpoch(value);
    }

    return switch (type) {
      DraftType.entry => EntryDraftPayload(
        kind: EntryKind.values.byName(data['kind'] as String),
        note: text('note'),
        at: time('at'),
        fields: Map<String, String>.from(data['fields'] as Map? ?? {}),
      ),
      DraftType.medication => MedicationDraftPayload(
        name: text('name'),
        instruction: text('instruction'),
        times: text('times'),
      ),
      DraftType.intake => IntakeDraftPayload(
        status: text('status'),
        reason: text('reason'),
        reaction: text('reaction'),
        at: time('at'),
      ),
      DraftType.task => TaskDraftPayload(
        title: text('title'),
        note: text('note'),
        at: time('at'),
        reminder: (data['reminder'] ?? false) as bool,
      ),
      DraftType.visit => VisitDraftPayload(
        title: text('title'),
        questions: text('questions'),
        selected: List<String>.from(data['selected'] as List? ?? []),
      ),
      DraftType.checkin => CheckinDraftPayload(
        fatigue: text('fatigue'),
        sleep: text('sleep'),
        stress: text('stress'),
        note: text('note'),
      ),
    };
  }
}

final class EntryDraftPayload extends DraftPayload {
  EntryDraftPayload({
    required this.kind,
    this.note = '',
    this.at,
    Map<String, String> fields = const {},
  }) : fields = Map.unmodifiable(fields);
  final EntryKind kind;
  final String note;
  final DateTime? at;
  final Map<String, String> fields;
  @override
  DraftType get type => DraftType.entry;
  @override
  Map<String, Object?> toFields() => immutableMap({
    'kind': kind.name,
    'note': note,
    'at': at?.millisecondsSinceEpoch,
    'fields': fields,
  });
}

final class MedicationDraftPayload extends DraftPayload {
  const MedicationDraftPayload({
    this.name = '',
    this.instruction = '',
    this.times = '',
  });
  final String name, instruction, times;
  @override
  DraftType get type => DraftType.medication;
  @override
  Map<String, Object?> toFields() => Map.unmodifiable({
    'name': name,
    'instruction': instruction,
    'times': times,
  });
}

final class IntakeDraftPayload extends DraftPayload {
  const IntakeDraftPayload({
    this.status = 'taken',
    this.reason = '',
    this.reaction = '',
    this.at,
  });
  final String status, reason, reaction;
  final DateTime? at;
  @override
  DraftType get type => DraftType.intake;
  @override
  Map<String, Object?> toFields() => Map.unmodifiable({
    'status': status,
    'reason': reason,
    'reaction': reaction,
    'at': at?.millisecondsSinceEpoch,
  });
}

final class TaskDraftPayload extends DraftPayload {
  const TaskDraftPayload({
    this.title = '',
    this.note = '',
    this.at,
    this.reminder = false,
  });
  final String title, note;
  final DateTime? at;
  final bool reminder;
  @override
  DraftType get type => DraftType.task;
  @override
  Map<String, Object?> toFields() => Map.unmodifiable({
    'title': title,
    'note': note,
    'at': at?.millisecondsSinceEpoch,
    'reminder': reminder,
  });
}

final class VisitDraftPayload extends DraftPayload {
  VisitDraftPayload({
    this.title = '',
    this.questions = '',
    List<String> selected = const [],
  }) : selected = List.unmodifiable(selected);
  final String title, questions;
  final List<String> selected;
  @override
  DraftType get type => DraftType.visit;
  @override
  Map<String, Object?> toFields() => Map.unmodifiable({
    'title': title,
    'questions': questions,
    'selected': selected,
  });
}

final class CheckinDraftPayload extends DraftPayload {
  const CheckinDraftPayload({
    this.fatigue = '',
    this.sleep = '',
    this.stress = '',
    this.note = '',
  });
  final String fatigue, sleep, stress, note;
  @override
  DraftType get type => DraftType.checkin;
  @override
  Map<String, Object?> toFields() => Map.unmodifiable({
    'fatigue': fatigue,
    'sleep': sleep,
    'stress': stress,
    'note': note,
  });
}

/// Kept verbatim for local inspection/deletion; never eligible for confirmation.
final class UnreadableDraftPayload extends DraftPayload {
  const UnreadableDraftPayload(this.type, this.raw);
  @override
  final DraftType type;
  final String raw;
  @override
  Map<String, Object?> toFields() => const {};
  @override
  String encode() => raw;
}
