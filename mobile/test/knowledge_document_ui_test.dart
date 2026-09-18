import 'package:care_notebook/domain/knowledge.dart';
import 'package:care_notebook/presentation/knowledge_document_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const citation = KnowledgeCitation(
  packageHash: 'fixture-package',
  sourceId: 'synthetic',
  pageNumber: 1,
  textHash: 'fixture-text',
  excerpt: '정확한 인용 구절',
  excerptStart: 7,
);

class FakeReader implements KnowledgeReviewReader {
  bool fail = false;
  @override
  String get kind => 'documents';
  @override
  String get packageHash => 'fixture-package';
  @override
  Future<List<KnowledgeSource>> sources() async => [];
  @override
  Future<List<KnowledgeHit>> searchDocuments(String query) async => [];
  @override
  Future<KnowledgeDocument> document(String id, int pageNumber) async =>
      _page(pageNumber);
  @override
  Future<KnowledgeDocument> resolve(KnowledgeCitation citation) async {
    if (fail) throw const KnowledgePackageException('fixture error');
    return _page(1, citation: citation);
  }

  KnowledgeDocument _page(int page, {KnowledgeCitation? citation}) =>
      KnowledgeDocument(
        source: const KnowledgeSource(
          id: 'synthetic',
          title: '합성 시험 문서',
          publisher: '시험 발행기관',
          url: 'https://example.invalid',
          version: 'fixture-version',
          pageCount: 2,
        ),
        citation:
            citation ??
            KnowledgeCitation(
              packageHash: packageHash,
              sourceId: 'synthetic',
              pageNumber: page,
              textHash: 'p$page',
            ),
        text: page == 1 ? '앞뒤 문맥과 정확한 인용 구절을 함께 봅니다.' : '두 번째 쪽의 조건과 예외입니다.',
      );
}

void main() {
  testWidgets(
    'narrow screen shows source, excerpt, full context and neighboring page',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: KnowledgeDocumentPage(reader: FakeReader(), citation: citation),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('합성 시험 문서'), findsOneWidget);
      expect(find.text('발행기관: 시험 발행기관'), findsOneWidget);
      expect(find.byKey(const Key('knowledge-excerpt')), findsOneWidget);
      await tester.ensureVisible(find.text('다음 쪽'));
      await tester.tap(find.text('다음 쪽'));
      await tester.pumpAndSettle();
      expect(find.text('원본 파일 기준 2 / 2쪽'), findsOneWidget);
      expect(find.byKey(const Key('knowledge-excerpt')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed citation does not display unverified text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: KnowledgeDocumentPage(
          reader: FakeReader()..fail = true,
          citation: citation,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('knowledge-error')), findsOneWidget);
    expect(find.byKey(const Key('knowledge-body')), findsNothing);
  });
}
