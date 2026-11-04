from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from scripts.report_automated_agent_evaluation import generate_report, ConsolidatedReportError
from tests.agent_fixtures import consolidated_inputs


class AutomatedAgentEvaluationReportTests(unittest.TestCase):
    def test_consolidated_report_is_verified_and_never_promoted(self) -> None:
        root = Path.cwd().resolve()
        with tempfile.TemporaryDirectory(dir=root) as temp_name:
            base = Path(temp_name)
            input_manifest = consolidated_inputs(root, base)
            output = base / "report"
            generate_report(root, input_manifest, output)
            generated_json = (output / "automated_agent_evaluation.json").read_bytes()
            generated_markdown = (output / "automated_agent_evaluation.md").read_bytes()
            report = json.loads(
                generated_json.decode("utf-8")
            )
            manifest = json.loads(
                (output / "manifest.json").read_text(encoding="utf-8")
            )
            # Verify input hashes, rather than just accepting false gate flags.
            (base / 'responses/responses.jsonl').write_text('{}\n', encoding='utf-8')
            with self.assertRaises(ConsolidatedReportError):
                generate_report(root, input_manifest, base / 'tampered-report')

        self.assertTrue(report["automated_development_diagnostic"])
        self.assertFalse(report["evaluation_eligible"])
        self.assertFalse(report["model_performance_result"])
        self.assertFalse(report["medical_release_gate_result"])
        self.assertFalse(report["automated_research_cutoff"]["reached"])
        self.assertEqual(
            report["technical_conclusion"]["status"],
            "best_observed_nonpassing_development_baseline",
        )
        self.assertFalse(
            report["technical_conclusion"]["selected_for_medical_use"]
        )
        self.assertFalse(manifest["evaluation_eligible"])
        self.assertFalse(manifest["medical_release_gate_result"])
        self.assertIn(b"synthetic-contract", generated_markdown)


if __name__ == "__main__":
    unittest.main()
