import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:care_notebook/infrastructure/platform_services.dart';
import 'package:care_notebook/l10n/app_strings.dart';
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
    final now = DateTime.now();
    final reminders = [
      Reminder(10, now.subtract(const Duration(seconds: 30))),
      Reminder(20, now.add(const Duration(hours: 1))),
    ];
    final pending = <int, String?>{
      10: reminders.first.at.millisecondsSinceEpoch.toString(),
      30: null,
    };
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
          return pending.entries
              .map(
                (request) => {
                  'id': request.key,
                  'title': '간병수첩',
                  'body': '',
                  'payload': request.value,
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
          pending[call.arguments['id'] as int] =
              call.arguments['payload'] as String?;
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
    await platform.schedule(reminders);
    expect(pending.keys.toSet(), {10, 20});
    expect(pending[20], reminders.last.at.millisecondsSinceEpoch.toString());
    expect(calls.where((c) => c.method == 'cancelAll'), isEmpty);
    expect(calls.where((c) => c.method == 'cancel').single.arguments['id'], 30);
    await platform.schedule(reminders);
    expect(calls.where((c) => c.method == 'zonedSchedule'), hasLength(1));
    final original =
        calls.where((c) => c.method == 'zonedSchedule').single.arguments as Map;
    for (final language in AppLanguage.values.skip(1)) {
      platform.strings = AppStrings(language);
      await platform.schedule(reminders);
      final next =
          calls.where((c) => c.method == 'zonedSchedule').last.arguments as Map;
      expect(next['id'], 20);
      expect(next['scheduledDateTime'], original['scheduledDateTime']);
      expect(next['title'], platform.strings.text('간병수첩'));
      expect(
        next['body'],
        platform.strings.text('확인할 일정이 있어요. 수첩을 열어 확인해 주세요.'),
      );
      expect(pending.keys.toSet(), {10, 20});
      expect(calls.where((c) => c.method == 'cancelAll'), isEmpty);
    }
    expect(calls.where((c) => c.method == 'zonedSchedule'), hasLength(5));

    final restarted = DevicePlatformServices();
    final yesterday = now.subtract(const Duration(days: 1));
    await restarted.schedule([reminders.first, Reminder(20, yesterday)]);
    expect(pending.keys, [10]);
    expect(calls.where((c) => c.method == 'cancel').last.arguments['id'], 20);

    pending[40] = null; // A request scheduled by the previous app version.
    await restarted.schedule([reminders.first, Reminder(40, yesterday)]);
    expect(pending.keys, [10]);

    await restarted.schedule([]);
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
