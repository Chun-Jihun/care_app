import 'package:flutter/material.dart';

import 'accessible_image.dart';

import '../domain/knowledge.dart';

/// Offline evidence viewer. Resolves a pinned citation before showing any text.
/// Used by development discovery and by separately authorized medical citations.
class KnowledgeDocumentPage extends StatefulWidget {
  const KnowledgeDocumentPage({
    super.key,
    required this.reader,
    required this.citation,
    this.reviewed = false,
  });
  final KnowledgeReviewReader reader;
  final KnowledgeCitation citation;
  final bool reviewed;
  @override
  State<KnowledgeDocumentPage> createState() => _KnowledgeDocumentPageState();
}

class _KnowledgeDocumentPageState extends State<KnowledgeDocumentPage> {
  late Future<KnowledgeDocument> _document;
  bool _showPage = false;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _document = widget.reader.resolve(widget.citation);
  }

  @override
  void didUpdateWidget(KnowledgeDocumentPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.citation != widget.citation ||
        oldWidget.reader != widget.reader) {
      _document = widget.reader.resolve(widget.citation);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _move(KnowledgeDocument document, int page) {
    setState(() {
      _document = widget.reader.document(document.source.id, page);
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('근거 문서 확인')),
    body: SafeArea(
      child: FutureBuilder<KnowledgeDocument>(
        future: _document,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '근거의 버전이나 내용을 확인할 수 없습니다.\n일치하는 원본 패키지를 다시 확인해 주세요.',
                  key: Key('knowledge-error'),
                ),
              ),
            );
          }
          final document = snapshot.requireData;
          final source = document.source;
          final page = document.citation.pageNumber;
          final excerpt = document.citation.excerpt;
          return ListView(
            controller: _scroll,
            padding: const EdgeInsets.all(20),
            children: [
              Text(source.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                widget.reviewed
                    ? '답변에 사용한 원문 · 표시된 버전과 위치를 확인하세요.'
                    : '개발용 자료 · 임상 검수 전 · 의료 답변에 사용하지 않음',
              ),
              Text('발행기관: ${source.publisher}'),
              Text('발행·개정일: ${source.publicationDate ?? '확인 대기'}'),
              Text('앱 내부 검수일: ${source.reviewDate ?? '미검수'}'),
              Text('원본 파일 기준 $page / ${source.pageCount}쪽'),
              SelectableText('원문 링크: ${source.url}', minLines: 2),
              ExpansionTile(
                title: const Text('문서 버전 확인'),
                children: [
                  SelectableText(
                    '원문: ${source.version}\n패키지: ${document.citation.packageHash}\n본문: ${document.citation.textHash}',
                    minLines: 2,
                  ),
                ],
              ),
              if (excerpt != null) ...[
                const SizedBox(height: 12),
                const Text('인용한 구절'),
                Container(
                  padding: const EdgeInsets.all(12),
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  child: SelectableText(
                    excerpt,
                    key: const Key('knowledge-excerpt'),
                    minLines: 2,
                  ),
                ),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: page > 1
                        ? () => _move(document, page - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                    label: const Text('이전 쪽'),
                  ),
                  TextButton.icon(
                    onPressed: page < source.pageCount
                        ? () => _move(document, page + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                    label: const Text('다음 쪽'),
                  ),
                ],
              ),
              if (document.pageImage != null) ...[
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('본문 텍스트')),
                    ButtonSegment(value: true, label: Text('원래 페이지')),
                  ],
                  selected: {_showPage},
                  onSelectionChanged: (selection) =>
                      setState(() => _showPage = selection.single),
                ),
                const SizedBox(height: 12),
                Text(
                  '${widget.reviewed ? '' : '텍스트 추출 검수 전입니다. '}표·그림·문맥은 원래 페이지와 함께 확인하세요. '
                  '페이지 이미지는 ${source.rasterDpi ?? 144} DPI이며 확대에는 한계가 있습니다.',
                ),
              ],
              const SizedBox(height: 16),
              if (_showPage && document.pageImage != null)
                AccessibleImage(
                  key: ValueKey(document.citation.textHash),
                  viewportHeight: 520,
                  maxScale: 5,
                  bytes: document.pageImage!,
                  semanticLabel: '${source.title} 원본 $page쪽',
                )
              else
                SelectableText.rich(
                  _text(document.text, document.citation, context),
                  key: const Key('knowledge-body'),
                  minLines: 2,
                ),
              for (final asset in document.assets) ...[
                const SizedBox(height: 16),
                AccessibleImage(
                  viewportHeight: 320,
                  maxScale: 5,
                  bytes: asset.bytes,
                  semanticLabel: asset.description.isEmpty
                      ? source.title
                      : asset.description,
                ),
                if (asset.description.isNotEmpty) Text(asset.description),
              ],
            ],
          );
        },
      ),
    ),
  );

  TextSpan _text(
    String text,
    KnowledgeCitation citation,
    BuildContext context,
  ) {
    final excerpt = citation.excerpt;
    if (excerpt == null) return TextSpan(text: text);
    final start = citation.excerptStart;
    if (start == null || start < 0 || start + excerpt.length > text.length) {
      return TextSpan(text: text);
    }
    return TextSpan(
      children: [
        TextSpan(text: text.substring(0, start)),
        TextSpan(
          text: excerpt,
          style: TextStyle(
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
            fontWeight: FontWeight.bold,
          ),
        ),
        TextSpan(text: text.substring(start + excerpt.length)),
      ],
    );
  }
}
