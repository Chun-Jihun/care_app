import 'dart:async';
import 'dart:io';

import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/application/drug_safety_rules.dart';
import 'package:care_notebook/domain/drug_safety.dart';
import 'package:care_notebook/domain/knowledge.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/domain/backup.dart';
import 'package:care_notebook/infrastructure/care_database.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final hash = 'a' * 64;
const a = DrugProduct('111111111', 'Synthetic A', 'Synthetic manufacturer');
const b = DrugProduct('222222222', 'Synthetic B', 'Synthetic manufacturer');
DurRecord row(
  int id,
  String operation,
  String item, {
  String counterpart = '',
}) => DurRecord(
  id: id,
  packageHash: hash,
  operation: operation,
  page: 1,
  row: id,
  source: const KnowledgeSource(
    id: 'synthetic',
    title: 'Synthetic source',
    publisher: 'Test',
    url: 'https://example.org/test',
    version: '1',
    pageCount: 0,
  ),
  fields: {
    'ITEM_SEQ': item,
    'MIXTURE_ITEM_SEQ': counterpart,
    'PROHBT_CONTENT': 'SYNTHETIC CONDITION',
    'REMARK': 'SYNTHETIC EXCEPTION',
  },
);

class Catalog implements DrugCatalog {
  DrugDataState state = DrugDataState.ready;
  String release = hash;
  Completer<void>? pending;
  int calls = 0;
  @override
  Future<DrugCatalogInfo> status() async =>
      DrugCatalogInfo(state, releaseId: release);
  @override
  Future<DrugProducts> search(String query) async => DrugProducts(
    await status(),
    [a, b].where((p) => p.code == query || p.name == query),
  );
  @override
  Future<DurRecords> records(Set<String> codes, String releaseId) async {
    calls++;
    await pending?.future;
    return DurRecords([
      row(1, DrugSafetyRules.pairOperation, a.code, counterpart: b.code),
    ], complete: true);
  }
}

