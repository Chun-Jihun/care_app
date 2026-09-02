from __future__ import annotations

import hashlib
import json
from pathlib import Path
import unittest


WORKSPACE_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_ROOT = WORKSPACE_ROOT / "experiments" / "agent_eval" / "manifests"
PROFILE_PATH = MANIFEST_ROOT / "model_comparison_runtime_profiles_v1.json"
MODEL_LOCK_PATH = MANIFEST_ROOT / "model_comparison_v1" / "models.lock.json"
INPUT_PATH = MANIFEST_ROOT / "model_comparison_inputs_v1.json"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _merge(base: dict, override: dict) -> dict:
    result = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = _merge(result[key], value)
        else:
            result[key] = value
    return result


class ModelComparisonRuntimeProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.document = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))
        self.model_lock = json.loads(MODEL_LOCK_PATH.read_text(encoding="utf-8"))
        self.inputs = json.loads(INPUT_PATH.read_text(encoding="utf-8"))

    def test_five_downloaded_revisions_match_the_model_lock(self) -> None:
        profiles = self.document["profiles"]
        locked = {model["id"]: model for model in self.model_lock["models"]}

        self.assertEqual({profile["model"]["asset_id"] for profile in profiles}, set(locked))
        self.assertEqual(len(profiles), 5)
        for profile in profiles:
            model = profile["model"]
            self.assertEqual(model["revision"], locked[model["asset_id"]]["revision"])
            self.assertEqual(model["model_lock_sha256"], _sha256(MODEL_LOCK_PATH))

    def test_common_primary_budget_quantization_and_fail_closed_policy(self) -> None:
        defaults = self.document["defaults"]
        for profile in self.document["profiles"]:
            effective = _merge(defaults, profile)
            generation = effective["generation"]["primary_scored"]
            quantization = effective["quantization"]
            policy = effective["policy"]

            self.assertFalse(generation["do_sample"])
            self.assertEqual(generation["max_input_tokens"], 4096)
            self.assertEqual(generation["max_new_tokens"], 512)
            self.assertEqual(quantization["weight_bits"], 4)
            self.assertEqual(quantization["quant_type"], "nf4")
            self.assertEqual(quantization["compute_dtype"], "bfloat16")
            self.assertFalse(quantization["double_quant"])
            self.assertTrue(policy["local_files_only"])
            self.assertFalse(policy["network_access"])
            self.assertFalse(policy["trust_remote_code"])
            self.assertFalse(policy["automatic_precision_fallback"])

    def test_report_inputs_pin_the_executed_runtime_and_model_lock(self) -> None:
        locked_assets = self.inputs["locked_assets"]

        self.assertEqual(locked_assets["runtime_profile_sha256"], _sha256(PROFILE_PATH))
        self.assertEqual(locked_assets["model_lock_sha256"], _sha256(MODEL_LOCK_PATH))

    def test_desktop_profiles_do_not_claim_mobile_selection(self) -> None:
        self.assertEqual(
            self.document["defaults"]["mobile_deployment"]["status"],
            "not_selected_requires_separate_device_validation",
        )


if __name__ == "__main__":
    unittest.main()
