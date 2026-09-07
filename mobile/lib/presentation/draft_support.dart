import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/drafts.dart';
import '../infrastructure/care_database.dart';
import 'common.dart';

Future<bool> chooseDraftRetention(
  BuildContext context,
  CareController c, {
  bool onlyIfUnset = false,
}) async {
  if (onlyIfUnset && c.db.draftRetention != null) return true;
  final current = c.db.draftRetention;
  final choice = await showDialog<DraftRetention>(
    context: context,
    useRootNavigator: false,
    builder: (ctx) => SimpleDialog(
      title: const Text('초안을 얼마나 보관할까요?'),
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            '일기·약·복약·할 일·진료 준비·내 상태의 작성 중 내용을 기기에 암호화해 보관합니다. 기간은 마지막 자동 저장부터 계산하며 설정에서 바꿀 수 있어요.',
          ),
        ),
        for (final value in DraftRetention.values)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, value),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('${value.label}${value == current ? ' (현재)' : ''}'),
            ),
          ),
      ],
    ),
  );
  if (choice == null || !context.mounted || !c.unlocked) return false;
  if (current != null && choice != current && choice.days != null) {
    if (!await confirm(
      context,
      '초안 보관기간을 바꿀까요?',
      '새 기간을 지난 초안은 삭제됩니다. 이미 확정한 기록에는 영향을 주지 않습니다.',
      action: '변경',
    )) {
      return false;
    }
  }
  await c.mutate(() => c.db.setDraftRetention(choice));
  return true;
}
