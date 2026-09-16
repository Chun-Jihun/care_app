import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> acknowledgeChatNotice(WidgetTester tester) async {
  expect(find.byKey(const ValueKey('chatAiNotice')), findsOneWidget);
  expect(find.byKey(const ValueKey('chat_input')), findsNothing);
  expect(tester.takeException(), isNull);
  await tester.tap(find.byKey(const ValueKey('chatAiNoticeAccept')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('chatAiNotice')), findsNothing);
}
