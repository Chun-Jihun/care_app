import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/infrastructure/crypto.dart';

import 'support.dart';

void main() {
  late Directory root;
  late MemorySecrets secrets;
  late VaultStore vault;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-vault-test-');
    secrets = MemorySecrets();
    vault = VaultStore(root, secrets);
    await vault.open();
  });
  tearDown(() async {
    vault.close();
    await root.delete(recursive: true);
  });
  test('REVIEW-04 rejects oversized PNG headers before allocating pixels', () {
    final source = Uint8List.fromList(
      img.encodePng(img.Image(width: 2, height: 2)),
    );
    final bytes = ByteData.sublistView(source);
    bytes.setUint32(16, 100000);
    bytes.setUint32(20, 100000);
    var crc = 0xffffffff;
    for (final byte in source.sublist(12, 29)) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0);
      }
    }
    bytes.setUint32(29, crc ^ 0xffffffff);
    expect(
      () => VaultStore.normalizePhoto(source),
      throwsA(
        isA<CareError>().having(
          (e) => e.message,
          'size error',
          contains('2,400만'),
        ),
      ),
    );
  });

  test(
    'REVIEW-05 restore commit wins over a future legacy clock marker',
    () async {
      final p = vault.db.createPatient(alias: '복원할 수첩');
      const password = 'review-backup-password';
      final backup = await vault.backup(password);
      vault.db.createPatient(alias: '복원 전 수첩');
      final marker = (await Directory(
        '${root.path}/commits',
      ).list().toList()).single;
      await marker.rename(
        '${root.path}/commits/ffffffff-ffff-7fff-8fff-ffffffffffff.commit',
      );
      await vault.restore(backup, password);
      vault.close();
      vault = VaultStore(root, secrets);
      await vault.open();
      expect(vault.db.patients().single.id, p.id);
    },
  );
  test(
    'REVIEW-05 cleanup failure after commit keeps restored state usable',
    () async {
      final p = vault.db.createPatient(alias: '복원한 수첩');
      const password = 'review-backup-password';
      final backup = await vault.backup(password);
      final originalKey = secrets.values.keys.single;
      vault.db.createPatient();
      secrets.rejectDeleteKey = originalKey;
      await vault.restore(backup, password);
      expect(vault.maintenancePending, true);
      expect(vault.db.patients().single.id, p.id);
      vault.close();
      secrets.rejectDeleteKey = null;
      vault = VaultStore(root, secrets);
      await vault.open();
      expect(vault.maintenancePending, false);
      expect(vault.db.patients().single.id, p.id);
      expect(secrets.values.containsKey(originalKey), false);
    },
  );

  test(
    'REVIEW-01/05 cancelled restore keeps original generation and keys',
    () async {
      vault.db.createPatient();
      const password = 'review-backup-password';
      final backup = await vault.backup(password);
      final current = vault.db.createPatient(alias: '보존할 수첩');
      final originalKeys = Map<String, String>.from(secrets.values);
      await expectLater(
        vault.restore(
          backup,
          password,
          beforeCommit: () => throw const CareError('잠금'),
        ),
        throwsA(isA<CareError>()),
      );
      expect(vault.db.patients().any((p) => p.id == current.id), true);
      expect(secrets.values, originalKeys);
    },
  );
  test('LOCAL-07/09 photo raster loses metadata, encrypted attachment survives reopen and scoped deletion', () async {
    final p = vault.db.createPatient(), other = vault.db.createPatient();
    final e = vault.db.saveEntry(
      p.id,
      kind: EntryKind.generalNote,
      note: '사진 기록',
      occurredAt: DateTime.now(),
    );
    final source = img.Image(width: 16, height: 16);
    source.textData = {'private-location': 'SENSITIVE_IMAGE_METADATA'};
    img.fill(source, color: img.ColorRgb8(120, 180, 80));
    await vault.addPhoto(p.id, e.id, Uint8List.fromList(img.encodePng(source)));
    final attachment = vault.db.attachments(p.id, e.id).single;
    final jpeg = await vault.photo(p.id, e.id, attachment.id);
    expect(img.decodeJpg(jpeg)?.width, 16);
    expect(latin1.decode(jpeg), isNot(contains('SENSITIVE_IMAGE_METADATA')));
    final disk =
        (await root
                    .list(recursive: true)
                    .where((f) => f.path.endsWith('.enc'))
                    .toList())
                .single
            as File;
    expect(await disk.readAsBytes(), isNot(equals(jpeg)));
    await expectLater(
      vault.photo(other.id, e.id, attachment.id),
      throwsA(isA<CareError>()),
    );
    vault.close();
    vault = VaultStore(root, secrets);
    await vault.open();
    expect(await vault.photo(p.id, e.id, attachment.id), jpeg);
    vault.db.deleteEntry(p.id, e.id);
    vault.close();
    vault = VaultStore(root, secrets);
    await vault.open();
    expect(await disk.exists(), false);
    expect(vault.db.pendingFileDeletes, isEmpty);
  });
  test('LOCAL-08 backup verifies password, tamper, source links and commits a complete replacement', () async {
    final p = vault.db.createPatient(alias: '백업 별칭');
    final e = vault.db.saveEntry(
      p.id,
      kind: EntryKind.generalNote,
      note: 'BACKUP_SENTINEL',
      occurredAt: DateTime.now(),
    );
    await vault.addPhoto(
      p.id,
      e.id,
      Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4))),
    );
    vault.db.addCheckin(fatigue: '내 상태', sleep: '수면', stress: '기록');
    const password = 'long-backup-password';
    final backup = await vault.backup(password);
    vault.db.saveEntry(
      p.id,
      kind: EntryKind.generalNote,
      note: '복원 전 현재 기록',
      occurredAt: DateTime.now(),
    );
    await expectLater(
      vault.restore(backup, 'wrong-password'),
      throwsA(anything),
    );
    expect(vault.db.entries(p.id), hasLength(2));
    final corrupt = Uint8List.fromList(backup);
    corrupt[60] ^= 1;
    await expectLater(vault.restore(corrupt, password), throwsA(anything));
    expect(vault.db.entries(p.id), hasLength(2));
    final decoded = jsonDecode(
      utf8.decode(await VaultCrypto.passwordOpen(backup, password)),
    ) as Map<String, dynamic>;
    decoded['files'] = {};
    final incomplete = await VaultCrypto.passwordSeal(
      Uint8List.fromList(utf8.encode(jsonEncode(decoded))),
      password,
    );
    await expectLater(
      vault.restore(incomplete, password),
      throwsA(isA<CareError>()),
    );
    expect(vault.db.entries(p.id), hasLength(2));
    await vault.restore(backup, password);
    expect(vault.db.entries(p.id).single.note, 'BACKUP_SENTINEL');
    expect(vault.db.patients().single.alias, '백업 별칭');
    expect(vault.db.checkins(), hasLength(1));
    vault.close();
    vault = VaultStore(root, secrets);
    await vault.open();
    expect(vault.db.entries(p.id), hasLength(1));
    expect(vault.db.attachments(p.id, e.id), hasLength(1));
    expect(
      (await root
          .list()
          .where((f) => f is Directory && !f.path.endsWith('commits'))
          .toList()),
      hasLength(1),
    );
  });
  test(
    'LOCAL-02/07 missing key preserves files and pending full wipe resumes',
    () async {
      vault.db.createPatient();
      vault.close();
      final key = secrets.values.keys.firstWhere((k) => k.startsWith('vault.'));
      final value = secrets.values.remove(key)!;
      vault = VaultStore(root, secrets);
      await expectLater(vault.open(), throwsA(isA<CareError>()));
      expect(
        await root.list(recursive: true).any((f) => f.path.endsWith('care.db')),
        true,
      );
      secrets.values[key] = value;
      await File('${root.path}/wipe.pending').writeAsString('1');
      await vault.open();
      expect(vault.db.patients(), isEmpty);
      expect(secrets.values.containsKey(key), false);
      await vault.wipe();
      expect(await root.list().isEmpty, true);
      expect(secrets.values.keys.where((k) => k.startsWith('vault.')), isEmpty);
    },
  );
}
