import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/domain/drafts.dart';
import 'package:care_notebook/domain/backup.dart';
import 'package:care_notebook/l10n/error_messages.dart';
import 'package:care_notebook/l10n/catalogs.g.dart';

void main() {
  test('ARCH-10 every stable error code has a translated display message', () {
    expect(errorMessages.keys.toSet(), CareErrorCode.values.toSet());
    for (final catalog in translationCatalogs.values) {
      for (final message in errorMessages.values) {
        expect(catalog.containsKey(message), true, reason: message);
      }
    }
  });
  test(
    'ARCH-05 snapshots do not alias constructor or serialization collections',
    () {
      final fields = {'food': 'original'};
      final entry = CareEntry(
        id: 'entry',
        patientId: 'patient',
        kind: EntryKind.meal,
        occurredAt: DateTime(2026),
        offsetMinutes: 540,
        note: '',
        fields: fields,
        version: 1,
      );
      fields['food'] = 'changed';
      expect(entry.fields['food'], 'original');
      expect(() => entry.fields['food'] = 'changed', throwsUnsupportedError);
      (entry.toJson()['fields'] as Map<String, String>)['food'] = 'JSON edit';
      expect(entry.fields['food'], 'original');
      final selected = ['one'];
      final payload = VisitDraftPayload(selected: selected);
      selected.clear();
      expect(payload.selected, ['one']);
      expect(
        () => (payload.toFields()['selected'] as List).clear(),
        throwsUnsupportedError,
      );
      final counts = {BackupCategory.records: 3};
      final preview = BackupPreview(legacy: false, counts: counts);
      counts.clear();
      expect(preview.counts[BackupCategory.records], 3);
    },
  );

  test('ARCH-04 typed drafts read legacy and versioned data without losing incomplete text', () {
    final legacy = DraftPayload.decode(
      DraftType.entry,
      '{"kind":"symptom","note":"unfinished","fields":{"symptom":""}}',
    );
    expect(legacy, isA<EntryDraftPayload>());
    final saved = DraftPayload.decode(
      DraftType.entry,
      legacy.encode(),
    ) as EntryDraftPayload;
    expect(saved.note, 'unfinished');
    expect(saved.fields['symptom'], '');
    for (final raw in [
      '{"kind":"unknown"}',
      '{invalid',
      '{"version":999,"fields":{}}',
      '{"kind":"meal","fields":{"food":7}}',
    ]) {
      final failed = DraftPayload.decode(DraftType.entry, raw);
      expect(failed, isA<UnreadableDraftPayload>());
      expect(failed.encode(), raw);
    }
  });

  test('ARCH-02 presentation has no storage imports or generic mutation escape hatch', () {
    final forbidden = RegExp(
      r"infrastructure/|\.db\b|\.vault\b|\.secrets\b|\.mutate\s*\(",
    );
    for (final file
        in Directory('lib/presentation')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      expect(
        forbidden.hasMatch(file.readAsStringSync()),
        isFalse,
        reason: file.path,
      );
    }
  });
}
