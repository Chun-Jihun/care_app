from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.freeze_asset_manifests import hash_directory
from scripts.stage_mfds_easy_drug import (
    StagingError,
    normalize_medical_text,
    stage_snapshot,
)


def _sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


class StagingFixture:
    def __init__(self, root: Path, items: list[dict[str, object]]) -> None:
        self.root = root
        self.raw_dir = root / "data" / "easy-drug" / "raw" / "SNAPSHOT"
        self.raw_dir.mkdir(parents=True)
        payload = {
            "header": {"resultCode": "00", "resultMsg": "NORMAL SERVICE."},
            "body": {
                "pageNo": 1,
                "totalCount": len(items),
                "numOfRows": 100,
                "items": items,
            },
        }
        page_bytes = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        (self.raw_dir / "page-00001.json").write_bytes(page_bytes)
        self.raw_manifest = {
            "schema_version": "1.0",
            "snapshot_id": "SNAPSHOT",
            "approval_state": "raw_unreviewed",
            "source": {
                "title": "식품의약품안전처_의약품개요정보(e약은요)",
                "provider": "식품의약품안전처",
                "catalog_url": "https://example.test/easy-drug",
            },
            "collector": {"version": "test"},
            "download": {
                "complete": True,
                "page_count": 1,
                "downloaded_item_count": len(items),
                "reported_total_count": len(items),
                "completed_at": "2026-09-01T00:00:00Z",
                "pages": [
                    {
                        "file": "page-00001.json",
                        "sha256": _sha256(page_bytes),
                        "bytes": len(page_bytes),
                        "result_code": "00",
                        "page_no": 1,
                        "num_rows": 100,
                        "item_count": len(items),
                        "total_count": len(items),
                    }
                ],
            },
            "handling": {"runtime_rag_eligible": False},
        }
        (self.raw_dir / "manifest.json").write_text(
            json.dumps(self.raw_manifest, ensure_ascii=False), encoding="utf-8"
        )
        tree = hash_directory(self.raw_dir)
        self.asset_lock = root / "data_sources.lock.json"
        self.asset_lock.write_text(
            json.dumps(
                {
                    "data_sources": [
                        {
                            "id": "RAG-DRUG-01",
                            "availability": "present",
                            "local_path": "data/easy-drug/raw/SNAPSHOT",
                            "integrity": {"tree_sha256": tree.tree_sha256},
                            "approval": {
                                "state": "raw_unreviewed",
                                "runtime_rag_eligible": False,
                            },
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )


def _item(**overrides: object) -> dict[str, object]:
    value: dict[str, object] = {
        "entpName": "테스트제약",
        "itemName": "테스트정",
        "itemSeq": "123456789",
        "efcyQesitm": "<p>첫 번째 효능입니다.</p><p>두 번째 효능입니다.</p>",
        "useMethodQesitm": "정해진 방법으로 복용합니다.",
        "atpnWarnQesitm": None,
        "atpnQesitm": "주의하십시오.\n\n이상 시 확인하십시오.",
        "intrcQesitm": None,
        "seQesitm": None,
        "depositMethodQesitm": "실온에서 보관하십시오.",
        "openDe": "20210129",
        "updateDe": "2024-05-09",
        "itemImage": None,
        "bizrno": "1234567890",
    }
    value.update(overrides)
    return value


class TextNormalizationTests(unittest.TestCase):
    def test_html_nbsp_and_line_breaks_are_normalized_without_new_claims(self) -> None:
        normalized, blocks = normalize_medical_text(
            "<p>첫 문장&nbsp;입니다.</p><ul><li>둘째 항목</li><li>셋째 항목</li></ul>"
        )
        self.assertEqual(normalized, "첫 문장 입니다.\n\n둘째 항목\n\n셋째 항목")
        self.assertEqual(blocks, ["첫 문장 입니다.", "둘째 항목", "셋째 항목"])


class SnapshotStagingTests(unittest.TestCase):
    def test_valid_snapshot_is_staged_with_traceable_spans(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            first = _item(itemImage=None)
            second = _item(itemImage="https://example.test/image.jpg")
            fixture = StagingFixture(root, [first, second])
            output = root / "data" / "easy-drug" / "staged" / "SNAPSHOT-schema-v1"

            stage_snapshot(
                workspace_root=root,
                raw_dir=fixture.raw_dir,
                output_dir=output,
                asset_lock_path=fixture.asset_lock,
            )

            products = [
                json.loads(line)
                for line in (output / "products.jsonl").read_text(encoding="utf-8").splitlines()
            ]
            spans = [
                json.loads(line)
                for line in (output / "evidence_spans.jsonl")
                .read_text(encoding="utf-8")
                .splitlines()
            ]
            manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
            report = json.loads((output / "quality_report.json").read_text(encoding="utf-8"))

            self.assertEqual(len(products), 1)
            self.assertEqual(len(products[0]["source_refs"]), 2)
            self.assertEqual(products[0]["image_urls"], ["https://example.test/image.jpg"])
            self.assertEqual(
                products[0]["sections"]["effectiveness"]["normalized_text"],
                "첫 번째 효능입니다.\n\n두 번째 효능입니다.",
            )
            effectiveness_spans = [s for s in spans if s["section"] == "effectiveness"]
            self.assertEqual(len(effectiveness_spans), 2)
            normalized = products[0]["sections"]["effectiveness"]["normalized_text"]
            for span in effectiveness_spans:
                self.assertEqual(
                    normalized[span["normalized_start"] : span["normalized_end"]],
                    span["text"],
                )
                self.assertEqual(span["review_status"], "unreviewed")
                self.assertFalse(span["runtime_rag_eligible"])

            self.assertEqual(manifest["approval_state"], "staged_unreviewed")
            self.assertFalse(manifest["runtime_rag_eligible"])
            self.assertFalse(manifest["clinical_review"]["completed"])
            self.assertEqual(report["summary"]["raw_item_count"], 2)
            self.assertEqual(report["summary"]["unique_product_count"], 1)
            self.assertEqual(report["summary"]["collapsed_duplicate_rows"], 1)

    def test_page_hash_mismatch_fails_without_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fixture = StagingFixture(root, [_item()])
            (fixture.raw_dir / "page-00001.json").write_text("{}", encoding="utf-8")
            output = root / "out"
            with self.assertRaises(StagingError):
                stage_snapshot(root, fixture.raw_dir, output, fixture.asset_lock)
            self.assertFalse(output.exists())

    def test_incomplete_download_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fixture = StagingFixture(root, [_item()])
            manifest_path = fixture.raw_dir / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["download"]["complete"] = False
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            fixture.asset_lock.write_text(
                json.dumps(
                    {
                        "data_sources": [
                            {
                                "id": "RAG-DRUG-01",
                                "availability": "present",
                                "local_path": "data/easy-drug/raw/SNAPSHOT",
                                "integrity": {
                                    "tree_sha256": hash_directory(fixture.raw_dir).tree_sha256
                                },
                                "approval": {
                                    "state": "raw_unreviewed",
                                    "runtime_rag_eligible": False,
                                },
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaises(StagingError):
                stage_snapshot(root, fixture.raw_dir, root / "out", fixture.asset_lock)

    def test_conflicting_medical_duplicate_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fixture = StagingFixture(
                root,
                [_item(efcyQesitm="효능 A"), _item(efcyQesitm="효능 B")],
            )
            with self.assertRaises(StagingError):
                stage_snapshot(root, fixture.raw_dir, root / "out", fixture.asset_lock)

    def test_asset_lock_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fixture = StagingFixture(root, [_item()])
            lock = json.loads(fixture.asset_lock.read_text(encoding="utf-8"))
            lock["data_sources"][0]["integrity"]["tree_sha256"] = "0" * 64
            fixture.asset_lock.write_text(json.dumps(lock), encoding="utf-8")
            with self.assertRaises(StagingError):
                stage_snapshot(root, fixture.raw_dir, root / "out", fixture.asset_lock)

    def test_existing_output_is_never_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fixture = StagingFixture(root, [_item()])
            output = root / "out"
            output.mkdir()
            marker = output / "keep.txt"
            marker.write_text("keep", encoding="utf-8")
            with self.assertRaises(StagingError):
                stage_snapshot(root, fixture.raw_dir, output, fixture.asset_lock)
            self.assertEqual(marker.read_text(encoding="utf-8"), "keep")


if __name__ == "__main__":
    unittest.main()
