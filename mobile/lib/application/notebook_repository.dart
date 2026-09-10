import '../domain/records.dart';
import '../domain/chat.dart';
import '../domain/drafts.dart';

/// Internal application persistence port. Screens and AI receive feature APIs,
/// never this full repository or its implementation.
abstract interface class NotebookRepository {
  ChatRetention? chatRetention(String pid);
  void setChatRetention(String pid, ChatRetention policy, {DateTime? now});
  void pruneChats({DateTime? now});
  List<ChatMessage> chatMessages(String pid, {DateTime? now});
  ChatMessage addChatMessage(String pid, String text, {DateTime? now});
  void deleteChatMessage(String pid, String id);
  void clearChatMessages(String pid);
  String? setting(String key);
  void setSetting(String key, String value);
  List<Patient> patients();
  Patient createPatient({
    String alias = '',
    String role = 'family',
    String context = '',
    String contact = '',
  });
  void updatePatient(
    String id, {
    required String alias,
    required String role,
    required String context,
    required String contact,
  });
  void deletePatient(String id);
  CareEntry? entry(String pid, String id);
  List<CareEntry> entries(
    String patientId, {
    EntryKind? kind,
    String query = '',
    DateTime? day,
    int? limit,
    String Function(CareEntry)? displayText,
  });
  CareEntry saveEntry(
    String patientId, {
    String? id,
    int? expectedVersion,
    required EntryKind kind,
    required DateTime occurredAt,
    String note = '',
    Map<String, String> fields = const {},
  });
  List<CareEntry> revisions(String pid, String id);
  void deleteEntry(String pid, String id);
  List<Medication> medications(String pid, {bool includeArchived = false});
  Medication saveMedication(
    String pid, {
    String? id,
    int? expectedVersion,
    required String name,
    required String instruction,
    required List<String> times,
  });
  List<MedicationPlan> medicationPlans(String pid, String id);
  void archiveMedication(String pid, String id, bool archive);
  CareEntry recordIntake(
    String pid,
    String medId,
    String status,
    DateTime at, {
    String reason = '',
    String reaction = '',
    DateTime? scheduledAt,
  });
  List<CareTask> tasks(String pid);
  CareTask saveTask(
    String pid, {
    String? id,
    required String title,
    String note = '',
    required DateTime dueAt,
    bool reminder = false,
  });
  void completeTask(String pid, String id, bool done);
  void deleteTask(String pid, String id);
  List<VisitPreparation> visits(String pid);
  VisitPreparation saveVisit(
    String pid, {
    String? id,
    required String title,
    required String questions,
    required List<String> entryIds,
  });
  List<CareEntry> visitEntries(String pid, String id);
  void deleteVisit(String pid, String id);
  List<Attachment> attachments(String pid, String eid);
  void deleteAttachment(String pid, String id);
  void addCheckin({
    required String fatigue,
    required String sleep,
    required String stress,
    String note = '',
  });
  List<CaregiverCheckin> checkins();
  void deleteCheckin(String id);
  DraftRetention? get draftRetention;
  void setDraftRetention(DraftRetention value, {DateTime? now});
  void pruneDrafts({DateTime? now});
  List<CareDraft> drafts(String? pid, {DateTime? now});
  int draftCount(String? pid);
  void saveDraft({
    required String id,
    required String? patientId,
    required DraftType type,
    required DraftPayload payload,
    String? targetId,
    String? base,
    bool create = true,
    DateTime? now,
  });
  void deleteDraft(String? pid, String id);
  String? draftBase(DraftType type, String? pid, String? targetId);
  void completeDraft(String? pid, String id);
}
