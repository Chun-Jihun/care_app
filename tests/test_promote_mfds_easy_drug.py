from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from scripts.promote_mfds_easy_drug import (
    CLINICAL_ATTESTATION,
    ApprovalError,
    create_review_catalog,
    prepare_review_packet,
    promote_approved_snapshot,
)


def _json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def _jsonl_bytes(values: list[dict[str, object]]) -> bytes:
    return b"".join(
        (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode(
            "utf-8"
        )
        for value in values
    )


def _output(file: str, content: bytes, record_count: int | None = None) -> dict[str, object]:
    result: dict[str, object] = {
        "file": file,
        "bytes": len(content),
        "sha256": hashlib.sha256(content).hexdigest(),
    }
    if record_count is not None:
        result["record_count"] = record_count
    return result


def _section(source_field: str, text: str | None, span_ids: list[str]) -> dict[str, object]:
    return {
        "source_field": source_field,
        "raw_text": text,
        "raw_text_sha256": hashlib.sha256(text.encode()).hexdigest() if text else None,
        "normalized_text": text,
        "normalized_text_sha256": hashlib.sha256(text.encode()).hexdigest()
        if text
        else None,
        "span_ids": span_ids,
    }


def _write_staged_fixture(root: Path) -> Path:
    staged = root / "data" / "easy-drug" / "staged" / "SNAPSHOT-schema-v1"
    staged.mkdir(parents=True)
    refs = [
        {
            "page_file": "page-00001.json",
            "page_sha256": "a" * 64,
            "item_index": 0,
            "json_pointer": "/body/items/0",
        }
    ]
    product = {
        "schema_version": "1.0",
        "product_id": "MFDS-EASY-0001",
        "item_seq": "0001",
        "product_name": "시험약",
        "manufacturer_name": "시험제약",
        "business_registration_number": "1234567890",
        "disclosed_at": "2025-01-01",
        "updated_at": "2026-08-01",
        "image_urls": [],
        "sections": {
            "effectiveness": _section("efcyQesitm", "시험 효능 원문입니다.", ["SPAN-1"]),
            "usage": _section("useMethodQesitm", None, []),
            "warnings": _section("atpnWarnQesitm", None, []),
            "precautions": _section("atpnQesitm", "시험 주의 원문입니다.", ["SPAN-2"]),
            "interactions": _section("intrcQesitm", None, []),
            "adverse_reactions": _section("seQesitm", None, []),
            "storage": _section("depositMethodQesitm", None, []),
        },
        "source_values": {"itemSeq": "0001"},
        "source_refs": refs,
        "review_status": "unreviewed",
        "runtime_rag_eligible": False,
    }
    spans = [
        {
            "schema_version": "1.0",
            "span_id": "SPAN-1",
            "document_id": "MFDS-EASY-0001",
            "product_id": "MFDS-EASY-0001",
            "item_seq": "0001",
            "section": "effectiveness",
            "source_field": "efcyQesitm",
            "ordinal": 1,
            "location": "efcyQesitm#1",
            "text": "시험 효능 원문입니다.",
            "text_sha256": hashlib.sha256("시험 효능 원문입니다.".encode()).hexdigest(),
            "normalized_start": 0,
            "normalized_end": len("시험 효능 원문입니다."),
            "source_refs": refs,
            "review_status": "unreviewed",
            "runtime_rag_eligible": False,
        },
        {
            "schema_version": "1.0",
            "span_id": "SPAN-2",
            "document_id": "MFDS-EASY-0001",
            "product_id": "MFDS-EASY-0001",
            "item_seq": "0001",
            "section": "precautions",
            "source_field": "atpnQesitm",
            "ordinal": 1,
            "location": "atpnQesitm#1",
            "text": "시험 주의 원문입니다.",
            "text_sha256": hashlib.sha256("시험 주의 원문입니다.".encode()).hexdigest(),
            "normalized_start": 0,
            "normalized_end": len("시험 주의 원문입니다."),
            "source_refs": refs,
            "review_status": "unreviewed",
            "runtime_rag_eligible": False,
        },
    ]
    products_bytes = _jsonl_bytes([product])
    spans_bytes = _jsonl_bytes(spans)
    quality_bytes = _json_bytes({"technical_validation": "passed"})
    (staged / "products.jsonl").write_bytes(products_bytes)
    (staged / "evidence_spans.jsonl").write_bytes(spans_bytes)
    (staged / "quality_report.json").write_bytes(quality_bytes)
    manifest = {
        "schema_version": "1.0",
        "stage_id": "mfds-easy-drug-SNAPSHOT-schema-v1",
        "approval_state": "staged_unreviewed",
        "runtime_rag_eligible": False,
        "source": {
            "title": "식품의약품안전처_의약품개요정보(e약은요)",
            "provider": "식품의약품안전처",
            "catalog_url": "https://www.data.go.kr/data/15075057/openapi.do",
        },
        "input": {
            "raw_snapshot_id": "SNAPSHOT",
            "download_completed_at": "2026-09-01T00:00:00Z",
        },
        "transformer": {"version": "0.1.0", "medical_content_generated": False},
        "technical_validation": {"completed": True, "passed": True},
        "clinical_review": {"completed": False, "reviewed_at": None, "reviewer_roles": []},
        "usage": {
            "do_not_train": True,
            "mobile_bundle": False,
            "runtime_rag_eligible": False,
        },
        "outputs": [
            _output("products.jsonl", products_bytes, 1),
            _output("evidence_spans.jsonl", spans_bytes, 2),
            _output("quality_report.json", quality_bytes),
        ],
    }
    (staged / "manifest.json").write_bytes(_json_bytes(manifest))
    return staged


def _selection(path: Path) -> Path:
    path.write_bytes(_json_bytes({"schema_version": "1.0", "item_seqs": ["0001"]}))
    return path


def _complete_decisions(template_path: Path, output_path: Path) -> Path:
    decisions = json.loads(template_path.read_text(encoding="utf-8"))
    decisions["reviewer"] = {
        "reviewer_id": "reviewer-001",
        "roles": ["pharmacist"],
        "organization": "test-clinic",
        "credential_verification": {
            "verified": True,
            "verified_by": "clinical-admin-001",
            "verified_at": "2026-09-01",
        },
    }
    decisions["reviewed_at"] = "2026-09-01"
    decisions["next_review_due"] = "2027-03-01"
    decisions["attestation"] = CLINICAL_ATTESTATION
    decisions["rights_review"] = {
        "completed": True,
        "decision": "approved",
        "reviewer_id": "rights-reviewer-001",
        "reviewed_at": "2026-09-01",
        "license_basis": "공공데이터포털 이용허락범위 제한 없음 확인",
        "evidence_url": "https://www.data.go.kr/data/15075057/openapi.do",
    }
    product_review = decisions["product_reviews"][0]
    product_review["identity_confirmed"] = True
    product_review["span_reviews"][0].update(
        {
            "decision": "approved",
            "allowed_uses": ["general_drug_purpose_explanation"],
            "note": "원문과 대조함",
        }
    )
    product_review["span_reviews"][1].update(
        {"decision": "rejected", "allowed_uses": [], "note": "이번 범위에서 제외"}
    )
    output_path.write_bytes(_json_bytes(decisions))
    return output_path


class PromoteMfdsEasyDrugTests(unittest.TestCase):
    def test_catalog_and_review_packet_are_unapproved(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            staged = _write_staged_fixture(root)
            catalog = create_review_catalog(root, staged, root / "review-catalog")
            catalog_manifest = json.loads(
                (catalog / "manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(catalog_manifest["approval_state"], "awaiting_selection")
            self.assertFalse(catalog_manifest["runtime_rag_eligible"])
            catalog_row = json.loads(
                (catalog / "review_catalog.jsonl").read_text(encoding="utf-8")
            )
            self.assertEqual(catalog_row["span_count"], 2)
            self.assertNotIn("normalized_text", json.dumps(catalog_row))

            packet = prepare_review_packet(
                root,
                staged,
                _selection(root / "selection.json"),
                root / "review-packet",
                "REVIEW-001",
            )
            packet_manifest = json.loads(
                (packet / "manifest.json").read_text(encoding="utf-8")
            )
            template = json.loads(
                (packet / "review_decisions.template.json").read_text(encoding="utf-8")
            )
            self.assertEqual(packet_manifest["approval_state"], "awaiting_clinical_review")
            self.assertFalse(packet_manifest["runtime_rag_eligible"])
            self.assertTrue(
                all(
                    span["decision"] == "pending"
                    for span in template["product_reviews"][0]["span_reviews"]
                )
            )

    def test_pending_decision_cannot_be_promoted(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            staged = _write_staged_fixture(root)
            packet = prepare_review_packet(
                root,
                staged,
                _selection(root / "selection.json"),
                root / "review-packet",
                "REVIEW-001",
            )
            decisions_path = _complete_decisions(
                packet / "review_decisions.template.json", root / "decisions.json"
            )
            decisions = json.loads(decisions_path.read_text(encoding="utf-8"))
            decisions["product_reviews"][0]["span_reviews"][0]["decision"] = "pending"
            decisions_path.write_bytes(_json_bytes(decisions))
            with self.assertRaisesRegex(ApprovalError, "pending|미결정"):
                promote_approved_snapshot(
                    root,
                    staged,
                    packet,
                    decisions_path,
                    root / "approved",
                    "APPROVED-001",
                )

    def test_reviewer_role_and_rights_review_are_hard_gates(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            staged = _write_staged_fixture(root)
            packet = prepare_review_packet(
                root,
                staged,
                _selection(root / "selection.json"),
                root / "review-packet",
                "REVIEW-001",
            )
            decisions_path = _complete_decisions(
                packet / "review_decisions.template.json", root / "decisions.json"
            )
            decisions = json.loads(decisions_path.read_text(encoding="utf-8"))
            decisions["reviewer"]["roles"] = ["developer"]
            decisions_path.write_bytes(_json_bytes(decisions))
            with self.assertRaisesRegex(ApprovalError, "pharmacist|physician|검수 역할"):
                promote_approved_snapshot(
                    root, staged, packet, decisions_path, root / "approved", "APPROVED-001"
                )

            decisions["reviewer"]["roles"] = ["pharmacist"]
            decisions["rights_review"]["completed"] = False
            decisions_path.write_bytes(_json_bytes(decisions))
            with self.assertRaisesRegex(ApprovalError, "권리"):
                promote_approved_snapshot(
                    root, staged, packet, decisions_path, root / "approved", "APPROVED-001"
                )

    def test_packet_tampering_blocks_promotion(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            staged = _write_staged_fixture(root)
            packet = prepare_review_packet(
                root,
                staged,
                _selection(root / "selection.json"),
                root / "review-packet",
                "REVIEW-001",
            )
            decisions_path = _complete_decisions(
                packet / "review_decisions.template.json", root / "decisions.json"
            )
            with (packet / "evidence_spans.jsonl").open("ab") as stream:
                stream.write(b" ")
            with self.assertRaisesRegex(ApprovalError, "SHA-256|hash|해시|바이트"):
                promote_approved_snapshot(
                    root, staged, packet, decisions_path, root / "approved", "APPROVED-001"
                )

    def test_stage_tampering_after_packet_creation_blocks_promotion(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            staged = _write_staged_fixture(root)
            packet = prepare_review_packet(
                root,
                staged,
                _selection(root / "selection.json"),
                root / "review-packet",
                "REVIEW-001",
            )
            decisions_path = _complete_decisions(
                packet / "review_decisions.template.json", root / "decisions.json"
            )
            with (staged / "products.jsonl").open("ab") as stream:
                stream.write(b" ")
            with self.assertRaisesRegex(ApprovalError, "SHA-256|hash|해시|바이트"):
                promote_approved_snapshot(
                    root, staged, packet, decisions_path, root / "approved", "APPROVED-001"
                )

    def test_valid_review_promotes_only_approved_spans_but_not_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            staged = _write_staged_fixture(root)
            packet = prepare_review_packet(
                root,
                staged,
                _selection(root / "selection.json"),
                root / "review-packet",
                "REVIEW-001",
            )
            decisions_path = _complete_decisions(
                packet / "review_decisions.template.json", root / "decisions.json"
            )
            approved = promote_approved_snapshot(
                root,
                staged,
                packet,
                decisions_path,
                root / "approved",
                "APPROVED-001",
            )
            manifest = json.loads(
                (approved / "manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(manifest["approval_state"], "approved_snapshot")
            self.assertEqual(manifest["activation_state"], "pending_index_and_regression")
            self.assertFalse(manifest["runtime_rag_eligible"])
            self.assertFalse(manifest["usage"]["mobile_bundle"])
            spans = [
                json.loads(line)
                for line in (approved / "approved_evidence_spans.jsonl")
                .read_text(encoding="utf-8")
                .splitlines()
            ]
            self.assertEqual([span["span_id"] for span in spans], ["SPAN-1"])
            evidence = spans[0]
            for field in (
                "source_title",
                "publisher",
                "published_or_revised_at",
                "location",
                "supporting_span",
                "source_url",
                "reviewed_at",
            ):
                self.assertTrue(evidence[field])
            self.assertEqual(evidence["review_status"], "clinician_approved")
            self.assertFalse(evidence["runtime_rag_eligible"])

    def test_existing_output_is_never_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            staged = _write_staged_fixture(root)
            output = root / "review-catalog"
            output.mkdir()
            sentinel = output / "keep.txt"
            sentinel.write_text("keep")
            with self.assertRaisesRegex(ApprovalError, "덮어"):
                create_review_catalog(root, staged, output)
            self.assertEqual(sentinel.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
