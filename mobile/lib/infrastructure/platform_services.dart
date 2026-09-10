import '../l10n/app_strings.dart';

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:local_auth_darwin/local_auth_darwin.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart' hide AndroidOptions;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
// Native OS identifiers can use IANA aliases (for example Android's GMT).
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../domain/records.dart';
import '../application/ports.dart';
import 'vault_store.dart';
export '../application/ports.dart' show PlatformServices, Reminder;

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

class DevicePlatformServices extends PlatformServices {
  static const privacy = MethodChannel('org.carenotebook/privacy');
  final _notifications = FlutterLocalNotificationsPlugin();
  bool _notificationsReady = false;
  AppLanguage? _channelLanguage;
  final _scheduled = <int, String>{};
  @override
  Future<String> timeZone() async {
    final zone = await privacy.invokeMethod<String>('timeZone');
    if (zone == null) throw CareError(CareErrorCode.timeZoneUnavailable);
    return zone;
  }

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
    try {
      return await auth.authenticate(
        localizedReason: strings.text('간병수첩의 기록을 열기 위해 인증해 주세요.'),
        authMessages: [
          AndroidAuthMessages(
            cancelButton: strings.text('취소'),
            signInTitle: strings.text('간병수첩'),
            signInHint: strings.text('지문·얼굴 또는 기기 잠금으로 인증'),
          ),
          IOSAuthMessages(cancelButton: strings.text('취소')),
        ],
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException {
      // Cancellation, unavailable credentials and OS lockout never unlock the
      // vault. The caller keeps the app PIN fallback and shows an auth message.
      return false;
    }
  }

  Future<void> _initializeNotifications() async {
    if (_notificationsReady) {
      return;
    }
    tz_data.initializeTimeZones();
    final zone = await timeZone();
    tz.setLocalLocation(tz.getLocation(zone));
    await _notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
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
    final zone = await timeZone();
    tz.setLocalLocation(tz.getLocation(zone));
    if (reminders.isEmpty) {
      await _notifications.cancelAll();
      _scheduled.clear();
      return;
    }
    if (_channelLanguage != strings.language) {
      await _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            AndroidNotificationChannel(
              'care_reminders',
              strings.text('간병 일정'),
              description: strings.text('사용자가 설정한 일정과 복약 확인'),
              importance: Importance.defaultImportance,
            ),
          );
      _channelLanguage = strings.language;
    }
    final pending = (await _notifications.pendingNotificationRequests())
        .map((r) => r.id)
        .toSet();
    final now = DateTime.now();
    final future = reminders.where((r) => r.at.isAfter(now)).take(60).toList();
    // An inexact alarm may be due but not delivered yet. Keep it until it fires
    // unless the user completes, disables or removes that specific task.
    final retained = {
      ...future.map((r) => r.id),
      ...reminders
          .where((r) => !r.daily && !r.at.isAfter(now))
          .map((r) => r.id),
    };
    for (final id in {...pending, ..._scheduled.keys}.difference(retained)) {
      await _notifications.cancel(id: id);
      _scheduled.remove(id);
    }
    for (final reminder in future) {
      final signature = reminder.daily
          ? '${strings.language.code}:$zone:daily:${reminder.at.hour}:${reminder.at.minute}'
          : '${strings.language.code}:$zone:${reminder.at.millisecondsSinceEpoch}';
      if (pending.contains(reminder.id) &&
          _scheduled[reminder.id] == signature) {
        continue;
      }
      await _notifications.zonedSchedule(
        id: reminder.id,
        scheduledDate: tz.TZDateTime.from(reminder.at, tz.local),
        title: strings.text('간병수첩'),
        body: strings.text('확인할 일정이 있어요. 수첩을 열어 확인해 주세요.'),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'care_reminders',
            strings.text('간병 일정'),
            channelDescription: strings.text('사용자가 설정한 일정과 복약 확인'),
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
      _scheduled[reminder.id] = signature;
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
        throw CareError(CareErrorCode.photoTooLarge);
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
      dialogTitle: strings.text('암호화 백업 저장'),
      fileName:
          'care-notebook-${DateTime.now().toIso8601String().substring(0, 10)}.carebackup',
      type: FileType.any,
      bytes: data,
    );
    if (result == null) {
      throw CareError(CareErrorCode.backupSaveCancelled);
    }
  }

  @override
  Future<Uint8List?> pickBackup() async {
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: strings.text('간병수첩 백업 선택'),
        type: FileType.any,
      );
      if (file == null) {
        return null;
      }
      if (await file.length() > VaultStore.maxBackupBytes + 128) {
        throw CareError(CareErrorCode.backupFileTooLarge);
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
