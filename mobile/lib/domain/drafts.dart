import 'draft_types.dart';
export 'draft_types.dart';
import 'draft_payload.dart';
export 'draft_payload.dart';

/// Unconfirmed form data. Never a care entry, medication plan or chat message.
class CareDraft {
  const CareDraft({
    required this.id,
    required this.patientId,
    required this.type,
    required this.targetId,
    required this.base,
    required this.payload,
    required this.updatedAt,
    required this.expiresAt,
  });
  final String id;
  final String? patientId, targetId, base;
  final DraftType type;
  final DraftPayload payload;
  bool get canResume => payload is! UnreadableDraftPayload;
  Map<String, Object?> get values => payload.toFields();
  final DateTime updatedAt;
  final DateTime? expiresAt;
}
