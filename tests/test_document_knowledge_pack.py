import tempfile
import unittest
from pathlib import Path

from scripts.build_document_knowledge_pack import ArticleParser, add_page, local_asset
from scripts.knowledge_pack import PackError, PackReader, PackWriter, sha


class DocumentPackTests(unittest.TestCase):
    def test_main_text_keeps_conditions_tables_and_image_references(self):
        parser = ArticleParser()
        parser.feed('<head>ignored</head><main><nav>menu</nav><h1>Title</h1><p>Do <b>not</b> change. '
                    'Only if &lt; 0.5.</p><script>ignored()</script><table><tr><th>Condition</th>'
                    '<td>Except A</td></tr></table><img src="a_files/a.png" alt="Diagram"></main>outside')
        self.assertEqual(parser.text(), 'Title\nDo not change. Only if < 0.5.\n| Condition | Except A')
        self.assertEqual(parser.images, [('a_files/a.png', 'Diagram')])

    def test_remote_missing_and_traversal_images_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            document = Path(temp) / 'a.html'
            for ref in ('https://example.test/a.png', '//example.test/a.png', '../a.png',
                        '%2e%2e/a.png', 'data:image/png;base64,AA==', 'missing.png'):
                with self.assertRaises(PackError):
                    local_asset(document, ref)

    def test_missing_main_content_does_not_silently_create_empty_document(self):
        parser = ArticleParser()
        parser.feed('<body><p>unexpected source structure</p></body>')
        with self.assertRaises(PackError):
            parser.text()

    def test_search_result_restores_exact_page_and_not_duplicate_text(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'pack'
            writer = PackWriter(path, 'documents')
            writer.source('synthetic', {'title': 'Synthetic fixture'})
            add_page(writer, 'synthetic', 3, 'Synthetic condition only. Never infer safety.')
            add_page(writer, 'synthetic', 4, 'Another page.')
            writer.finish()
            reader = PackReader(path)
            try:
                hits = reader.db.execute("SELECT rowid,text FROM document_search WHERE document_search MATCH ?",
                                         ('"condition"',)).fetchall()
                self.assertEqual(len(hits), 1)
                self.assertIsNone(hits[0]['text'])
                row = reader.db.execute('SELECT * FROM document_pages WHERE id=?', (hits[0]['rowid'],)).fetchone()
                self.assertEqual(row['page_no'], 3)
                self.assertEqual(reader.blob(row['text_blob']).decode(), 'Synthetic condition only. Never infer safety.')
                self.assertEqual(sha(reader.blob(row['text_blob'])), row['text_sha256'])
            finally:
                reader.close()


if __name__ == '__main__':
    unittest.main()
