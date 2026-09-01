from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.freeze_asset_manifests import (
    ManifestError,
    build_locks,
    hash_directory,
    load_catalog,
)


class DirectoryHashTests(unittest.TestCase):
    def test_tree_hash_is_deterministic_and_changes_with_content(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "z").mkdir()
            (root / "z" / "b.txt").write_text("second", encoding="utf-8")
            (root / "a.txt").write_text("first", encoding="utf-8")

            first = hash_directory(root)
            second = hash_directory(root)
            parallel = hash_directory(root, workers=4)
            self.assertEqual(first.tree_sha256, second.tree_sha256)
            self.assertEqual(first.tree_sha256, parallel.tree_sha256)
            self.assertEqual(first.file_count, 2)

            (root / "a.txt").write_text("changed", encoding="utf-8")
            changed = hash_directory(root)
            self.assertNotEqual(first.tree_sha256, changed.tree_sha256)

    def test_cache_and_secret_files_are_excluded(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "payload.txt").write_text("public", encoding="utf-8")
            baseline = hash_directory(root)

            (root / ".env").write_text("SECRET=must-not-be-read", encoding="utf-8")
            (root / ".cache").mkdir()
            (root / ".cache" / "token").write_text("secret", encoding="utf-8")
            after = hash_directory(root)

            self.assertEqual(baseline.tree_sha256, after.tree_sha256)
            self.assertEqual(after.file_count, 1)


class LockManifestTests(unittest.TestCase):
    def _write_fixture(self, root: Path) -> Path:
        model_dir = root / "models" / "fixture"
        model_dir.mkdir(parents=True)
        model_bytes = b"model-weights"
        (model_dir / "model.safetensors").write_bytes(model_bytes)
        (model_dir / "LICENSE").write_text("Apache License 2.0", encoding="utf-8")
        cache_dir = model_dir / ".cache" / "huggingface" / "trees"
        cache_dir.mkdir(parents=True)
        (cache_dir / "abc123.json").write_text('{"format_version": 1}', encoding="utf-8")

        eval_dir = root / "data" / "fixture-eval"
        eval_dir.mkdir(parents=True)
        (eval_dir / "test.jsonl").write_text('{"id": 1}\n', encoding="utf-8")

        easy_dir = root / "data" / "easy-drug" / "raw" / "SNAPSHOT"
        easy_dir.mkdir(parents=True)
        page = b'{"body":{"items":[],"totalCount":0}}'
        (easy_dir / "page-00001.json").write_bytes(page)
        raw_manifest = {
            "snapshot_id": "SNAPSHOT",
            "approval_state": "raw_unreviewed",
            "download": {"complete": True, "page_count": 1, "downloaded_item_count": 0},
            "handling": {"runtime_rag_eligible": False},
        }
        (easy_dir / "manifest.json").write_text(
            json.dumps(raw_manifest), encoding="utf-8"
        )

        catalog = {
            "schema_version": "1.0",
            "license_checked_at": "2026-09-01",
            "models": [
                {
                    "id": "M1",
                    "name": "Fixture Model",
                    "local_path": "models/fixture",
                    "repository_id": "owner/model",
                    "source_url": "https://example.test/model",
                    "license": {"spdx": "Apache-2.0", "status": "verified"},
                    "required": True,
                }
            ],
            "data_sources": [
                {
                    "id": "EVAL-FIXTURE",
                    "name": "Fixture Eval",
                    "local_path": "data/fixture-eval",
                    "source_url": "https://example.test/eval",
                    "license": {"spdx": "MIT", "status": "verified"},
                    "required": True,
                    "usage": {
                        "purpose": ["component_evaluation"],
                        "do_not_train": True,
                        "mobile_bundle": False,
                        "runtime_rag_eligible": False,
                    },
                },
                {
                    "id": "RAG-DRUG-01",
                    "name": "Easy Drug",
                    "local_path": "data/easy-drug/raw/SNAPSHOT",
                    "source_url": "https://example.test/easy-drug",
                    "license": {"spdx": "NOASSERTION", "status": "needs_review"},
                    "required": True,
                    "raw_snapshot_manifest": "manifest.json",
                    "usage": {
                        "purpose": ["rag_candidate"],
                        "do_not_train": True,
                        "mobile_bundle": False,
                        "runtime_rag_eligible": False,
                    },
                },
                {
                    "id": "OPTIONAL-MISSING",
                    "name": "Optional Missing",
                    "local_path": "data/not-downloaded",
                    "source_url": "https://example.test/missing",
                    "license": {"spdx": "MIT", "status": "verified"},
                    "required": False,
                    "usage": {
                        "purpose": ["component_evaluation"],
                        "do_not_train": True,
                        "mobile_bundle": False,
                        "runtime_rag_eligible": False,
                    },
                },
            ],
        }
        catalog_path = root / "asset_sources.json"
        catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
        return catalog_path

    def test_build_locks_records_hashes_and_safety_boundaries(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            catalog_path = self._write_fixture(root)
            catalog = load_catalog(catalog_path)
            models_lock, data_lock = build_locks(root, catalog)

            model = models_lock["models"][0]
            expected = hashlib.sha256(b"model-weights").hexdigest()
            hashes = {item["path"]: item["sha256"] for item in model["files"]}
            self.assertEqual(hashes["model.safetensors"], expected)
            self.assertEqual(model["revision"], "abc123")

            eval_entry = next(
                item for item in data_lock["data_sources"] if item["id"] == "EVAL-FIXTURE"
            )
            self.assertTrue(eval_entry["usage"]["do_not_train"])
            self.assertFalse(eval_entry["usage"]["mobile_bundle"])

            easy = next(
                item for item in data_lock["data_sources"] if item["id"] == "RAG-DRUG-01"
            )
            self.assertEqual(easy["approval"]["state"], "raw_unreviewed")
            self.assertFalse(easy["approval"]["runtime_rag_eligible"])
            self.assertTrue(easy["approval"]["download_complete"])

            missing = next(
                item for item in data_lock["data_sources"] if item["id"] == "OPTIONAL-MISSING"
            )
            self.assertEqual(missing["availability"], "missing")

            serialized = json.dumps([models_lock, data_lock])
            self.assertNotIn(str(root), serialized)
            self.assertNotIn("must-not-be-read", serialized)

    def test_required_missing_asset_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            catalog_path = self._write_fixture(root)
            catalog = load_catalog(catalog_path)
            catalog["models"][0]["local_path"] = "models/missing"
            with self.assertRaises(ManifestError):
                build_locks(root, catalog)

    def test_path_escape_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            catalog_path = self._write_fixture(root)
            catalog = load_catalog(catalog_path)
            catalog["models"][0]["local_path"] = "../outside"
            with self.assertRaises(ManifestError):
                build_locks(root, catalog)


class ProjectCatalogPolicyTests(unittest.TestCase):
    def test_project_evaluation_sources_are_never_training_or_mobile_assets(self) -> None:
        workspace = Path(__file__).resolve().parents[1]
        catalog = load_catalog(
            workspace / "experiments" / "agent_eval" / "manifests" / "asset_sources.json"
        )
        ids: set[str] = set()
        for source in catalog["data_sources"]:
            self.assertNotIn(source["id"], ids)
            ids.add(source["id"])
            self.assertTrue(source["source_url"].startswith("https://"))
            usage = source["usage"]
            self.assertTrue(usage["do_not_train"])
            self.assertFalse(usage["mobile_bundle"])
            self.assertFalse(usage["runtime_rag_eligible"])


if __name__ == "__main__":
    unittest.main()
