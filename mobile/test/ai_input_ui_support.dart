import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> acceptAiInputNotice(WidgetTester tester) async {
  await tester.pumpAndSettle();
  expect(find.text('AI 인식 사용 전 확인해 주세요'), findsOneWidget);
  await tester.tap(find.widgetWithText(FilledButton, '확인하고 시작'));
}

Future<void> cancelAiInputNotice(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, '취소'),
    ),
  );
  await tester.pumpAndSettle();
}
