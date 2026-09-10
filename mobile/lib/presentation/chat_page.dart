import '../l10n/app_strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/chat.dart';
import 'common.dart';
import 'editors.dart';

class ChatPage extends StatelessWidget {
  const ChatPage(this.c, {super.key});
  final CareController c;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      if (!c.unlocked) {
        return const SizedBox.shrink();
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(context.tr('간병 도우미')),
          actions: [
            PopupMenuButton<String>(
              tooltip: context.tr('대화 수첩 전환'),
              onSelected: (id) => attempt(context, () => c.selectPatient(id)),
              itemBuilder: (_) => c.patients
                  .map(
                    (p) => PopupMenuItem(
                      value: p.id,
                      child: Text(context.strings.patient(p)),
                    ),
                  )
                  .toList(),
              icon: const Icon(Icons.people_outline),
            ),
          ],
        ),
        body: ChatBody(key: ValueKey(c.selectedId), c: c, pid: c.selectedId!),
      );
    },
  );
}

class ChatBody extends StatefulWidget {
  const ChatBody({super.key, required this.c, required this.pid});
  final CareController c;
  final String pid;
  @override
  State<ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<ChatBody> {
  final input = TextEditingController(), scroll = ScrollController();
  bool sending = false;
  int policyRevision = 0;
  Object? error;
  Timer? expiry;
  ChatRetention? policy;
  List<ChatMessage> messages = [];
  void loadMessages() {
    policy = widget.c.db.chatRetention(widget.pid);
    messages = widget.c.chatMessages(widget.pid);
  }

  @override
  void didUpdateWidget(covariant ChatBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    loadMessages();
  }

  @override
  void initState() {
    super.initState();
    loadMessages();
    expiry = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && widget.c.unlocked) {
        attempt(context, widget.c.refresh);
      }
    });
  }

  @override
  void dispose() {
    expiry?.cancel();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> setPolicy(ChatRetention value) async {
    final c = widget.c, pid = widget.pid;
    final hasMessages = c.chatMessages(pid).isNotEmpty;
    if (hasMessages &&
        !await confirm(
          context,
          context.tr('질문 보관 방식을 바꿀까요?'),
          value == ChatRetention.session
              ? context.tr('기기에 저장한 기존 질문을 삭제합니다. 새 질문은 수첩을 잠글 때 지워집니다.')
              : context.tr('기존 질문에도 새 기간을 적용합니다. 기간이 지난 질문과 임시 질문은 삭제됩니다.'),
          action: context.tr('변경'),
        )) {
      if (mounted) {
        setState(() => policyRevision++);
      }
      return;
    }
    if (mounted) {
      await attempt(context, () => c.setChatRetention(pid, value));
      if (mounted) {
        setState(() => policyRevision++);
      }
    }
  }

  Future<void> send() async {
    if (sending || input.text.trim().isEmpty) {
      return;
    }
    setState(() {
      sending = true;
      error = null;
    });
    try {
      await widget.c.addChatMessage(widget.pid, input.text);
      if (mounted) {
        input.clear();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (scroll.hasClients) {
            scroll.animateTo(
              scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e);
      }
    } finally {
      if (mounted) {
        setState(() => sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c, pid = widget.pid;
    return SafeArea(
      top: false,
      child: Column(
        children: [
          Expanded(
            child: CustomScrollView(
              controller: scroll,
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
                        color: const Color(0xFFE8EFE8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.chat_bubble_outline,
                                  color: forest,
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    context.tr('{0} · AI 연결 전', [
                                      context.strings.patient(c.patient),
                                    ]),
                                    style: const TextStyle(
                                      color: forest,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 7),
                            Text(
                              context.tr(
                                '지금은 질문을 남겨두는 대화창이에요. AI 답변은 제공되지 않으며 질문이 자동 전송되지 않아요.',
                              ),
                              style: TextStyle(height: 1.5, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<ChatRetention>(
                                key: ValueKey('$policy-$policyRevision'),
                                initialValue: policy,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: context.tr('질문 보관 방식'),
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                ),
                                items: ChatRetention.values
                                    .map(
                                      (p) => DropdownMenuItem(
                                        value: p,
                                        child: Text(context.tr(p.label)),
                                      ),
                                    )
                                    .toList(),
                                onChanged: sending
                                    ? null
                                    : (v) {
                                        if (v != null) {
                                          setPolicy(v);
                                        }
                                      },
                              ),
                            ),
                            IconButton(
                              tooltip: context.tr('모든 질문 삭제'),
                              onPressed: messages.isEmpty
                                  ? null
                                  : () async {
                                      if (await confirm(
                                            context,
                                            context.tr('이 수첩의 질문을 모두 삭제할까요?'),
                                            context.tr(
                                              '따로 저장한 진료 준비와 일기는 유지됩니다.',
                                            ),
                                          ) &&
                                          context.mounted) {
                                        await attempt(
                                          context,
                                          () => c.clearChatMessages(pid),
                                        );
                                      }
                                    },
                              icon: const Icon(Icons.delete_sweep_outlined),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                messages.isEmpty
                    ? SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            children: [
                              const SizedBox(height: 25),
                              const Icon(
                                Icons.forum_outlined,
                                size: 42,
                                color: forest,
                              ),
                              const SizedBox(height: 20),
                              Text(
                                context.tr('궁금한 점을\n잊기 전에 남겨 보세요.'),
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(
                                      height: 1.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                context.tr(
                                  '질문은 진료 준비에 옮겨 정리할 수 있어요.\n먼저 보관 방식을 선택해 주세요.',
                                ),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Color(0xFF68796E),
                                  height: 1.6,
                                ),
                              ),
                              const SizedBox(height: 20),
                              Wrap(
                                alignment: WrapAlignment.center,
                                spacing: 8,
                                runSpacing: 8,
                                children:
                                    [
                                          context.tr('약에 관한 질문'),
                                          context.tr('식사에 관한 질문'),
                                          context.tr('활동에 관한 질문'),
                                        ]
                                        .map(
                                          (text) => ActionChip(
                                            label: Text(text),
                                            onPressed: () => setState(
                                              () => input.text = '$text: ',
                                            ),
                                          ),
                                        )
                                        .toList(),
                              ),
                            ],
                          ),
                        ),
                      )
                    : SliverList.builder(
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final m = messages[index];
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Container(
                                  constraints: const BoxConstraints(
                                    maxWidth: 520,
                                  ),
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: forest,
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  child: Text(
                                    m.text,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      height: 1.5,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        context.tr('{0} {1} · 답변 없음', [
                                          dateText(context, m.createdAt),
                                          timeText(context, m.createdAt),
                                        ]),
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF68796E),
                                        ),
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: context.tr('질문 메뉴'),
                                      onSelected: (action) async {
                                        if (action == 'visit') {
                                          await editVisit(
                                            context,
                                            c,
                                            initialQuestions: m.text,
                                          );
                                        } else if (await confirm(
                                              context,
                                              context.tr('질문을 삭제할까요?'),
                                              context.tr('선택한 질문을 삭제합니다.'),
                                            ) &&
                                            context.mounted) {
                                          await attempt(
                                            context,
                                            () =>
                                                c.deleteChatMessage(pid, m.id),
                                          );
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        PopupMenuItem(
                                          value: 'visit',
                                          child: Text(context.tr('진료 준비로 정리')),
                                        ),
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: Text(context.tr('질문 삭제')),
                                        ),
                                      ],
                                      icon: const Icon(
                                        Icons.more_horiz,
                                        size: 18,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                errorText(context, error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('chat_input'),
                    controller: input,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 20000,
                    autocorrect: false,
                    enableIMEPersonalizedLearning: false,
                    enableSuggestions: false,
                    enabled: !sending,
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: policy == null
                          ? context.tr('보관 방식을 먼저 선택해 주세요')
                          : context.tr('궁금한 점을 적어 주세요'),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: context.tr('질문 남기기'),
                  onPressed:
                      policy == null || sending || input.text.trim().isEmpty
                      ? null
                      : send,
                  icon: sending
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_upward),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
