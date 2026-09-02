from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from scripts.report_automated_agent_evaluation import generate_report


class AutomatedAgentEvaluationReportTests(unittest.TestCase):
    def test_consolidated_report_is_verified_and_never_promoted(self) -> None:
        root = Path.cwd().resolve()
        input_manifest = Path(
            "experiments/agent_eval/manifests/automated_agent_eval_inputs_v1.json"
        )
        results_root = root / "experiments/agent_eval/results"

        with tempfile.TemporaryDirectory(dir=results_root) as temp_name:
            output = Path(temp_name) / "report"
            generate_report(root, input_manifest, output)
            generated_json = (output / "automated_agent_evaluation.json").read_bytes()
            generated_markdown = (output / "automated_agent_evaluation.md").read_bytes()
            report = json.loads(
                generated_json.decode("utf-8")
            )
            manifest = json.loads(
                (output / "manifest.json").read_text(encoding="utf-8")
            )

        self.assertTrue(report["automated_development_diagnostic"])
        self.assertFalse(report["evaluation_eligible"])
        self.assertFalse(report["model_performance_result"])
        self.assertFalse(report["medical_release_gate_result"])
        self.assertTrue(report["automated_research_cutoff"]["reached"])
        self.assertEqual(
            report["technical_conclusion"]["status"],
            "best_observed_nonpassing_development_baseline",
        )
        self.assertFalse(
            report["technical_conclusion"]["selected_for_medical_use"]
        )
        self.assertFalse(manifest["evaluation_eligible"])
        self.assertFalse(manifest["medical_release_gate_result"])
        committed = root / "experiments/agent_eval/results/automated_agent_evaluation_v1"
        self.assertEqual(
            generated_json,
            (committed / "automated_agent_evaluation.json").read_bytes(),
        )
        self.assertEqual(
            generated_markdown,
            (committed / "automated_agent_evaluation.md").read_bytes(),
        )


if __name__ == "__main__":
    unittest.main()
