import unittest
from scripts.evaluate_evidence_selector import grade
from scripts.audit_mobile_release import media_diagnostics


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


if __name__ == '__main__':
    unittest.main()
