from __future__ import annotations

import json
from pathlib import Path
import unittest


WORKSPACE_ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = (
    WORKSPACE_ROOT
    / "experiments"
    / "agent_eval"
    / "manifests"
    / "runtime_profiles.json"
)
MODEL_LOCK_PATH = PROFILE_PATH.with_name("models.lock.json")


class Qwen35RuntimeProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        document = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))
        profiles = document["profiles"]
        self.profile = next(
            profile
            for profile in profiles
            if profile["id"] == "RT-M1-HF-BNB-NF4-WIN-001"
        )

    def test_model_revision_matches_locked_original(self) -> None:
        model_lock = json.loads(MODEL_LOCK_PATH.read_text(encoding="utf-8"))
        locked_model = next(
            model for model in model_lock["models"] if model["id"] == "M1"
        )

        self.assertEqual(self.profile["model"]["asset_id"], "M1")
        self.assertEqual(
            self.profile["model"]["revision"], locked_model["revision"]
        )
        self.assertEqual(self.profile["model"]["input_precision"], "bfloat16")

    def test_desktop_runtime_and_nf4_parameters_are_fixed(self) -> None:
        runtime = self.profile["runtime"]
        quantization = self.profile["quantization"]

        self.assertEqual(runtime["os"], "windows_x86_64")
        self.assertEqual(runtime["python"], "3.12")
        self.assertEqual(runtime["engine"], "transformers_in_process")
        self.assertEqual(runtime["linear_attention_kernel"], "pytorch_reference")
        self.assertEqual(runtime["packages"]["torch"], "2.12.1+cu126")
        self.assertEqual(runtime["packages"]["transformers"], "5.16.1")
        self.assertEqual(runtime["packages"]["accelerate"], "1.14.0")
        self.assertEqual(runtime["packages"]["bitsandbytes"], "0.50.2")
        self.assertEqual(quantization["loader"], "BitsAndBytesConfig")
        self.assertEqual(quantization["weight_bits"], 4)
        self.assertEqual(quantization["quant_type"], "nf4")
        self.assertEqual(quantization["compute_dtype"], "bfloat16")
        self.assertFalse(quantization["double_quant"])
        self.assertEqual(quantization["storage_dtype"], "uint8")

    def test_profile_fails_closed_and_does_not_claim_mobile_validation(self) -> None:
        policy = self.profile["policy"]

        self.assertTrue(policy["local_files_only"])
        self.assertFalse(policy["network_access"])
        self.assertFalse(policy["trust_remote_code"])
        self.assertFalse(policy["cpu_or_disk_offload"])
        self.assertFalse(policy["automatic_precision_fallback"])
        self.assertEqual(
            self.profile["mobile_deployment"]["status"],
            "not_selected_requires_separate_device_validation",
        )


if __name__ == "__main__":
    unittest.main()
