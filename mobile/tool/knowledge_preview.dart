// Separate development entry point. Never imported by the production app.
// flutter run -t tool/knowledge_preview.dart --dart-define=CARE_KNOWLEDGE_PREVIEW_PATH=<directory>
import 'dart:convert';

import 'package:care_notebook/domain/knowledge.dart';
import 'package:care_notebook/infrastructure/knowledge_package.dart';
import 'package:care_notebook/presentation/knowledge_document_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

void main() {
  if (kReleaseMode) {
    throw StateError('Development preview cannot run in release mode.');
  }
  runApp(const MaterialApp(home: KnowledgePreview()));
}

class KnowledgePreview extends StatefulWidget {
  const KnowledgePreview({super.key});
  @override
  State<KnowledgePreview> createState() => _KnowledgePreviewState();
}

class _KnowledgePreviewState extends State<KnowledgePreview> {
  final _path = TextEditingController(
    text: const String.fromEnvironment('CARE_KNOWLEDGE_PREVIEW_PATH'),
  );
  final _query = TextEditingController();
  LocalKnowledgePackage? _reader;
  List<KnowledgeSource> _sources = [];
  List<KnowledgeHit> _hits = [];
  List<Map<String, Object?>> _drugs = [];
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _path.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _work(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        setState(() => _error = '자료를 읽을 수 없습니다. 경로·패키지 버전과 무결성을 확인하세요.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() => _work(() async {
    setState(() {
      _reader = null;
      _sources = [];
      _hits = [];
      _drugs = [];
    });
    final reader = await LocalKnowledgePackage.openForReview(_path.text.trim());
    final sources = await reader.sources();
    if (mounted) {
      setState(() {
        _reader = reader;
        _sources = sources;
      });
    }
  });

  Future<void> _search() => _work(() async {
    final reader = _reader!;
    if (reader.kind == 'documents') {
      final hits = await reader.searchDocuments(_query.text);
      if (mounted) setState(() => _hits = hits);
    } else {
      final rows = await reader.lookupDrug(_query.text.trim());
      if (mounted) setState(() => _drugs = rows);
    }
  });

  Future<void> _showSource(KnowledgeSource source) => _work(() async {
    final page = await _reader!.document(source.id, 1);
    if (mounted) _show(page.citation);
  });

  void _show(KnowledgeCitation citation) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          KnowledgeDocumentPage(reader: _reader!, citation: citation),
    ),
  );

  Future<void> _showDrug(Map<String, Object?> row) => _work(() async {
    final record = await _reader!.drugRecord(row['id'] as int);
    final source = _sources.firstWhere((s) => s.id == row['source_id']);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('약물 원문 레코드')),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: SelectableText(
              '개발용 · 미검수 · 조회 결과로 병용 가능 여부를 판단하지 않습니다.\n'
              '${_reader!.coverageNotice}\n'
              '${source.title}\n${source.publisher}\n${source.url}\n버전: ${source.version}\n'
              'API 페이지 ${row['page_no']} · 행 ${row['row_no']}\n'
              '${const JsonEncoder.withIndent('  ').convert(record)}',
            ),
          ),
        ),
      ),
    );
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('오프라인 근거 · 개발용 미리보기')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '임상·이용허락 검수 전 자료입니다. 의료 답변이나 치료 판단에 사용할 수 없습니다. '
            '자료를 기기에서만 읽으며 원문 링크에 자동 접속하지 않습니다.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _path,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: '패키지 폴더 경로'),
          ),
          FilledButton(
            onPressed: _busy ? null : _open,
            child: const Text('무결성 검사 후 열기'),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          if (_reader != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_reader!.coverageNotice),
            ),
            TextField(
              controller: _query,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: _reader!.kind == 'documents'
                    ? '원문 언어로 검색'
                    : '품목기준코드로 조회',
              ),
              onSubmitted: (_) {
                if (!_busy) _search();
              },
            ),
            FilledButton(
              onPressed: _busy ? null : _search,
              child: const Text('오프라인 조회'),
            ),
            Text(
              _reader!.kind == 'documents'
                  ? '검색 결과 ${_hits.length}건 · 최대 30건'
                  : '조회 결과 ${_drugs.length}건 · 최대 20건\n결과가 없어도 안전하다는 뜻이 아닙니다.',
            ),
            for (final hit in _hits)
              ListTile(
                title: Text(hit.title),
                subtitle: Text('${hit.citation.pageNumber}쪽'),
                trailing: const Icon(Icons.description_outlined),
                onTap: () => _show(hit.citation),
              ),
            for (final row in _drugs)
              ListTile(
                title: Text('${row['item_seq']} → ${row['counterpart_seq']}'),
                subtitle: Text('${row['source_id']}'),
                onTap: _busy ? null : () => _showDrug(row),
              ),
            const Divider(),
            const Text('포함된 출처'),
            for (final source in _sources)
              ListTile(
                title: Text(source.title),
                subtitle: Text(
                  '${source.publisher} · ${source.pageCount}쪽 · 미검수',
                ),
                onTap: _busy || source.pageCount == 0
                    ? null
                    : () => _showSource(source),
              ),
          ],
        ],
      ),
    ),
  );
}
