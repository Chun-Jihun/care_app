import '../domain/records.dart';

/// Physical names are persistence details, independent of UI metadata.
extension EntryTable on EntryKind {
  String get table => switch (this) {
    EntryKind.meal => 'meal_entry',
    EntryKind.medicationIntake => 'medication_intake',
    EntryKind.symptom => 'symptom_entry',
    EntryKind.activity => 'activity_entry',
    EntryKind.measurement => 'measurement_entry',
    EntryKind.dailyLiving => 'daily_living_entry',
    EntryKind.incident => 'incident_entry',
    EntryKind.medicalContact => 'medical_contact_entry',
    EntryKind.handoff => 'handoff_entry',
    EntryKind.generalNote => 'general_note_entry',
  };
}
