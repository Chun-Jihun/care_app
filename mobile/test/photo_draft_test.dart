import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:care_notebook/application/draft_session.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/domain/drafts.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';

import 'support.dart';

// Atomicity: a cancelled/invalid photo must not leave a partial record, changed
// prescription or deleted draft. Locking during encryption must reject commit.
class InvalidPhotoPlatform extends FakePlatform {
  @override
  Future<Uint8List?> pickPhoto({bool camera = false}) async =>
      Uint8List.fromList([1, 2, 3]);
}

void main() {
  late Directory root;
  late CareController c;
  late VaultStore vault;
  late String pid;
  final photo = Uint8List.fromList(
    img.encodePng(img.Image(width: 12, height: 12)),
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-photo-draft-');
    vault = VaultStore(root, MemorySecrets());
    c = testController(vault, FakePlatform());
    await c.initialize();
    await c.setPin('123456');
    pid = c.selectedId!;
    await c.drafts.setRetention(DraftRetention.month);
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });
  List<File> attachments() => root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.enc'))
      .toList();
  DraftSession draft(DraftPayload value, {String? target}) => DraftSession(
    c,
    patientId: pid,
    type: value.type,
    targetId: target,
    snapshot: () => value,
  );

  test(
    'photo and confirmed text save together, survive reopen and discard draft',
    () async {
      final d = draft(
        EntryDraftPayload(
          kind: EntryKind.meal,
          note: 'reviewed photo',
          at: DateTime.now(),
          fields: {'food': 'rice'},
        ),
      );
      addTearDown(d.dispose);
      await d.complete(photo: photo);
      final entry = c.entries.single;
      final a = c.records.attachments(pid, entry.id).single;
      expect(c.drafts.list(pid), isEmpty);
      final decoded = await c.photo(pid, entry.id, a.id);
      expect(img.decodeJpg(decoded), isNotNull);
      expect(attachments(), hasLength(1));
      expect(await attachments().single.readAsBytes(), isNot(decoded));
      c.lock();
      await c.unlockPin('123456');
      expect((await c.photo(pid, entry.id, a.id)), decoded);
    },
  );

  test('failed photo leaves old medication, source records and recoverable draft intact', () async {
    final med = await c.medicationBook.saveMedication(
      pid,
      name: 'old medicine',
      instruction: 'old direction',
      times: [],
    );
    final d = draft(
      const MedicationDraftPayload(
        name: 'new medicine',
        instruction: 'reviewed direction',
        times: '09:00',
      ),
      target: med.id,
    );
    addTearDown(d.dispose);
    await expectLater(
      d.complete(photo: Uint8List.fromList([1, 2, 3])),
      throwsA(isA<CareError>()),
    );
    expect(c.medications.single.name, 'old medicine');
    expect(c.entries, isEmpty);
    expect(c.drafts.list(pid).single.id, d.id);
    expect(attachments(), isEmpty);
    await d.complete(photo: photo);
    expect(c.medications.single.name, 'new medicine');
    expect(c.entries.single.kind, EntryKind.medicalContact);
    expect(c.medications.single.instruction, 'reviewed direction');
    expect(c.entries.single.note, 'new medicine');
    expect(c.records.attachments(pid, c.entries.single.id), hasLength(1));
    expect(c.drafts.list(pid), isEmpty);
  });

  test('database validation failure removes prepared encrypted file and keeps draft', () async {
    final d = draft(
      EntryDraftPayload(kind: EntryKind.symptom, note: '', fields: {}),
    );
    addTearDown(d.dispose);
    await expectLater(d.complete(photo: photo), throwsA(isA<CareError>()));
    expect(c.entries, isEmpty);
    expect(c.drafts.list(pid), hasLength(1));
    expect(attachments(), isEmpty);
  });

  test(
    'locking during photo preparation prevents commit and preserves text draft',
    () async {
      final d = draft(
        EntryDraftPayload(kind: EntryKind.generalNote, note: 'recover text'),
      );
      addTearDown(d.dispose);
      final saving = d.complete(photo: photo);
      c.lock();
      await expectLater(saving, throwsA(isA<CareError>()));
      await c.unlockPin('123456');
      expect(c.entries, isEmpty);
      expect(c.drafts.list(pid).single.values['note'], 'recover text');
      expect(attachments(), isEmpty);
    },
  );

  test('cancelled photo picker creates no entry or attachment', () async {
    expect(await c.photos.pick(pid), isNull);
    expect(c.entries, isEmpty);
    expect(attachments(), isEmpty);
  });

  test(
    'today intake lookup uses medication identity and local day boundaries',
    () async {
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day);
      final first = await c.medicationBook.saveMedication(
        pid,
        name: 'same name',
        instruction: '',
        times: [],
      );
      final second = await c.medicationBook.saveMedication(
        pid,
        name: 'same name',
        instruction: '',
        times: [],
      );
      final expected = await c.medicationBook.recordIntake(
        pid,
        first.id,
        'taken',
        day,
      );
      await c.medicationBook.recordIntake(
        pid,
        first.id,
        'missed',
        day.subtract(const Duration(milliseconds: 1)),
      );
      await c.medicationBook.recordIntake(
        pid,
        first.id,
        'unknown',
        DateTime(day.year, day.month, day.day + 1),
      );
      await c.records.saveEntry(
        pid,
        kind: EntryKind.medicationIntake,
        occurredAt: day,
        fields: {'medicine': 'same name', 'status': 'taken'},
      );
      expect(c.medicationBook.intakes(pid, first.id, now).map((e) => e.id), [
        expected.id,
      ]);
      expect(c.medicationBook.intakes(pid, second.id, now), isEmpty);
      final other = await c.profiles.createPatient();
      await c.selectPatient(other.id);
      expect(
        () => c.medicationBook.intakes(pid, first.id, now),
        throwsA(isA<CareError>()),
      );
    },
  );
  test(
    'invalid chosen image is rejected before any preview or record',
    () async {
      c.dispose();
      c = testController(vault, InvalidPhotoPlatform());
      await c.initialize();
      await c.unlockPin('123456');
      await expectLater(
        c.photos.pick(c.selectedId!),
        throwsA(isA<CareError>()),
      );
      expect(c.entries, isEmpty);
      expect(attachments(), isEmpty);
    },
  );
}
