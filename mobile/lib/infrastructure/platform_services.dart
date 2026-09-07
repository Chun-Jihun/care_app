import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart' hide AndroidOptions;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../domain/records.dart';
import 'vault_store.dart';

class DeviceSecretStore implements SecretStore {
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
  );
  @override
  Future<String?> read(String key) => _storage.read(key: 'care.$key');
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: 'care.$key', value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: 'care.$key');
}

abstract class PlatformServices {
  Future<bool> authenticate() => Future.value(false);
  Future<bool> requestNotifications() => Future.value(false);
  Future<void> schedule(List<Reminder> reminders) async {}
  Future<Uint8List?> pickPhoto({bool camera = false}) async => null;
  Future<void> saveBackup(Uint8List data) async {}
  Future<Uint8List?> pickBackup() async => null;
  Future<void> dial(String number) async {}
}

class Reminder {
  const Reminder(this.id, this.at, {this.daily = false});
  final int id;
  final DateTime at;
  final bool daily;
}

class DevicePlatformServices extends PlatformServices {
  static const privacy = MethodChannel('org.carenotebook/privacy');
  final _notifications = FlutterLocalNotificationsPlugin();
  bool _notificationsReady = false;
  static Future<Directory> prepareDirectory() async {
    final root = await Directory(
      p.join((await getApplicationSupportDirectory()).path, 'care-vault'),
    ).create(recursive: true);
    await privacy.invokeMethod<void>('protectDirectory', {'path': root.path});
    if (Platform.isAndroid) {
      await ImagePicker().retrieveLostData();
    }
    await cleanupPickerImages();
    return root;
  }

  /// Native pickers stage images in the app's private cache. Never touch originals.
  static Future<void> cleanupPickerImages() async {
    final temp = await getTemporaryDirectory();
    await for (final file in temp.list(recursive: true, followLinks: false)) {
      if (file is File &&
          p.isWithin(temp.path, file.path) &&
          [
            '.jpg',
            '.jpeg',
            '.png',
            '.heic',
            '.heif',
          ].contains(p.extension(file.path).toLowerCase())) {
        await file.delete();
      }
    }
  }

  @override
  Future<bool> authenticate() async {
    final auth = LocalAuthentication();
    if (!await auth.isDeviceSupported()) {
      return false;
    }
    return auth.authenticate(
      localizedReason: '간병수첩의 기록을 열기 위해 인증해 주세요.',
      persistAcrossBackgrounding: true,
    );
  }

  Future<void> _initializeNotifications() async {
    if (_notificationsReady) {
      return;
    }
    tz_data.initializeTimeZones();
    final zone = await privacy.invokeMethod<String>('timeZone');
    if (zone == null) {
      throw const CareError('기기 시간대를 확인할 수 없습니다.');
    }
    tz.setLocalLocation(tz.getLocation(zone));
    await _notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_notification'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    _notificationsReady = true;
  }

  @override
  Future<bool> requestNotifications() async {
    await _initializeNotifications();
    if (Platform.isAndroid) {
      return await _notifications
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
    }
    return await _notifications
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: false, sound: true) ??
        false;
  }

  @override
  Future<void> schedule(List<Reminder> reminders) async {
    await _initializeNotifications();
    final zone = await privacy.invokeMethod<String>('timeZone');
    if (zone != null) {
      tz.setLocalLocation(tz.getLocation(zone));
    }
    await _notifications.cancelAll();
    for (final reminder in reminders.take(60)) {
      await _notifications.zonedSchedule(
        id: reminder.id,
        scheduledDate: tz.TZDateTime.from(reminder.at, tz.local),
        title: '간병수첩',
        body: '확인할 일정이 있어요. 수첩을 열어 확인해 주세요.',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'care_reminders',
            '간병 일정',
            channelDescription: '사용자가 설정한 일정과 복약 확인',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            visibility: NotificationVisibility.secret,
          ),
          iOS: DarwinNotificationDetails(presentBadge: false),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: reminder.daily
            ? DateTimeComponents.time
            : null,
      );
    }
  }

  @override
  Future<Uint8List?> pickPhoto({bool camera = false}) async {
    final photo = await ImagePicker().pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      requestFullMetadata: false,
    );
    if (photo == null) {
      return null;
    }
    try {
      if (await photo.length() > 20 * 1024 * 1024) {
        throw const CareError('사진은 20MB 이하로 선택해 주세요.');
      }
      return await photo.readAsBytes();
    } finally {
      final temp = await getTemporaryDirectory();
      if (p.isWithin(temp.path, photo.path)) {
        final f = File(photo.path);
        if (await f.exists()) {
          await f.delete();
        }
      }
    }
  }

  @override
  Future<void> saveBackup(Uint8List data) async {
    final result = await FilePicker.saveFile(
      dialogTitle: '암호화 백업 저장',
      fileName:
          'care-notebook-${DateTime.now().toIso8601String().substring(0, 10)}.carebackup',
      type: FileType.any,
      bytes: data,
    );
    if (result == null) {
      throw const CareError('백업 저장을 취소했습니다.');
    }
  }

  @override
  Future<Uint8List?> pickBackup() async {
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: '간병수첩 백업 선택',
        type: FileType.any,
      );
      if (file == null) {
        return null;
      }
      if (await file.length() > VaultStore.maxBackupBytes + 128) {
        throw const CareError('백업 파일이 너무 큽니다.');
      }
      return await file.readAsBytes();
    } finally {
      await FilePicker.clearTemporaryFiles();
    }
  }

  @override
  Future<void> dial(String number) =>
      privacy.invokeMethod<void>('dial', {'number': number});
}
