import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/ai.dart';
import '../l10n/app_strings.dart';
import 'ai_record_source.dart';
import 'common.dart';
import 'medical_citation_card.dart';

/// Resolves source IDs against the selected notebook, never against model prose.
class AiEvidencePage extends StatelessWidget {
  const AiEvidencePage(this.c, this.pid, this.reply, {super.key});
  final CareController c;
  final String pid;
  final AiReply reply;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      if (!c.unlocked || c.selectedId != pid) return const SizedBox.shrink();
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('답변의 근거'))),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Section(context.tr('참고한 내 기록')),
              Text(context.tr('아래 내용은 내 수첩의 기록이며, 검수된 의료 문서가 아닙니다.')),
              if (reply.sources.isEmpty)
                Text(context.tr('이 답변은 수첩 기록을 인용하지 않았습니다.')),
              for (final (index, source) in reply.sources.indexed)
                AiRecordSource(
                  c,
                  pid,
                  source,
                  number: index + 1,
                  detailed: true,
                ),
              Section(context.tr('의료 근거 문서')),
              if (reply.citations.isEmpty)
                Text(
                  context.tr(
                    '검수된 의료 문서가 아직 연결되지 않았습니다. 의료 문서를 인용한 답변은 제공하지 않습니다.',
                  ),
                ),
              for (final citation in reply.citations)
                MedicalCitationCard(c, pid, citation),
            ],
          ),
        ),
      );
    },
  );
}
