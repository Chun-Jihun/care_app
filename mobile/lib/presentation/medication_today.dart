import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/records.dart';
import '../l10n/app_strings.dart';
import 'common.dart';

class MedicationTodayStatus extends StatelessWidget {
  const MedicationTodayStatus(this.c, this.medication, {super.key});
  final CareController c;
  final Medication medication;
  @override
  Widget build(BuildContext context) {
    final records = c.medicationBook.intakes(
      c.selectedId!,
      medication.id,
      DateTime.now(),
    );
    return Text(
      records.isEmpty
          ? context.tr('오늘 연결된 복약 기록 없음 · 복용 여부는 확인해 주세요.')
          : context.tr('오늘의 기록: {0}', [
              records
                  .map(
                    (e) =>
                        '${timeText(context, e.occurredAt)} ${context.tr(intakeLabels[e.fields['status']] ?? '확인 못함')}',
                  )
                  .join(' · '),
            ]),
    );
  }
}
