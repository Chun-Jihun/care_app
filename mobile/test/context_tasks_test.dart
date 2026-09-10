import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/domain/notebook_context.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';

import 'support.dart';

void main() {
  test('ARCH-03 context sources, fields and size are host controlled; late work is cancelled', () async {
    final root = await Directory.systemTemp.createTemp(
      'care-context-contract-',
    );
    final c = testController(VaultStore(root, MemorySecrets()), FakePlatform());
    addTearDown(() async {
      c.dispose();
      await root.delete(recursive: true);
    });
    await c.initialize();
    await c.setPin('123456');
    final pid = c.selectedId!;
    await c.profiles.updatePatient(
      pid,
      alias: 'PRIVATE_ALIAS',
      role: 'family',
      context: '',
      contact: 'PRIVATE_CONTACT',
    );
    final entry = await c.records.saveEntry(
      pid,
      kind: EntryKind.meal,
      occurredAt: DateTime(2026),
      note: 'unselected note',
      fields: {'food': 'selected food', 'after': 'unselected field'},
    );
    final other = await c.profiles.createPatient();
    final selected = ContextSelection(
      patientId: pid,
      entryIds: {entry.id},
      entryFields: {'food'},
    );
    final job = c.contextTasks.create(selected);
    late NotebookContextReader captured;
    final result = await job.run((reader) async {
      captured = reader;
      return reader.read();
    });
    expect(result.records.single.fields, {'food': 'selected food'});
    expect(result.records.single.note, isNull);
    expect(result.medications, isEmpty);
    expect(() => result.records.clear(), throwsUnsupportedError);
    expect(() => captured.read(), throwsA(isA<CareError>()));

    final excessive = c.contextTasks.create(
      ContextSelection(
        patientId: pid,
        entryIds: {entry.id},
        includeNotes: true,
        maxCharacters: 1,
      ),
    );
    await expectLater(
      excessive.run((r) async => r.read()),
      throwsA(
        isA<CareError>().having(
          (e) => e.code,
          'code',
          CareErrorCode.contextTooLarge,
        ),
      ),
    );
    for (final change in ['manual', 'switch', 'lock', 'edit', 'delete']) {
      final active = c.contextTasks.create(selected),
          response = Completer<String>();
      final operation = active.run((reader) {
        reader.read();
        return response.future;
      });
      final assertion = expectLater(operation, throwsA(isA<CareError>()));
      expect(c.busy, false);
      switch (change) {
        case 'switch':
          await c.selectPatient(other.id);
        case 'lock':
          c.lock();
        case 'edit':
          await c.records.saveEntry(
            pid,
            id: entry.id,
            expectedVersion: 1,
            kind: entry.kind,
            occurredAt: entry.occurredAt,
            fields: entry.fields,
            note: 'changed',
          );
        case 'delete':
          await c.records.deleteEntry(pid, entry.id);
        case 'manual':
          active.cancel();
      }
      await assertion;
      response.complete('must not display');
      await Future<void>.delayed(Duration.zero);
      if (!c.unlocked) await c.unlockPin('123456');
      if (c.selectedId != pid) await c.selectPatient(pid);
      if (change == 'delete') break; // The source has now been removed.
    }
  });
}
