import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../application/care_controller.dart';
import '../../domain/records.dart';
import '../common.dart';
import '../details.dart';
import '../editors.dart';

List<Widget> visitContent(BuildContext context, CareController c) => [
  Section(context.tr('진료를 준비해요')),
  Text(
    context.tr('물어볼 질문과 보여줄 기록을 한곳에 모아 두세요.'),
    style: TextStyle(color: Color(0xFF68796E), height: 1.5),
  ),
  const SizedBox(height: 16),
  if (c.visits.isEmpty)
    EmptyCard(
      context.tr('진료실에서 기억하기 쉽도록'),
      context.tr('직접 고른 기록의 원문을 질문 목록과 함께 볼 수 있어요.'),
      icon: Icons.assignment_outlined,
    ),
  ...c.visits.map(
    (v) => Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: const Icon(Icons.assignment_outlined, color: forest),
        title: Text(v.title),
        subtitle: Text(
          v.stale
              ? context.tr('원본이 변경되었어요 · 다시 검토해 주세요')
              : v.questions.isEmpty
              ? context.tr('선택한 기록을 확인하세요')
              : v.questions,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => VisitDetails(c, c.selectedId!, v.id),
          ),
        ),
      ),
    ),
  ),
  Section(context.tr('진료 후 남기기')),
  Card(
    child: ListTile(
      leading: const Icon(Icons.edit_note, color: forest),
      title: Text(context.tr('의료진의 설명과 다음 할 일')),
      subtitle: Text(context.tr('들은 내용을 직접 기록해 두세요.')),
      trailing: const Icon(Icons.add),
      onTap: () => editEntry(context, c, EntryKind.medicalContact),
    ),
  ),
];
