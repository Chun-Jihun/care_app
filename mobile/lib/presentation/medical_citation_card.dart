import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/knowledge.dart';
import '../l10n/app_strings.dart';
import 'knowledge_document_page.dart';

/// Never display the saved excerpt until the original version resolves again.
class MedicalCitationCard extends StatefulWidget {
  const MedicalCitationCard(this.c, this.pid, this.citation, {super.key});
  final CareController c;
  final String pid;
  final KnowledgeCitation citation;
  @override
  State<MedicalCitationCard> createState() => _MedicalCitationCardState();
}

class _MedicalCitationCardState extends State<MedicalCitationCard> {
  late Future<(KnowledgeReviewReader, KnowledgeDocument)?> _source = _load();
  Future<(KnowledgeReviewReader, KnowledgeDocument)?> _load() async {
    final reader = await widget.c.medicalAnswers?.reader(widget.citation);
    if (reader == null) return null;
    final doc = await reader.resolve(widget.citation);
    if (doc.source.reviewDate == null || doc.source.publicationDate == null) {
      return null;
    }
    return (reader, doc);
  }

  @override
  void didUpdateWidget(MedicalCitationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.c != widget.c ||
        oldWidget.pid != widget.pid ||
        oldWidget.citation != widget.citation) {
      _source = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.c.unlocked || widget.c.selectedId != widget.pid) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<(KnowledgeReviewReader, KnowledgeDocument)?>(
      future: _source,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const LinearProgressIndicator();
        }
        final result = snapshot.data;
        if (snapshot.hasError || result == null) {
          return Text(context.tr('당시 근거를 확인할 수 없어 발췌를 표시하지 않습니다.'));
        }
        final (reader, doc) = result;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${doc.source.title} · ${doc.citation.pageNumber}'),
                Text(doc.source.publisher),
                SelectableText(doc.citation.excerpt!),
                TextButton.icon(
                  icon: const Icon(Icons.find_in_page_outlined),
                  label: Text(context.tr('원문 위치 확인')),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => KnowledgeDocumentPage(
                        reader: reader,
                        citation: widget.citation,
                        reviewed: true,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
