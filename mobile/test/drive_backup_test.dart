import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/application/services/drive_backup_service.dart';
import 'package:care_notebook/domain/backup.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/presentation/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support.dart';

class FakeDrive implements BackupDrive {
  static const email = 'test@example.invalid';
  final uploaded = <Uint8List>[];
  int reserved = 0;
  bool fail = false;
  Completer<void>? uploadCompleted;
  Completer<void>? uploading;
  Completer<void>? resumeUpload;
  @override
  Future<String> connect() async => email;
  @override
  Future<void> reconnect(String email) async {}
  @override
  Future<void> disconnect(String email) async {}
  @override
  Future<String> reserveFile(String email) async {
    expect(email, FakeDrive.email);
    reserved++;
    return 'backup-id';
  }

  @override
  Future<void> upload(
    String email,
    String fileId,
    Uint8List data,
    void Function() check,
  ) async {
    check();
    expect((email, fileId), (FakeDrive.email, 'backup-id'));
    if (fail) throw const SocketException('synthetic network failure');
    uploading?.complete();
    await resumeUpload?.future;
    uploaded.add(data);
    uploadCompleted?.complete();
  }

  @override
  Future<List<DriveBackupFile>> files(String email) async => [
    (id: 'backup-id', accountEmail: email, modifiedAt: DateTime.now()),
  ];
  @override
  Future<Uint8List> download(String email, String fileId) async =>
      uploaded.last;
}

void main() {
  const password = 'synthetic-drive-backup-password';
  late Directory root;
  late MemorySecrets secrets;
  late VaultStore vault;
  late FakeDrive drive;
  late CareController controller;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('care-drive-backup-');
    secrets = MemorySecrets();
    vault = VaultStore(root, secrets);
    drive = FakeDrive();
    controller = CareController(
      vault,
      FakePlatform(),
      backupDrive: drive,
      driveSecrets: secrets,
    );
    await controller.initialize();
    await controller.startWithoutLock();
  });
  tearDown(() async {
    controller.dispose();
    await root.delete(recursive: true);
  });

  test(
    'only a successful upload counts, and the backup restores across devices',
    () async {
      final service = controller.driveBackup!;
      await service.backup();
      expect(drive.reserved, 0);
      final pid = controller.selectedId!;
      final other = vault.repository.createPatient().id;
      final photo = img.encodePng(img.Image(width: 2, height: 2));
      for (final id in [pid, other]) {
        final entry = vault.repository.saveEntry(
          id,
          kind: EntryKind.generalNote,
          occurredAt: DateTime.now(),
          note: 'synthetic note',
        );
        await vault.addPhoto(id, entry.id, photo);
        vault.repository.saveMedication(
          id,
          name: 'synthetic med',
          instruction: '',
          times: [],
        );
        vault.repository.saveTask(
          id,
          title: 'synthetic task',
          dueAt: DateTime.now(),
        );
      }
      await service.enable(password);
      drive.fail = true;
      await service.backup();
      expect((await service.status())?.lastSuccess, isNull);
      expect(service.failure, isA<SocketException>());
      drive.fail = false;
      await service.backup();
      expect((await service.status())?.lastSuccess, isNotNull);
      expect(service.failure, isNull);
      await service.backup();
      expect(drive.uploaded, hasLength(1));
      expect(drive.reserved, 1);
      final file = (await service.availableFiles()).single;
      final encrypted = await service.download(file);
      expect(String.fromCharCodes(encrypted.take(8)), 'CAREBK01');
      final otherVault = VaultStore(
        await Directory('${root.path}/restore').create(),
        MemorySecrets(),
      );
      try {
        await otherVault.open();
        final preview = await otherVault.inspectBackup(encrypted, password);
        expect(preview.counts[BackupCategory.notebooks], 2);
        expect(preview.counts[BackupCategory.photos], 2);
        expect(preview.counts[BackupCategory.medications], 2);
        expect(preview.counts[BackupCategory.tasks], 2);
        expect(preview.counts[BackupCategory.chats], 0);
        expect(preview.counts[BackupCategory.checkins], 0);
        await otherVault.importSelection(encrypted, password);
        expect(otherVault.repository.patients(), hasLength(2));
      } finally {
        otherVault.close();
      }
      await service.backup(now: true);
      expect(drive.uploaded, hasLength(2));
      expect(drive.reserved, 1);
    },
  );

  test(
    'overlapping opens and local erasure cannot restore the stored password',
    () async {
      final service = controller.driveBackup!;
      await service.enable(password);
      drive.uploading = Completer<void>();
      drive.resumeUpload = Completer<void>();
      final backup = service.backup();
      await drive.uploading!.future;
      await service.backup();
      await controller.deleteAll();
      drive.resumeUpload!.complete();
      await backup;
      expect(
        secrets.values.values.any((value) => value.contains(password)),
        isFalse,
      );
      expect(drive.uploaded, hasLength(1));
    },
  );

  testWidgets('opening an already unlocked notebook schedules its due backup', (
    tester,
  ) async {
    drive.uploadCompleted = Completer<void>();
    await tester.runAsync(() => controller.driveBackup!.enable(password));
    await tester.pumpWidget(CareApp(controller: controller));
    for (var i = 0; i < 100 && !drive.uploadCompleted!.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    expect(drive.uploaded, hasLength(1));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
