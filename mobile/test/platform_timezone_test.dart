import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:care_notebook/infrastructure/platform_services.dart';
import 'package:timezone/data/latest_all.dart' as data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('REVIEW-03 native scheduling preserves pending due alarms and updates only changes', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final calls = <MethodCall>[];
    final pending = <int>{10, 30};
    messenger.setMockMethodCallHandler(
      DevicePlatformServices.privacy,
      (_) async => 'UTC',
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'initialize':
          return true;
        case 'pendingNotificationRequests':
          return pending
              .map(
                (id) => {
                  'id': id,
                  'title': '간병수첩',
                  'body': '',
                  'payload': null,
                },
              )
              .toList();
        case 'cancel':
          pending.remove(call.arguments['id']);
          return null;
        case 'cancelAll':
          pending.clear();
          return null;
        case 'zonedSchedule':
          pending.add(call.arguments['id'] as int);
          return null;
        default:
          return null;
      }
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(DevicePlatformServices.privacy, null);
    });
    final platform = DevicePlatformServices();
    final now = DateTime.now();
    final reminders = [
      Reminder(10, now.subtract(const Duration(seconds: 30))),
      Reminder(20, now.add(const Duration(hours: 1))),
    ];
    await platform.schedule(reminders);
    expect(pending, {10, 20});
    expect(calls.where((c) => c.method == 'cancelAll'), isEmpty);
    expect(calls.where((c) => c.method == 'cancel').single.arguments['id'], 30);
    await platform.schedule(reminders);
    expect(calls.where((c) => c.method == 'zonedSchedule'), hasLength(1));
    await platform.schedule([]);
    expect(pending, isEmpty);
  });
  test(
    'Android default GMT and Korean timezone resolve without a fallback',
    () {
      data.initializeTimeZones();
      expect(tz.getLocation('GMT').currentTimeZone.offset, Duration.zero);
      expect(
        tz.getLocation('Asia/Seoul').currentTimeZone.offset,
        const Duration(hours: 9),
      );
    },
  );
}
