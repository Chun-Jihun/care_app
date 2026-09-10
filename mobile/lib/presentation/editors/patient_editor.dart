import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../application/care_controller.dart';
import '../../domain/records.dart';
import '../common.dart';

Future<void> editPatient(
  BuildContext context,
  CareController c, {
  Patient? patient,
}) async {
  final alias = TextEditingController(text: patient?.alias),
      details = TextEditingController(text: patient?.context),
      contact = TextEditingController(text: patient?.contact);
  var role = patient?.role ?? 'family';
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (_) => EditorPage(
          title: patient == null ? context.tr('수첩 추가') : context.tr('돌봄 대상 수정'),
          content: (update) => [
            Text(
              context.tr('이름 없이 시작해도 괜찮아요. 여러 사람을 돌본다면 구분하기 쉬운 별칭을 적어 주세요.'),
            ),
            textField(alias, context.tr('이름 또는 별칭 (선택)')),
            DropdownButtonFormField<String>(
              isExpanded: true,
              itemHeight: null,
              initialValue: role,
              decoration: InputDecoration(
                labelText: context.tr('나는 어떤 역할인가요?'),
              ),
              items: [
                DropdownMenuItem(
                  value: 'self',
                  child: Text(context.tr('환자 본인')),
                ),
                DropdownMenuItem(
                  value: 'family',
                  child: Text(context.tr('가족')),
                ),
                DropdownMenuItem(
                  value: 'cohabitant',
                  child: Text(context.tr('동거인')),
                ),
                DropdownMenuItem(
                  value: 'caregiver',
                  child: Text(context.tr('간병인')),
                ),
              ],
              onChanged: (v) => role = v!,
            ),
            textField(
              details,
              context.tr('돌봄에 필요한 배경 (선택)'),
              multiline: true,
              hint: context.tr('알레르기, 생활 습관, 의료진에게 전달받은 주의사항 등'),
            ),
            textField(contact, context.tr('의료기관 연락처 (선택)')),
          ],
          save: () async {
            if (patient == null) {
              final created = await c.profiles.createPatient(
                alias: alias.text,
                role: role,
                context: details.text,
                contact: contact.text,
              );
              await c.selectPatient(created.id);
            } else {
              await c.profiles.updatePatient(
                patient.id,
                alias: alias.text,
                role: role,
                context: details.text,
                contact: contact.text,
              );
            }
          },
        ),
      ),
    );
  } finally {
    alias.dispose();
    details.dispose();
    contact.dispose();
  }
}
