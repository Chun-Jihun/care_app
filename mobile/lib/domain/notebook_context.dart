import 'records.dart';

/// The host selects exact sources. An adapter cannot broaden these permissions.
final class ContextSelection {
  ContextSelection({
    required this.patientId,
    Set<String> entryIds = const {},
    Set<String> medicationIds = const {},
    Set<String> entryFields = const {},
    this.includeNotes = false,
    this.from,
    this.until,
    this.maxCharacters = 20000,
  }) : entryIds = Set.unmodifiable(entryIds),
       medicationIds = Set.unmodifiable(medicationIds),
       entryFields = Set.unmodifiable(entryFields) {
    if (entryIds.length > 50 ||
        medicationIds.length > 20 ||
        maxCharacters < 1 ||
        maxCharacters > 20000 ||
        (from != null && until != null && !from!.isBefore(until!))) {
      throw CareError(CareErrorCode.invalidContextSelection);
    }
  }
  final String patientId;
  final Set<String> entryIds, medicationIds, entryFields;
  final bool includeNotes;
  final DateTime? from, until;
  final int maxCharacters;
}

final class ContextRecord {
  ContextRecord({
    required this.id,
    required this.kind,
    required this.at,
    required this.version,
    required this.note,
    required Map<String, String> fields,
  }) : fields = Map.unmodifiable(fields);
  final String id;
  final EntryKind kind;
  final DateTime at;
  final int version;
  final String? note;
  final Map<String, String> fields;
}

final class ContextMedication {
  ContextMedication({
    required this.id,
    required this.name,
    required this.instruction,
    required this.version,
    required List<String> times,
  }) : times = List.unmodifiable(times);
  final String id, name, instruction;
  final int version;
  final List<String> times;
}

/// Contains selected care data only: no aliases, contacts, photos, keys or drafts.
final class NotebookContext {
  NotebookContext({
    required List<ContextRecord> records,
    required List<ContextMedication> medications,
  }) : records = List.unmodifiable(records),
       medications = List.unmodifiable(medications);
  final List<ContextRecord> records;
  final List<ContextMedication> medications;
}

abstract interface class NotebookContextReader {
  NotebookContext read();
  bool get cancelled;
}
