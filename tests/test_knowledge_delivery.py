import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest

from scripts.build_knowledge_delivery import build


class KnowledgeDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.manifest = {
            'schema': 'care-mobile-core-set-v1', 'purpose': 'development_preview',
            'approval_state': 'staged_unreviewed', 'clinical_review_completed': False,
            'runtime_rag_eligible': False, 'mobile_bundle': False, 'do_not_train': True,
            'packages': {},
        }
        for kind in ['dur', 'permits', 'easy-drug', 'documents']:
            folder = self.source / kind
            folder.mkdir()
            meta, database = b'{"synthetic":true}', b'SYNTHETIC-' + kind.encode()
            (folder / 'manifest.json').write_bytes(meta)
            (folder / 'knowledge.sqlite3').write_bytes(database)
            self.manifest['packages'][kind] = {
                'directory': kind, 'manifest_sha256': hashlib.sha256(meta).hexdigest(),
                'database_sha256': hashlib.sha256(database).hexdigest(),
            }
        self.save()
        self.output = self.root / 'v1.careknowledge'
        self.descriptor = self.root / 'releases' / 'v1.json'

    def save(self):
        (self.source / 'manifest.json').write_text(json.dumps(self.manifest), encoding='utf-8')

    def build(self):
        return build(self.source, self.output, self.descriptor, 'synthetic-v1')

    def test_all_nine_files_preserved_with_exact_framing_and_hashes(self):
        result = self.build()
        raw = self.output.read_bytes()
        self.assertEqual(raw[:8], b'CAREKB01')
        length = struct.unpack('<I', raw[8:12])[0]
        self.assertEqual(raw[12:12+length], self.descriptor.read_bytes())
        descriptor = json.loads(raw[12:12+length])
        offset = 12 + length
        self.assertTrue(descriptor['preview'])
        self.assertEqual(len(descriptor['files']), 9)
        for file in descriptor['files']:
            chunk = raw[offset:offset+file['bytes']]
            self.assertEqual(chunk, (self.source / file['path']).read_bytes())
            self.assertEqual(hashlib.sha256(chunk).hexdigest(), file['sha256'])
            offset += file['bytes']
        self.assertEqual(offset, len(raw))
        self.assertEqual(result['bytes'], len(raw))

    def test_unreviewed_builder_cannot_promote_content(self):
        self.manifest['approval_state'] = 'approved'
        self.save()
        with self.assertRaises(ValueError):
            self.build()
        self.assertFalse(self.output.exists())

    def test_changed_content_and_foreign_directories_are_rejected(self):
        (self.source / 'dur' / 'knowledge.sqlite3').write_bytes(b'changed')
        with self.assertRaises(ValueError):
            self.build()
        self.assertFalse(self.output.exists())
        self.manifest['packages']['documents']['directory'] = '../escape'
        self.save()
        with self.assertRaises(ValueError):
            self.build()

    def test_prior_descriptor_output_and_partial_files_are_preserved(self):
        self.build()
        before = self.output.read_bytes(), self.descriptor.read_bytes()
        with self.assertRaises(FileExistsError):
            self.build()
        self.assertEqual(before, (self.output.read_bytes(), self.descriptor.read_bytes()))
        partial = self.root / 'v2.careknowledge.partial'
        partial.write_bytes(b'prior interrupted attempt')
        with self.assertRaises(FileExistsError):
            build(self.source, partial.with_suffix(''), self.root / 'v2.json', 'v2')
        self.assertEqual(partial.read_bytes(), b'prior interrupted attempt')


if __name__ == '__main__':
    unittest.main()
