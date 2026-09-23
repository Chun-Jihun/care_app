import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../application/knowledge_search.dart';
import '../domain/knowledge.dart';
import '../domain/knowledge_installation.dart';
import '../l10n/app_strings.dart';
import 'knowledge_document_page.dart';

class KnowledgeSettings extends StatefulWidget {
  const KnowledgeSettings(this.c, {super.key});
  final CareController c;
  @override
  State<KnowledgeSettings> createState() => _KnowledgeSettingsState();
}

class _KnowledgeSettingsState extends State<KnowledgeSettings> {
  late Future<KnowledgeInstallation> _status = _load();
  bool _working = false;
  double _progress = 0;
  bool _error = false;
  bool _installing = false, _cancelled = false;
  Future<KnowledgeInstallation> _load() async =>
      await widget.c.knowledge?.status() ?? const KnowledgeInstallation();

  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = false;
      _cancelled = false;
      _progress = 0;
    });
    try {
      await action();
    } on Object {
      if (mounted && !_cancelled) setState(() => _error = true);
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _installing = false;
          _status = _load();
        });
      }
    }
  }

  Future<void> _install() async {
    _cancelled = false;
    _installing = true;
    await widget.c.installKnowledge(
      (v) {
        if (mounted) setState(() => _progress = v);
      },
      checkCancelled: () {
        if (!mounted || _cancelled) throw StateError('Installation cancelled');
      },
    );
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('의료 근거 자료'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(context.tr('검수된 자료가 준비되면 기기에 저장해 오프라인으로 사용합니다.')),
          FutureBuilder<KnowledgeInstallation>(
            future: _status,
            builder: (context, snapshot) {
              final s = snapshot.data;
              final active = s?.active;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (snapshot.connectionState != ConnectionState.done)
                    const LinearProgressIndicator(),
                  if (snapshot.hasError || s?.damaged == true)
                    Text(context.tr('자료 무결성을 확인하지 못했습니다. 답변에는 사용하지 않습니다.')),
                  if (snapshot.connectionState == ConnectionState.done &&
                      !snapshot.hasError &&
                      s?.damaged != true &&
                      active == null)
                    Text(context.tr('설치된 근거 자료가 없습니다.')),
                  if (snapshot.hasError)
                    TextButton(
                      onPressed: _working
                          ? null
                          : () => setState(() => _status = _load()),
                      child: Text(context.tr('다시 시도')),
                    ),
                  if (active != null) ...[
                    Text(
                      '${active.version} · ${(active.payloadBytes / 1048576).toStringAsFixed(2)} MiB',
                    ),
                    Text(
                      context.tr(
                        active.preview
                            ? '개발용 미검수 자료 · 의료 답변 사용 불가'
                            : '검수 상태 확인 필요',
                      ),
                    ),
                    if (active.stale(DateTime.now()))
                      Text(context.tr('자료의 재확인 기한이 지났습니다. 새 버전을 확인해 주세요.')),
                    if (kDebugMode && s?.damaged != true)
                      TextButton(
                        onPressed: _working
                            ? null
                            : () => _run(() async {
                                final reader = await widget.c.knowledge
                                    ?.reader();
                                if (reader != null && context.mounted) {
                                  await Navigator.of(context).push<void>(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          KnowledgeSearchPage(reader),
                                    ),
                                  );
                                }
                              }),
                        child: Text(context.tr('개발용 문서 검색')),
                      ),
                  ],
                  if (widget.c.knowledge != null && kDebugMode)
                    OutlinedButton.icon(
                      onPressed: _working ? null : () => _run(_install),
                      icon: const Icon(Icons.folder_open),
                      label: Text(context.tr('근거 자료 파일 선택')),
                    ),
                  if (s?.previous != null)
                    TextButton(
                      onPressed: _working
                          ? null
                          : () => _run(() async {
                              await widget.c.knowledge!.rollback();
                            }),
                      child: Text(context.tr('이전 자료 버전으로 복구')),
                    ),
                ],
              );
            },
          ),
          if (_working)
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
          if (_working && _installing)
            TextButton(
              onPressed: _cancelled || _progress >= 1
                  ? null
                  : () {
                      if (_progress < 1) setState(() => _cancelled = true);
                    },
              child: Text(context.tr('취소')),
            ),
          if (!_working && _cancelled)
            Text(context.tr('자료 설치를 취소했습니다. 기존 자료는 유지됩니다.')),
          if (_error) Text(context.tr('자료 작업을 완료하지 못했습니다. 기존 자료는 유지됩니다.')),
          Text(context.tr('새 자료와 이전 버전을 함께 보관하므로 설치 중 추가 공간이 필요합니다.')),
        ],
      ),
    ),
  );
}

/// Debug discovery only. Search results never become clinical authorization.
class KnowledgeSearchPage extends StatefulWidget {
  const KnowledgeSearchPage(this.reader, {super.key});
  final KnowledgeReviewReader reader;
  @override
  State<KnowledgeSearchPage> createState() => _KnowledgeSearchPageState();
}

class _KnowledgeSearchPageState extends State<KnowledgeSearchPage> {
  final _query = TextEditingController();
  Future<List<KnowledgeSearchResult>>? _results;
  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('개발용 문서 검색'))),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(context.tr('개발용 미검수 자료 · 의료 답변 사용 불가')),
          TextField(
            controller: _query,
            maxLength: 1200,
            decoration: InputDecoration(
              labelText: context.tr('찾고 싶은 내용을 입력하세요'),
            ),
            onSubmitted: (_) => _search(),
          ),
          FilledButton(onPressed: _search, child: Text(context.tr('검색'))),
          if (_results != null)
            FutureBuilder<List<KnowledgeSearchResult>>(
              future: _results,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const LinearProgressIndicator();
                }
                if (snapshot.hasError) {
                  return Text(
                    context.tr('자료 무결성을 확인하지 못했습니다. 답변에는 사용하지 않습니다.'),
                  );
                }
                final hits = snapshot.data ?? [];
                if (hits.isEmpty) {
                  return Text(context.tr('일치하는 근거가 없습니다. 안전하다는 뜻은 아닙니다.'));
                }
                return Column(
                  children: [
                    for (final hit in hits)
                      Card(
                        child: ListTile(
                          title: Text(
                            '${hit.source.title} · ${hit.citation.pageNumber}',
                          ),
                          subtitle: Text(
                            hit.citation.excerpt!,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => KnowledgeDocumentPage(
                                reader: widget.reader,
                                citation: hit.citation,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    ),
  );
  void _search() => setState(
    () => _results = KnowledgeSearch(widget.reader).search(_query.text),
  );
}
