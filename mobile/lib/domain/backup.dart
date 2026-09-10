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
      throw CareError(CareErrorCode.invalidBackupSelection);
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

enum BackupCategory {
  notebooks,
  records,
  medications,
  tasks,
  visits,
  photos,
  chats,
  checkins,
}

/// Preview contains counts only. Decrypted records are not retained by the UI.
class BackupPreview {
  BackupPreview({
    required this.legacy,
    Map<BackupCategory, int> counts = const {},
  }) : counts = Map.unmodifiable(counts);
  final bool legacy;
  final Map<BackupCategory, int> counts;
}
