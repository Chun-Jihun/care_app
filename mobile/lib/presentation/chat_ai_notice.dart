import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';

Future<bool> showChatAiNotice(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      barrierDismissible: false,
      builder: (_) => const ChatAiNotice(),
    ) ??
    false;

class ChatAiNotice extends StatelessWidget {
  const ChatAiNotice({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('chatAiNotice'),
    scrollable: true,
    icon: const Icon(Icons.info_outline),
    title: Text(context.tr('AI 대화 이용 전 확인해 주세요')),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr(
            'AI는 내용을 잘못 이해하거나 틀린 답변을 할 수 있어요. 중요한 내용은 원본 기록과 근거를 확인해 주세요.',
          ),
        ),
        const SizedBox(height: 16),
        Text(
          context.tr(
            '이 도우미는 의료진을 대신하지 않으며 진단·처방·치료 결정을 제공하지 않습니다. 약의 복용·중단·용량 변경이나 다른 약·건강보조제와 함께 먹는 문제는 의료진 또는 약사에게 확인해 주세요.',
          ),
        ),
        const SizedBox(height: 16),
        Text(
          context.tr(
            '증상이 갑자기 심해지거나 응급상황이라면 대화를 기다리지 말고 의료기관이나 현지 응급전화에 연락해 주세요. 대한민국에서는 119입니다.',
          ),
        ),
        const SizedBox(height: 16),
        Text(
          context.tr(
            '현재는 수첩 기록 조회를 지원합니다. 검수된 의료 문서가 연결되기 전까지 의료 질문에는 답변하지 않습니다.',
          ),
        ),
      ],
    ),
    actionsOverflowButtonSpacing: 8,
    actions: [
      TextButton(
        key: const ValueKey('chatAiNoticeCancel'),
        onPressed: () => Navigator.pop(context, false),
        child: Text(context.tr('돌아가기')),
      ),
      FilledButton(
        key: const ValueKey('chatAiNoticeAccept'),
        onPressed: () => Navigator.pop(context, true),
        child: Text(context.tr('확인하고 대화 시작')),
      ),
    ],
  );
}
