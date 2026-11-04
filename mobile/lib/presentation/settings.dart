import 'contact_action.dart';
export 'contact_action.dart' show contactCard;
import 'language_picker.dart';
import 'checkin_history_page.dart';
import 'ai_settings.dart';
import 'app_lock_settings.dart';
import 'display_settings_page.dart';
import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import 'common.dart';
import 'editors.dart';
import 'draft_page.dart';
import 'backup_page.dart';

List<Widget> settingsContent(BuildContext context, CareController c) => [
  Section(context.tr('화면과 사용 방법')),
  Card(
    child: ListTile(
      leading: const Icon(Icons.accessibility_new),
      title: Text(context.tr('화면·접근성 설정')),
      subtitle: Text(context.tr('글자·대비·큰 버튼·저사양 모드·홈 표시')),
      trailing: const Icon(Icons.chevron_right),
      onTap: c.busy
          ? null
          : () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => DisplaySettingsPage(c)),
            ),
    ),
  ),
  LanguagePicker(c),
  Section(context.tr('내 수첩 설정')),
  Text(context.tr('기록은 이 기기에 암호화해 보관됩니다.'), style: TextStyle(color: forest)),
  Section(
    context.tr('돌봄 대상'),
    action: context.tr('수첩 추가'),
    onAction: c.busy ? null : () => editPatient(context, c),
  ),
  ...c.patients.map(
    (p) => Card(
      child: ListTile(
        leading: Icon(
          p.id == c.selectedId ? Icons.check_circle : Icons.person_outline,
          color: forest,
        ),
        title: Text(context.strings.patient(p)),
        subtitle: Text(
          '${{'self': context.tr('환자 본인'), 'family': context.tr('가족'), 'cohabitant': context.tr('동거인'), 'caregiver': context.tr('간병인')}[p.role]!} · ${context.tr('수첩 정보 수정')}',
        ),
        onTap: c.busy ? null : () => editPatient(context, c, patient: p),
        trailing: IconButton(
          tooltip: context.tr('수첩 삭제'),
          icon: const Icon(Icons.delete_outline),
          onPressed: c.busy
              ? null
              : () async {
                  if (await confirm(
                        context,
                        context.tr('{0} 수첩을 삭제할까요?', [
                          context.strings.patient(p),
                        ]),
                        context.tr(
                          '이 수첩의 모든 기록, 약 목록, 일정, 사진, 진료 준비와 식별정보가 삭제됩니다. 따로 내보낸 백업은 삭제되지 않습니다.',
                        ),
                      ) &&
                      context.mounted) {
                    await attempt(context, () async {
                      await c.profiles.deletePatient(p.id);
                    });
                  }
                },
        ),
      ),
    ),
  ),
  Section(context.tr('잠금과 알림')),
  Card(
    child: Column(
      children: [
        SwitchListTile(
          title: Text(context.tr('일정·복약 확인 알림')),
          subtitle: Text(context.tr('잠금 화면에 약 이름이나 기록 내용을 표시하지 않아요.')),
          value: c.notificationsEnabled,
          onChanged: c.busy
              ? null
              : (v) => attempt(context, () => c.enableNotifications(v)),
        ),
        if (c.hasImportedReminderPolicy(c.selectedId!))
          SwitchListTile(
            title: Text(context.tr('복원한 이 수첩의 알림 허용')),
            subtitle: Text(
              context.tr('약 목록과 할 일의 시각을 검토한 뒤 켜 주세요. 전체 알림 설정도 켜져 있어야 합니다.'),
            ),
            value: c.importedRemindersEnabled(c.selectedId!),
            onChanged: c.busy
                ? null
                : (v) => attempt(context, () async {
                    await c.setImportedRemindersEnabled(c.selectedId!, v);
                  }),
          ),
        AppLockSettings(c),
      ],
    ),
  ),
  Section(context.tr('초안 보관')),
  Card(
    child: ListTile(
      leading: const Icon(Icons.edit_note, color: forest),
      title: Text(context.tr('작성 중인 초안과 보관기간')),
      subtitle: Text(context.tr(c.drafts.retention?.label ?? '처음 기록할 때 선택해요.')),
      trailing: const Icon(Icons.chevron_right),
      onTap: c.busy
          ? null
          : () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => DraftPage(c)),
            ),
    ),
  ),
  Section(
    context.tr('돌보는 나'),
    action: context.tr('상태 기록'),
    onAction: c.busy ? null : () => addCheckin(context, c),
  ),
  if (c.patient.role == 'self')
    Text(context.tr('이 항목은 간병인 자신의 상태를 따로 보관해요. 환자 본인의 상태는 일기에 기록해 주세요.')),
  Card(
    child: ListTile(
      leading: const Icon(Icons.favorite_outline, color: forest),
      title: Text(context.tr('돌보는 나의 상태')),
      subtitle: Text(context.tr('수면, 피로, 스트레스와 필요한 도움을 따로 기록할 수 있어요.')),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => CheckinHistoryPage(c))),
    ),
  ),
  Section(context.tr('백업과 복원')),
  Card(
    child: Column(
      children: [
        ListTile(
          leading: const Icon(Icons.lock_outline, color: forest),
          title: Text(context.tr('암호화 백업 저장')),
          subtitle: Text(context.tr('수첩·기간·사진·대화·내 상태를 선택')),
          trailing: const Icon(Icons.chevron_right),
          onTap: c.busy ? null : () => backupFlow(context, c),
        ),
        ListTile(
          leading: const Icon(Icons.restore, color: forest),
          title: Text(context.tr('백업에서 복원')),
          subtitle: Text(context.tr('선택 백업은 별도 수첩으로 추가')),
          trailing: const Icon(Icons.chevron_right),
          onTap: c.busy ? null : () => restoreFlow(context, c),
        ),
      ],
    ),
  ),
  Text(
    context.tr(
      '앱 삭제나 기기 분실에 대비해 백업을 별도로 보관해 주세요. 백업 비밀번호를 잊으면 복원할 수 없습니다. 현재 버전은 첨부 사진 합계 50MB까지 백업을 지원합니다.',
    ),
    style: TextStyle(fontSize: 14, height: 1.6, color: Color(0xFF52655A)),
  ),
  Section(context.tr('연락처')),
  contactCard(context, c),
  Card(
    child: ListTile(
      leading: const Icon(Icons.tune),
      title: Text(context.tr('AI·근거자료 관리')),
      trailing: const Icon(Icons.chevron_right),
      onTap: c.busy ? null : () => openAiSettings(context, c),
    ),
  ),
  const SizedBox(height: 28),
  Center(
    child: Text(
      context.tr('간병수첩 0.1.0 · 직접 기록하는 돌봄'),
      style: TextStyle(color: Color(0xFF52655A)),
    ),
  ),
  TextButton(
    onPressed: c.busy
        ? null
        : () async {
            if (await confirm(
                  context,
                  context.tr('이 기기의 데이터를 모두 삭제할까요?'),
                  context.tr(
                    '모든 수첩, 사진, 약 목록, 일정, 내 상태 기록과 잠금 설정을 삭제합니다. 이 작업은 되돌릴 수 없습니다. 따로 저장한 백업은 남아 있습니다.',
                  ),
                  action: context.tr('모두 삭제'),
                ) &&
                context.mounted) {
              await attempt(context, c.deleteAll);
            }
          },
    child: Text(context.tr('모든 데이터 삭제')),
  ),
];
