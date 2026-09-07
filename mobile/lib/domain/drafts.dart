enum DraftType {
  entry('간병일기'),
  medication('약 목록'),
  intake('복약 기록'),
  task('할 일'),
  visit('진료 준비'),
  checkin('돌보는 나');

  const DraftType(this.label);
  final String label;
}

enum DraftRetention {
  week('7d', '7일', 7),
  month('30d', '30일', 30),
  forever('forever', '직접 삭제할 때까지', null);

  const DraftRetention(this.code, this.label, this.days);
  final String code, label;
  final int? days;
}

/// Unconfirmed form data. Never a care entry, medication plan or chat message.
class CareDraft {
  const CareDraft({
    required this.id,
    required this.patientId,
    required this.type,
    required this.targetId,
    required this.base,
    required this.values,
    required this.updatedAt,
    required this.expiresAt,
  });
  final String id;
  final String? patientId, targetId, base;
  final DraftType type;
  final Map<String, dynamic> values;
  final DateTime updatedAt;
  final DateTime? expiresAt;
}
