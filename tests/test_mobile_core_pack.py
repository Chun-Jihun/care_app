import json
import tempfile
import unittest
from pathlib import Path

from scripts.build_document_knowledge_pack import add_page
from scripts.build_mobile_core_pack import build_documents, project_permit
from scripts.knowledge_pack import PackError, PackReader, PackWriter
from scripts.mobile_core_policy import CORE_DOCUMENTS
from scripts.packed_drugs import PackedDrugWriter, encode_ids, decode_ids


class MobileCoreTests(unittest.TestCase):
    def test_delta_index_keeps_large_distances_and_rejects_invalid_tails(self):
        numbers = [1, 128, 129, 16384, 857362]
        self.assertEqual(list(decode_ids(encode_ids(numbers))), numbers)
        for raw in (b'\x80', b'\x00', b'\x01\x80', b'\xff' * 6):
            with self.assertRaises(PackError): list(decode_ids(raw))
        with self.assertRaises(PackError): encode_ids([1, 1])

    def test_packed_rows_preserve_variants_directions_and_source_locations_across_groups(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'pack'
            writer = PackWriter(path, 'drugs', packed=True)
            writer.source('synthetic', {'title': 'Not medical'})
            writer.source('second', {'title': 'Not medical either'})
            packed = PackedDrugWriter(writer)
            records = []
            for n in range(700):
                item = {'ITEM_SEQ': 'A', 'MIXTURE_ITEM_SEQ': 'A' if n == 0 else f'B{n}',
                        'ITEM_NAME': 'Synthetic', 'PROHBT_CONTENT': '0.5 미만. 단, 예외 조건을 지킨다.',
                        'REMARK': '중복 조건도 보존', 'CHART': f'variant{n%3}',
                        'MIXTURE_CHART': f'counterpart{n%5}', 'ZERO': 0, 'NULL': None,
                        'EMPTY': '', 'nested': [True, {'number': n}]}
                records.append(item)
                packed.add('synthetic' if n < 600 else 'second', item, 1 + n//100, n%100)
            packed.finish()
            m = writer.finish({'coverage': {'notice_ko': '시험용 미검수'}})
            reader = PackReader(path)
            try:
                for n, record in enumerate(records):
                    self.assertEqual(reader.drug(n+1), record)
                self.assertEqual(m['stats']['roundtrip_verified_records'], 700)
                self.assertEqual(len(reader.lookup('A', limit=100)), 100)
                hit = reader.lookup('B650')[0]
                self.assertEqual((hit['id'],hit['source_id'],hit['page_no'],hit['row_no']), (651,'second',7,50))
                self.assertEqual([h['id'] for h in reader.lookup('A', limit=5)], [1,2,3,4,5])
                self.assertEqual(reader.lookup('missing'), [])
                with self.assertRaises(PackError): reader.drug(701)
                with self.assertRaises(PackError): reader.clinical_context('anything')
            finally:
                reader.close()

    def test_basic_permit_keeps_identity_ingredients_and_cancel_status(self):
        raw = {'ITEM_SEQ': '001', 'ITEM_NAME': 'Synthetic', 'ITEM_INGR_NAME': 'ingredient',
               'CANCEL_NAME': 'cancelled', 'CANCEL_DATE': '20250101', 'BIZRNO': 'removed', 'EDI_CODE': 'removed'}
        result = project_permit(raw)
        self.assertEqual(result, {k: v for k,v in raw.items() if k not in ('BIZRNO','EDI_CODE')})
        with self.assertRaises(PackError): project_permit(dict(raw, UNKNOWN_FIELD='must review'))

    def test_core_copies_complete_caregiver_documents_and_excludes_professional_book(self):
        with tempfile.TemporaryDirectory() as temp:
            full, output = Path(temp)/'full', Path(temp)/'core'
            writer = PackWriter(full, 'documents')
            for name in CORE_DOCUMENTS | {'Nursing Assistant.pdf'}:
                writer.source(name, {'path': 'docs/'+name, 'title': name})
                add_page(writer, name, 1, 'Synthetic context. Keep conditions and exceptions.', b'synthetic-image')
                add_page(writer, name, 2, 'Second page; do not truncate.')
            writer.finish()
            m = build_documents(full, output)
            self.assertEqual(m['document_count'], 13)
            self.assertFalse(m['coverage']['prescription_details_included'])
            reader = PackReader(output)
            try:
                self.assertEqual(reader.db.execute('SELECT count(*) FROM document_pages').fetchone()[0], 26)
                self.assertEqual(reader.db.execute("SELECT count(*) FROM sources WHERE id='Nursing Assistant.pdf'").fetchone()[0], 0)
                for row in reader.db.execute('SELECT * FROM document_pages WHERE page_no=1'):
                    self.assertEqual(reader.blob(row['image_blob']), b'synthetic-image')
            finally:
                reader.close()


if __name__ == '__main__':
    unittest.main()
