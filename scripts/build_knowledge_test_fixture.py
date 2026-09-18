"""Generate a small cross-language fixture containing only synthetic content."""
import base64
import argparse
import json
import tempfile
from pathlib import Path

from scripts.build_document_knowledge_pack import add_page
from scripts.build_drug_knowledge_pack import add_record
from scripts.knowledge_pack import PackWriter, open_readonly
from scripts.packed_drugs import PackedDrugWriter


def build(packed=False):
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp) / 'pack'
        writer = PackWriter(directory, 'drugs' if packed else 'documents', packed=packed)
        writer.source('synthetic', {'title': 'Synthetic guide', 'publisher': 'Test publisher',
                                   'url': 'https://example.invalid/fixture', 'source_sha256': 'test-version',
                                   'publication_or_revision_date': '2020-01-01', 'clinical_reviewed_at': None})
        add_page(writer, 'synthetic', 1, '합성 자료입니다. 조건과 예외를 그대로 확인합니다.\nSynthetic condition only.')
        add_page(writer, 'synthetic', 2, 'Synthetic second page. Never infer safety.')
        record = {'ITEM_SEQ': 'TEST-1', 'MIXTURE_ITEM_SEQ': 'TEST-2', 'ITEM_NAME': 'Synthetic product',
                  'CONDITION': '검사용 예외 조건. 0.5 미만일 때만.\n' * 3000,
                  'EMPTY': '', 'NULL': None, 'ZERO': 0, 'UNICODE': '😀é\u2028終',
                  'STRUCTURE': [True, {'x': 'y'}]}
        if packed:
            encoder = PackedDrugWriter(writer)
            encoder.add('synthetic', record, 2, 3)
            for n in range(600):
                encoder.add('synthetic', {'ITEM_SEQ': f'ALT{n}', 'MIXTURE_ITEM_SEQ': f'ALT{n-n%2}',
                    'ITEM_NAME': f'Variant {n}', 'PROHBT_CONTENT': '합성 조건. 예외를 제거하지 않습니다.'}, 1+n//100, n%100)
            encoder.finish()
        else:
            add_record(writer, 'synthetic', record, 2, 3)
        manifest = writer.finish({'coverage': {'notice_ko': '합성 시험용 자료', 'prescription_details_included': False}} if packed else None)
        db = open_readonly(directory / 'knowledge.sqlite3')
        try:
            tables = ('metadata', 'blobs', 'sources', 'drug_records', 'document_pages', 'page_assets')
            if packed:
                tables += ('value_groups', 'record_groups', 'drug_lookup')
            schema = [r[0] for r in db.execute("SELECT sql FROM sqlite_schema WHERE type='table' "
                                              "AND name NOT LIKE 'document_search_%' ORDER BY rowid")]
            rows = {}
            for table in tables:
                rows[table] = [{k: {'base64': base64.b64encode(v).decode()} if isinstance(v, bytes) else v
                                for k, v in dict(r).items()} for r in db.execute(f'SELECT * FROM {table}')]
            result = {'notice': 'Synthetic test-only fixture; contains no medical or patient data.',
                      'schema': schema, 'tables': rows, 'manifest': manifest, 'expected_record': record,
                      'search_rows': [[1, 'Synthetic condition only.'], [2, 'Synthetic second page.']]}
            # Expected long value is reproducible without duplicating it in the fixture.
            result['expected_record']['CONDITION'] = {'repeat': '검사용 예외 조건. 0.5 미만일 때만.\n', 'times': 3000}
            target = Path('mobile/test/fixtures/knowledge_pack_v2.json' if packed else 'mobile/test/fixtures/knowledge_pack_v1.json')
            target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        finally:
            db.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packed', action='store_true')
    build(parser.parse_args().packed)
