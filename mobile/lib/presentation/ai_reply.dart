import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/ai.dart';
import '../domain/medical_evidence.dart';
import 'lookup_results_page.dart';
import '../l10n/app_strings.dart';
import 'ai_evidence_page.dart';
import 'ai_record_source.dart';
import 'common.dart';
import 'settings.dart';
import 'medical_citation_card.dart';

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
                    AiReplyKind.clarify => '“어제 약 먹었어?”, “오늘 물 마신 기록”처럼 날짜와 항목을 알려 주세요. 이어서 “그럼 어제는?”처럼 물어볼 수 있어요. 조회는 최대 31일이며, 저녁처럼 모호한 시각은 오후 6시처럼 적어 주세요.',
                    AiReplyKind.medicalHold => switch (reply.evidenceHold) {
                      EvidenceHold.insufficient =>
                        '이 질문에 충분한 검수 근거를 찾지 못해 답변을 보류합니다. 의료진에게 확인해 주세요.',
                      EvidenceHold.conflicting =>
                        '근거가 서로 일치하는지 확인할 수 없어 답변을 보류합니다. 의료진에게 확인해 주세요.',
                      EvidenceHold.expired =>
                        '근거의 검수 기한이 지나 답변을 보류합니다. 새 자료 또는 의료진의 확인이 필요합니다.',
                      EvidenceHold.invalid =>
                        '답변과 원문 근거의 일치를 확인하지 못해 답변을 보류합니다.',
                      EvidenceHold.restricted =>
                        '약의 병용·용량·중단이나 치료 변경은 안내할 수 없습니다. 의료진 또는 약사에게 확인해 주세요.',
                      _ => '검수된 의료 근거가 아직 연결되지 않아 이 질문에는 답변할 수 없어요. 약의 병용·변경이나 치료 판단은 의료진 또는 약사에게 확인해 주세요.',
                    },
                    AiReplyKind.urgent => '위급한 상황이라면 앱 답변을 기다리지 말고 즉시 의료기관이나 현지 응급전화에 연락해 주세요. 대한민국에서는 119입니다.',
                    AiReplyKind.notebookScope =>
                      '현재 선택한 수첩의 기록만 조회할 수 있어요. 필요한 수첩으로 전환한 뒤 질문해 주세요.',
                    AiReplyKind.unavailable => '기기 AI를 실행하지 못했어요. 설정에서 모델 설치 상태와 기기 저장 공간을 확인해 주세요. 질문은 선택한 보관 방식으로 남겼습니다.',
                    AiReplyKind.evidence =>
                      '검수된 근거의 원문 발췌입니다. 환자별 처방과 의료진 지시가 우선합니다.',
                  }),
                ),
                if (reply.lookup case final lookup?) ...[
                  const SizedBox(height: 8),
                  LookupScopeView(lookup),
                  TextButton.icon(
                    onPressed: () => pushPage(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => LookupResultsPage(c, pid, lookup),
                      ),
                    ),
                    icon: const Icon(Icons.list_alt),
                    label: Text(context.tr('같은 조건으로 전체 기록 보기')),
                  ),
                ],
                if (reply.hasMore)
                  Text(context.tr('최근 8개를 표시했어요. 전체 기록 보기에서 나머지도 확인할 수 있습니다.')),
                if (reply.kind == AiReplyKind.urgent) contactCard(context, c),
                for (final (index, source) in reply.sources.indexed)
                  AiRecordSource(c, pid, source, number: index + 1),
                for (final citation in reply.citations)
                  MedicalCitationCard(c, pid, citation),
              ],
            ),
          ),
        ),
      );
    },
  );
}
