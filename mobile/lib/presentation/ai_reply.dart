import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/ai.dart';
import '../domain/record_lookup.dart';
import '../l10n/app_strings.dart';
import 'ai_evidence_page.dart';
import 'ai_record_source.dart';
import 'common.dart';
import 'settings.dart';

class AiReplyView extends StatelessWidget {
  const AiReplyView(this.c, this.pid, this.reply, {super.key});
  final CareController c;
  final String pid;
  final AiReply reply;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      if (!c.unlocked || c.selectedId != pid) return const SizedBox.shrink();
      return Align(
        alignment: Alignment.centerLeft,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      context.tr('간병 도우미'),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: forest,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => pushPage(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => AiEvidencePage(c, pid, reply),
                        ),
                      ),
                      icon: const Icon(Icons.find_in_page_outlined),
                      label: Text(context.tr('근거 보기')),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  context.tr(switch (reply.kind) {
                    AiReplyKind.records =>
                      '선택한 수첩에서 찾은 기록입니다. 기록 내용은 의료적 판단이 아닙니다.',
                    AiReplyKind.noRecords =>
                      '일치하는 기록을 찾지 못했어요. 기록이 없다는 것이 실제로 하지 않았다는 뜻은 아닙니다.',
                    AiReplyKind.clarify => '한국어로 “어제 복약 기록”, “이번 주 식사 기록”, “최근 7일 수분 기록”처럼 물어보세요. 특정 항목은 이름을 큰따옴표로 감싸 주세요. 조회는 최대 31일이며, 시각이 필요하면 09:30처럼 적어 주세요.',
                    AiReplyKind.medicalHold => '검수된 의료 근거가 아직 연결되지 않아 이 질문에는 답변할 수 없어요. 약의 병용·변경이나 치료 판단은 의료진 또는 약사에게 확인해 주세요.',
                    AiReplyKind.urgent => '위급한 상황이라면 앱 답변을 기다리지 말고 즉시 의료기관이나 현지 응급전화에 연락해 주세요. 대한민국에서는 119입니다.',
                    AiReplyKind.notebookScope =>
                      '현재 선택한 수첩의 기록만 조회할 수 있어요. 필요한 수첩으로 전환한 뒤 질문해 주세요.',
                    AiReplyKind.unavailable => '기기 AI를 실행하지 못했어요. 설정에서 모델 설치 상태와 기기 저장 공간을 확인해 주세요. 질문은 선택한 보관 방식으로 남겼습니다.',
                  }),
                ),
                if (reply.lookup case final lookup?) ...[
                  const SizedBox(height: 8),
                  Text(
                    context.tr('조회 기간: {0} ~ {1}', [
                      RecordLookup.date(lookup.start),
                      RecordLookup.date(
                        DateTime(
                          lookup.end.year,
                          lookup.end.month,
                          lookup.end.day - 1,
                        ),
                      ),
                    ]),
                  ),
                  if (lookup.fromMinute != 0 || lookup.untilMinute != 1440)
                    Text(
                      context.tr('조회 시각: {0}', [
                        '${(lookup.fromMinute ~/ 60).toString().padLeft(2, '0')}:${(lookup.fromMinute % 60).toString().padLeft(2, '0')}',
                      ]),
                    ),
                  Text(
                    context.tr('조회 항목: {0}', [
                      lookup.item.isNotEmpty
                          ? lookup.item
                          : context.tr(
                              lookup.requiredField == 'water_ml'
                                  ? '수분 (mL)'
                                  : lookup.kind?.label ?? '전체',
                            ),
                    ]),
                  ),
                ],
                if (reply.hasMore)
                  Text(
                    context.tr(
                      '일치하는 기록 중 최근 8개를 표시했어요. 나머지는 기간이나 시각을 좁혀 조회해 주세요.',
                    ),
                  ),
                if (reply.kind == AiReplyKind.urgent) contactCard(context, c),
                for (final (index, source) in reply.sources.indexed)
                  AiRecordSource(c, pid, source, number: index + 1),
              ],
            ),
          ),
        ),
      );
    },
  );
}
