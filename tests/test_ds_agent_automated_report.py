from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from scripts.report_ds_agent_automated_eval import generate_report, AutomatedEvalReportError
from tests.agent_fixtures import synthetic_report


class DsAgentAutomatedReportTests(unittest.TestCase):
    def test_partial_smoke_is_verified_but_never_promoted(self) -> None:
        root = Path.cwd().resolve()
        with tempfile.TemporaryDirectory(dir=root) as temp_name:
            output = synthetic_report(root, Path(temp_name))
            with self.assertRaises(AutomatedEvalReportError):
                generate_report(root, [Path(temp_name) / "run"], Path(temp_name) / "complete")
            report = json.loads(
                (output / "automated_evaluation_report.json").read_text(
                    encoding="utf-8"
                )
            )
            manifest = json.loads(
                (output / "manifest.json").read_text(encoding="utf-8")
            )

        self.assertTrue(report["automated_development_diagnostic"])
        self.assertFalse(report["evaluation_eligible"])
        self.assertFalse(report["model_performance_result"])
        self.assertFalse(report["medical_release_gate_result"])
        self.assertEqual(report["topologies"][0]["episode_count"], 1)
        self.assertFalse(report["topologies"][0]["standard_48_complete"])
        self.assertFalse(manifest["medical_release_gate_result"])


if __name__ == "__main__":
    unittest.main()
