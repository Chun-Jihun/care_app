import unittest
import json
from pathlib import Path
import tempfile
from unittest.mock import patch
from scripts.evaluate_evidence_selector import grade
from scripts.audit_mobile_release import main as audit_release, media_diagnostics


class ReleaseAuditTests(unittest.TestCase):
    def test_model_json_requires_exact_keys_unique_ids_and_all_conditions(self):
        self.assertTrue(grade('{"evidence_ids":["b","a"]}', ['a', 'b'])['exact_ids'])
        for text in ['{"evidence_ids":["a"]}', '{"evidence_ids":["a","a"]}',
                     '{"evidence_ids":["a","b"],"advice":"unsafe"}',
                     'prefix {"evidence_ids":["a","b"]}', 'null', '[]']:
            self.assertFalse(grade(text, ['a', 'b'])['exact_ids'])

    def test_saved_native_outputs_are_not_marked_as_new_device_or_quality_approval(self):
        report = media_diagnostics()
        self.assertIn('archived', report['execution'])
        self.assertFalse(report['quality_gate_passed'])
        self.assertGreater(report['groups']['speech']['edits'], 0)
        self.assertGreater(report['groups']['ocr']['cases'], 0)

    def test_android_scope_defers_ios_without_granting_medical_approval(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'audit.json'
            with patch('sys.argv', ['audit', '--output', str(output)]), \
                 patch('scripts.audit_mobile_release.audit_package', return_value={'sources': [], 'pages': []}), \
                 patch('scripts.audit_mobile_release.media_diagnostics', return_value={}):
                audit_release()
            report = json.loads(output.read_text(encoding='utf-8'))
        self.assertEqual(report['release_platforms'], ['android'])
        self.assertEqual(report['deferred_platforms'], ['ios'])
        self.assertFalse(report['medical_release_gate_result'])
        self.assertTrue(report['blockers'])
        self.assertFalse(any('ios' in blocker.lower() for blocker in report['blockers']))


if __name__ == '__main__':
    unittest.main()
