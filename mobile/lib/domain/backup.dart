import 'records.dart';

class BackupSelection {
  BackupSelection({
    required Set<String> patientIds,
    this.from,
    this.until,
    this.photos = true,
    this.chats = false,
    this.checkins = false,
    this.identities = false,
  }) : patientIds = Set.unmodifiable(patientIds) {
    if (patientIds.isEmpty ||
        (from != null && until != null && !from!.isBefore(until!))) {
      throw const CareError('수첩을 하나 이상 선택하고 백업 기간을 확인해 주세요.');
    }
  }
  final Set<String> patientIds;

  /// Inclusive start, exclusive end, resolved in the device's local time zone.
  final DateTime? from, until;
  final bool photos, chats, checkins, identities;
  Map<String, Object?> toJson() => {
    'from': from?.millisecondsSinceEpoch,
    'until': until?.millisecondsSinceEpoch,
    'photos': photos,
    'chats': chats,
    'checkins': checkins,
    'identities': identities,
  };
}

typedef BackupRows = Map<String, List<Map<String, Object?>>>;

/// Preview contains counts only. Decrypted records are not retained by the UI.
class BackupPreview {
  const BackupPreview({required this.legacy, this.counts = const {}});
  final bool legacy;
  final Map<String, int> counts;
}
