import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as data;
import 'package:timezone/timezone.dart' as tz;

void main() {
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
