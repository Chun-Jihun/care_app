import 'dart:async';
import 'dart:convert';

import 'package:care_notebook/application/services/daily_widget_service.dart';
import 'package:care_notebook/domain/daily_widget.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/l10n/app_strings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class DelayedWidgetPlatform extends FakePlatform {
  final started = Completer<void>();
  final release = Completer<void>();
  final published = <DailyWidgetSnapshot?>[];
  @override
  Future<void> updateDailyWidget(DailyWidgetSnapshot? snapshot) async {
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
    published.add(snapshot);
  }
}

void main() {
  final now = DateTime(2026, 11, 4, 10);
  const strings = AppStrings(AppLanguage.korean);
  CareEntry intake(String status, DateTime date) => CareEntry(
    id: 'synthetic-entry',
    patientId: 'synthetic-patient',
    kind: EntryKind.medicationIntake,
    occurredAt: date,
    offsetMinutes: 540,
    note: 'PRIVATE NOTE',
    fields: {'status': status},
    version: 1,
  );

  test(
    'widget projects entered schedules without inventing future intake records',
    () {
      final snapshot = DailyWidgetSnapshot.build(
        now: now,
        tasks: [
          CareTask(
            'old',
            'old',
            'PRIVATE',
            DateTime(2026, 11, 3),
            false,
            false,
          ),
          CareTask(
            'today',
            'today',
            '',
            DateTime(2026, 11, 4, 10, 20),
            false,
            false,
          ),
          CareTask('done', 'done', '', DateTime(2026, 11, 4, 11), true, false),
          CareTask(
            'tomorrow',
            'tomorrow',
            '',
            DateTime(2026, 11, 5, 12),
            false,
            false,
          ),
        ],
        medications: [
          Medication(
            'active',
            'PRIVATE DRUG',
            'PRIVATE INSTRUCTION',
            ['09:00', '11:00'],
            true,
            'plan',
            1,
          ),
          Medication('inactive', 'archived', '', ['12:00'], false, 'plan', 1),
        ],
        entries: [
          intake('taken', now),
          intake('unknown', now),
          intake('taken', DateTime(2026, 11, 3)),
          intake('taken', DateTime(2026, 11, 5)),
        ],
        strings: strings,
        details: false,
      );
      final days = snapshot.toJson()['days'] as List;
      expect(days, hasLength(7));
      expect(days[0]['pending'], 1);
      expect(days[0]['overdue'], 1);
      expect(days[0]['intakes'], 1);
      expect(days[0]['events'], hasLength(2));
      expect(days[1]['pending'], 1);
      expect(days[1]['overdue'], 2);
      expect(days[1]['intakes'], isNull);
      expect(jsonEncode(snapshot.toJson()), isNot(contains('PRIVATE')));
      // Consumers cannot mutate the next publication through a shallow map.
      days[0]['pending'] = 999;
      expect((snapshot.toJson()['days'] as List)[0]['pending'], 1);
    },
  );

  test(
    'long and numerous schedule titles are bounded without hiding truncation',
    () {
      final snapshot = DailyWidgetSnapshot.build(
        now: now,
        tasks: [
          for (var i = 0; i < 45; i++)
            CareTask(
              '$i',
              '합성\n${List.filled(100, '가😀').join()}',
              'PRIVATE NOTE',
              DateTime(2026, 11, 4, 11, i),
              false,
              false,
            ),
        ],
        medications: [],
        entries: [],
        strings: strings,
        details: true,
      );
      final today = (snapshot.toJson()['days'] as List)[0];
      expect(today['pending'], 45);
      expect(today['events'], hasLength(32));
      expect(today['more'], isTrue);
      final title = (today['events'] as List).first['text'] as String;
      expect(title.runes.length, lessThanOrEqualTo(40));
      expect(title, endsWith('…'));
      expect(title, isNot(contains('\n')));
      expect(
        utf8.encode(jsonEncode(snapshot.toJson())).length,
        lessThanOrEqualTo(65536),
      );
    },
  );

  test('revoking a widget clears a delayed publication and skips superseded writes', () async {
    final snapshot = DailyWidgetSnapshot.build(
      now: now,
      tasks: [],
      medications: [],
      entries: [],
      strings: strings,
      details: false,
    );
    final platform = DelayedWidgetPlatform();
    final service = DailyWidgetService(platform);
    final running = service.update(snapshot);
    await platform.started.future;
    final superseded = service.update(snapshot);
    final revoke = service.update(null);
    platform.release.complete();
    await Future.wait([running, superseded, revoke]);
    expect(platform.published, [snapshot, null]);
    await service.update(snapshot);
    expect(platform.published.last, snapshot);
  });
}
