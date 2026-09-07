import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/backup.dart';
import '../domain/records.dart';
import '../infrastructure/care_database.dart';
import 'common.dart';

String backupCounts(Map<String, int> counts) => [
  for (final e in const {
    'patient_context': '수첩',
    'care_entry': '간병일기',
    'medication': '약 목록',
    'medication_plan': '처방 이력',
    'care_task': '할 일',
    'visit_preparation': '진료 준비',
    'attachment': '사진',
    'chat_message': '보관한 대화',
    'caregiver_checkin': '돌보는 나의 상태',
  }.entries)
    '${e.value} ${counts[e.key] ?? 0}개',
].join('\n');

Future<void> backupFlow(BuildContext context, CareController c) async {
  final a = TextEditingController(), b = TextEditingController();
  final selected = <String>{c.selectedId!};
  DateTimeRange? range;
  var photos = true, chats = false, checkins = false, identities = false;
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (ctx) => EditorPage(
          title: '암호화 백업 저장',
          saveLabel: '백업 범위 확인',
          content: (update) => [
            const Text(
              '선택한 내용을 비밀번호로 암호화해 파일로 저장합니다. 초안과 잠금·알림 설정은 포함하지 않습니다.',
            ),
            const Section('백업할 수첩'),
            for (final patient in c.patients)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(patient.label),
                value: selected.contains(patient.id),
                onChanged: (v) => update(() {
                  if (v == true) {
                    selected.add(patient.id);
                  } else {
                    selected.remove(patient.id);
                  }
                }),
              ),
            const Section('기록 기간'),
            OutlinedButton.icon(
              icon: const Icon(Icons.date_range),
              label: Text(
                range == null
                    ? '전체 기간'
                    : '${dateText(range!.start)} ~ ${dateText(range!.end)}',
              ),
              onPressed: () async {
                final value = await showDateRangePicker(
                  context: ctx,
                  useRootNavigator: false,
                  initialDateRange: range,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100, 12, 31),
                  helpText: '백업할 기록 기간',
                  saveText: '기간 선택',
                );
                if (value != null && ctx.mounted) update(() => range = value);
              },
            ),
            if (range != null)
              TextButton(
                onPressed: () => update(() => range = null),
                child: const Text('전체 기간으로 변경'),
              ),
            const Text(
              '기간은 일기의 기록 시각·할 일의 예정일·진료 준비 및 대화의 작성일·내 상태의 기록일에 적용합니다. 수첩 배경과 약 목록·처방 이력, 선택한 기록의 수정 이력은 기간과 관계없이 함께 포함합니다. 진료 준비에서 기간 밖 원본은 제외하고 재검토 표시를 남깁니다.',
            ),
            const Section('함께 담을 정보'),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('선택한 기록의 사진'),
              value: photos,
              onChanged: (v) => update(() => photos = v!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('보관한 대화'),
              subtitle: const Text('보관 안 하는 대화와 만료된 대화는 포함하지 않아요.'),
              value: chats,
              onChanged: (v) => update(() => chats = v!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('돌보는 나의 상태'),
              subtitle: const Text('환자와 분리된 내 상태 기록이에요.'),
              value: checkins,
              onChanged: (v) => update(() => checkins = v!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('별칭·의료기관 연락처'),
              subtitle: const Text(
                '제외하면 복원한 수첩에 별칭을 다시 정할 수 있어요. 메모에 직접 적은 이름은 자동으로 지워지지 않습니다.',
              ),
              value: identities,
              onChanged: (v) => update(() => identities = v!),
            ),
            const Section('백업 비밀번호'),
            const Text('기기 잠금 번호와 다른 12자 이상의 비밀번호를 정해 주세요. 잊으면 복원할 수 없습니다.'),
            textField(a, '백업 비밀번호 (12자 이상)', secret: true),
            textField(b, '백업 비밀번호 확인', secret: true),
          ],
          save: () async {
            if (a.text.length < 12) {
              throw const CareError('백업 비밀번호는 12자 이상으로 입력해 주세요.');
            }
            if (a.text != b.text) throw const CareError('두 비밀번호가 일치하지 않습니다.');
            final selection = BackupSelection(
              patientIds: selected,
              from: range?.start,
              until: range == null
                  ? null
                  : DateTime(
                      range!.end.year,
                      range!.end.month,
                      range!.end.day + 1,
                    ),
              photos: photos,
              chats: chats,
              checkins: checkins,
              identities: identities,
            );
            final counts = c.db
                .selectBackup(selection)
                .map((k, v) => MapEntry(k, v.length));
            final ok = await confirm(
              ctx,
              '이 범위로 백업할까요?',
              '${backupCounts(counts)}\n\n별칭·연락처 ${identities ? '포함' : '제외'}\n초안 제외',
              action: '암호화하고 저장 위치 선택',
            );
            if (!ok || !ctx.mounted) throw const EditorCancelled();
            await c.exportSelection(a.text, selection);
          },
        ),
      ),
    );
  } finally {
    a.dispose();
    b.dispose();
  }
}

Future<void> restoreFlow(BuildContext context, CareController c) async {
  await attempt(context, () async {
    final data = await c.chooseBackup();
    if (data == null || !context.mounted) return;
    final password = TextEditingController();
    BackupPreview? preview;
    try {
      await pushPage(
        context,
        MaterialPageRoute<void>(
          builder: (_) => EditorPage(
            title: '백업 확인',
            saveLabel: '비밀번호 확인과 내용 보기',
            content: (_) => [
              const Text(
                '백업을 저장할 때 정한 비밀번호를 입력해 주세요. 다음 화면에서 복원할 내용을 확인할 수 있어요.',
              ),
              textField(password, '백업 비밀번호', secret: true),
            ],
            save: () async {
              preview = await c.inspectBackup(data, password.text);
            },
          ),
        ),
      );
      if (preview == null || !context.mounted || !c.unlocked) return;
      final legacy = preview!.legacy;
      final ok = await confirm(
        context,
        legacy ? '이전 형식의 전체 백업입니다' : '별도 수첩으로 추가할까요?',
        legacy
            ? '이 백업은 현재 기기의 모든 수첩과 초안을 교체하는 이전 형식입니다. 현재 기록이 필요하면 취소하고 먼저 백업해 주세요. 검증에 실패하면 현재 기록을 유지합니다. 잠금 번호는 유지됩니다.'
            : '${backupCounts(preview!.counts)}\n\n기존 수첩·초안은 유지하고 이름에 (복원)을 붙인 별도 수첩으로 추가합니다. 같은 백업의 중복 추가는 차단합니다. 복원한 수첩의 알림은 약과 할 일을 검토한 뒤 설정에서 켜 주세요. 대화의 원래 만료일은 유지됩니다.',
        action: legacy ? '현재 수첩 전체 교체' : '수첩 추가 복원',
      );
      if (!ok || !context.mounted) return;
      if (legacy) {
        await c.restoreBackup(data, password.text);
      } else {
        await c.importSelection(data, password.text);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              legacy ? '백업으로 교체했습니다.' : '수첩을 추가했습니다. 수첩 전환에서 확인해 주세요.',
            ),
          ),
        );
      }
    } finally {
      password.dispose();
    }
  });
}