void main() {
  test('DUR matches both exact products, deduplicates references and preserves exceptions', () {
    final pair = row(
      1,
      DrugSafetyRules.pairOperation,
      a.code,
      counterpart: b.code,
    );
    final data = DurRecords([
      pair,
      pair,
      row(2, 'getPwnmTabooInfoList03', a.code),
    ], complete: true);
    expect(DrugSafetyRules.match([b.code], data).records, isEmpty);
    final report = DrugSafetyRules.match([b.code, a.code, a.code], data);
    expect(report.records, hasLength(2));
    expect(report.records.first.fields['REMARK'], 'SYNTHETIC EXCEPTION');
    expect(report.repeatedProducts, [a.code]);
  });
  test(
    'DUR truncated and unknown operations fail closed; empty never means safe',
    () {
      expect(
        DrugSafetyRules.match([a.code], DurRecords([], complete: false)).state,
        DrugCheckState.incomplete,
      );
      expect(
        DrugSafetyRules.match([
          a.code,
        ], DurRecords([row(1, 'unknown', a.code)], complete: true)).state,
        DrugCheckState.incomplete,
      );
      final empty = DrugSafetyRules.match([
        a.code,
      ], DurRecords([], complete: true));
      expect(empty.state, DrugCheckState.checked);
      expect(empty.records, isEmpty);
      expect(DrugCheckState.values.map((s) => s.name), isNot(contains('safe')));
    },
  );

  group('confirmed products', () {
    late Directory root;
    late VaultStore vault;
    late CareController c;
    late Catalog catalog;
    late String pid;
    late Medication med;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('drug-safety-test-');
      vault = VaultStore(root, MemorySecrets());
      catalog = Catalog();
      c = CareController(
        vault,
        FakePlatform(),
        drugCatalog: () async => catalog,
      );
      await c.initialize();
      await c.setPin('123456');
      await c.profiles.createPatient();
      pid = c.selectedId!;
      med = await c.medicationBook.saveMedication(
        pid,
        name: 'User label',
        instruction: 'Keep instruction',
        times: [],
      );
    });
    tearDown(() async {
      c.dispose();
      await root.delete(recursive: true);
    });

    test('encrypted product confirmation survives lock; late locked result is rejected', () async {
      await c.medicationSafety.confirm(pid, med, a, hash);
      catalog.pending = Completer<void>();
      final expectation = expectLater(
        c.medicationSafety.check(pid),
        throwsA(isA<CareError>()),
      );
      while (catalog.calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      c.lock();
      catalog.pending!.complete();
      await expectation;
      await c.unlockPin('123456');
      expect(c.medicationBook.medications(pid).single.product!.code, a.code);
      for (final file
          in root
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.db'))) {
        expect(
          String.fromCharCodes(file.readAsBytesSync()),
          isNot(contains(a.name)),
        );
      }
    });

    test('persists explicit binding without changing prescription; edit invalidates', () async {
      await c.medicationSafety.confirm(pid, med, a, hash);
      final stored = c.medicationBook.medications(pid).single;
      expect(stored.product!.code, a.code);
      expect(stored.name, med.name);
      expect(stored.instruction, med.instruction);
      await c.medicationBook.saveMedication(
        pid,
        id: med.id,
        expectedVersion: med.version,
        name: 'New label',
        instruction: med.instruction,
        times: [],
      );
      expect(c.medicationBook.medications(pid).single.product, isNull);
      await expectLater(
        c.medicationSafety.confirm(pid, med, a, hash),
        throwsA(isA<CareError>()),
      );
    });
    test(
      'archive invalidates and scoped repository rejects foreign patient',
      () async {
        await c.medicationSafety.confirm(pid, med, a, hash);
        final db = vault.repository as CareDatabase;
        final other = db.createPatient().id;
        expect(
          () => db.confirmMedicationProduct(other, med.id, med.version, null),
          throwsA(anything),
        );
        await c.medicationBook.archiveMedication(pid, med.id, true);
        await c.medicationBook.archiveMedication(pid, med.id, false);
        expect(c.medicationBook.medications(pid).single.product, isNull);
      },
    );
    test(
      'backup retains medication and omits device confirmation authority',
      () async {
        await c.medicationSafety.confirm(pid, med, a, hash);
        final rows = (vault.repository as CareDatabase).selectBackup(
          BackupSelection(patientIds: {pid}),
        );
        expect(rows['medication']!.single['name'], med.name);
        expect(rows.containsKey('medication_product'), isFalse);
        expect(rows['medication']!.single.containsKey('item_code'), isFalse);
      },
    );
    test(
      'missing, unreviewed and stale data never query clinical records',
      () async {
        for (final state in [
          DrugDataState.missing,
          DrugDataState.unreviewed,
          DrugDataState.stale,
        ]) {
          catalog.state = state;
          expect(
            (await c.medicationSafety.check(pid)).state,
            isNot(DrugCheckState.checked),
          );
        }
        expect(catalog.calls, 0);
      },
    );
    test('unconfirmed and catalog-changed products cannot enter DUR', () async {
      expect(
        (await c.medicationSafety.check(pid)).state,
        DrugCheckState.needsConfirmation,
      );
      await c.medicationSafety.confirm(pid, med, a, hash);
      catalog.release = 'b' * 64;
      expect(
        (await c.medicationSafety.check(pid)).state,
        DrugCheckState.needsConfirmation,
      );
      expect(catalog.calls, 0);
    });
    test(
      'medication change and cancellation discard delayed results',
      () async {
        await c.medicationSafety.confirm(pid, med, a, hash);
        catalog.pending = Completer<void>();
        final pending = c.medicationSafety.check(pid);
        final expectation = expectLater(pending, throwsA(anything));
        while (catalog.calls == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        await c.medicationBook.archiveMedication(pid, med.id, true);
        catalog.pending!.complete();
        await expectation;
        await expectLater(
          c.medicationSafety.check(
            pid,
            checkCancelled: () => throw StateError('cancel'),
          ),
          throwsStateError,
        );
      },
    );
  });
}
