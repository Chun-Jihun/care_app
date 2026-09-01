from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from scripts.compile_agent_evaluation_scenarios import (
    ScenarioCompileError,
    compile_scenarios,
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


def _output(file: str, content: bytes, count: int | None = None) -> dict[str, object]:
    result: dict[str, object] = {
        "file": file,
        "bytes": len(content),
        "sha256": hashlib.sha256(content).hexdigest(),
    }
    if count is not None:
        result["record_count"] = count
    return result


def _write_source_bundle(root: Path, direct_identifiers: bool = False) -> Path:
    source = root / "source"
    source.mkdir()
    events: list[dict[str, object]] = [
        {
            "schema_version": "1.0",
            "source_event_id": "EVENT-A-1",
            "patient_key": "public_patient_alpha",
            "occurred_at": "2026-01-03T19:00:00+09:00",
            "entry_type": "medication_intake",
            "medication_display_name": "시험약",
            "drug_link": {
                "item_seq": "0001",
                "confirmation_status": "confirmed",
                "confirmation_method": "human_reviewed_mapping",
            },
            "intake_status": "missed",
            "reason_code": "nausea",
            "confirmation_status": "confirmed",
        },
        {
            "schema_version": "1.0",
            "source_event_id": "EVENT-B-1",
            "patient_key": "public_patient_beta",
            "occurred_at": "2026-01-04T08:30:00+09:00",
            "entry_type": "medication_intake",
            "medication_display_name": "시험약",
            "drug_link": {
                "item_seq": "0001",
                "confirmation_status": "unconfirmed",
                "confirmation_method": "string_candidate_only",
            },
            "intake_status": "taken",
            "reason_code": None,
            "confirmation_status": "confirmed",
        },
        {
            "schema_version": "1.0",
            "source_event_id": "EVENT-A-2",
            "patient_key": "public_patient_alpha",
            "occurred_at": "2026-01-05T13:20:00+09:00",
            "entry_type": "medication_intake",
            "medication_display_name": "근거없는약",
            "drug_link": {
                "item_seq": "9999",
                "confirmation_status": "confirmed",
                "confirmation_method": "official_item_seq",
            },
            "intake_status": "refused",
            "reason_code": "refused",
            "confirmation_status": "confirmed",
        },
    ]
    events_bytes = _jsonl_bytes(events)
    (source / "medication_events.jsonl").write_bytes(events_bytes)
    manifest = {
        "schema_version": "1.0",
        "source_id": "PUBLIC-FICTIONAL-001",
        "source_title": "공개 가상 기록 시험 원천",
        "source_url": "https://example.invalid/fictional-source",
        "source_revision": "fixture-v1",
        "source_kind": "fictional",
        "privacy": {
            "direct_identifiers_present": direct_identifiers,
            "patient_keys_pseudonymous": True,
            "free_text_excluded": True,
        },
        "usage": {
            "evaluation_only": True,
            "do_not_train": True,
            "mobile_bundle": False,
        },
        "license": {"status": "reviewed_for_local_evaluation"},
        "outputs": [_output("medication_events.jsonl", events_bytes, len(events))],
    }
    (source / "manifest.json").write_bytes(_json_bytes(manifest))
    return source


def _write_approved_snapshot(root: Path) -> Path:
    approved = root / "approved"
    approved.mkdir()
    products = [
        {
            "schema_version": "1.0",
            "approval_id": "APPROVED-TEST-001",
            "document_id": "MFDS-EASY-0001",
            "product_id": "MFDS-EASY-0001",
            "item_seq": "0001",
            "product_name": "시험약",
            "manufacturer_name": "시험제약",
            "approved_span_ids_by_section": {"effectiveness": ["EV-0001-EFCY"]},
            "review_status": "clinician_approved",
            "reviewed_at": "2026-09-01",
            "next_review_due": "2027-03-01",
            "status": "approved_inactive",
            "runtime_rag_eligible": False,
        }
    ]
    spans = [
        {
            "schema_version": "1.0",
            "approval_id": "APPROVED-TEST-001",
            "span_id": "EV-0001-EFCY",
            "document_id": "MFDS-EASY-0001",
            "product_id": "MFDS-EASY-0001",
            "item_seq": "0001",
            "product_name": "시험약",
            "section": "effectiveness",
            "source_field": "efcyQesitm",
            "source_title": "식품의약품안전처 의약품개요정보(e약은요): 시험약",
            "publisher": "식품의약품안전처",
            "published_or_revised_at": "2026-08-01",
            "retrieved_at": "2026-09-01T00:00:00Z",
            "source_url": "https://www.data.go.kr/data/15075057/openapi.do",
            "location": "efcyQesitm#1",
            "supporting_span": "시험 효능 원문입니다.",
            "source_hash": "sha256:" + hashlib.sha256("시험 효능 원문입니다.".encode()).hexdigest(),
            "parser_version": "0.1.0",
            "license": "시험 이용조건",
            "clinical_scope": ["general_drug_purpose_explanation"],
            "risk_level": "standard",
            "review_status": "clinician_approved",
            "reviewed_at": "2026-09-01",
            "reviewer_roles": ["pharmacist"],
            "next_review_due": "2027-03-01",
            "status": "approved_inactive",
            "runtime_rag_eligible": False,
            "revoked": False,
        }
    ]
    products_bytes = _jsonl_bytes(products)
    spans_bytes = _jsonl_bytes(spans)
    decisions_bytes = _json_bytes({"review": "fixture"})
    (approved / "approved_products.jsonl").write_bytes(products_bytes)
    (approved / "approved_evidence_spans.jsonl").write_bytes(spans_bytes)
    (approved / "review_decisions.json").write_bytes(decisions_bytes)
    manifest = {
        "schema_version": "1.0",
        "approval_id": "APPROVED-TEST-001",
        "approval_state": "approved_snapshot",
        "activation_state": "pending_index_and_regression",
        "runtime_rag_eligible": False,
        "rights_review": {"completed": True, "decision": "approved"},
        "clinical_review": {"completed": True, "reviewer_roles": ["pharmacist"]},
        "usage": {
            "do_not_train": True,
            "mobile_bundle": False,
            "runtime_rag_eligible": False,
            "allowed": ["medical_regression_candidate", "DS_AGENT_evidence_source"],
        },
        "outputs": [
            _output("approved_products.jsonl", products_bytes, len(products)),
            _output("approved_evidence_spans.jsonl", spans_bytes, len(spans)),
            _output("review_decisions.json", decisions_bytes),
        ],
    }
    (approved / "manifest.json").write_bytes(_json_bytes(manifest))
    return approved


def _contract(root: Path) -> Path:
    path = root / "agent_role_and_tool_contracts.md"
    path.write_text("# fixture contract v0.1.0\n", encoding="utf-8")
    return path


def _read_split_records(output: Path, filename: str) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for split in ("development", "validation", "frozen-test"):
        path = output / split / filename
        if path.exists():
            records.extend(
                json.loads(line)
                for line in path.read_text(encoding="utf-8").splitlines()
                if line
            )
    return records


class EvaluationScenarioCompilerTests(unittest.TestCase):
    def test_compiles_record_grounded_and_abstention_episodes(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = _write_source_bundle(root)
            approved = _write_approved_snapshot(root)
            output = compile_scenarios(
                root,
                source,
                root / "compiled",
                _contract(root),
                approved_snapshot_dir=approved,
                split_seed="unit-test-seed",
            )
            manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["review_status"], "compiler_generated_unreviewed")
            self.assertFalse(manifest["evaluation_eligible"])
            self.assertTrue(manifest["usage"]["do_not_train"])
            self.assertFalse(manifest["usage"]["mobile_bundle"])

            episodes = _read_split_records(output, "episodes.jsonl")
            self.assertEqual(len(episodes), 6)
            grounded = [
                episode
                for episode in episodes
                if episode["scenario_kind"] == "record_and_drug_info"
                and episode["expected_evidence_ids"]
            ]
            self.assertEqual(len(grounded), 1)
            self.assertEqual(grounded[0]["expected_evidence_ids"], ["EV-0001-EFCY"])
            self.assertFalse(grounded[0]["should_abstain"])
            self.assertIn(
                "lookup_approved_drug_info", grounded[0]["allowed_call_sequences"][0]
            )

            abstentions = [
                episode
                for episode in episodes
                if episode["scenario_kind"] == "record_and_drug_info"
                and episode["should_abstain"]
            ]
            self.assertEqual(len(abstentions), 2)
            self.assertTrue(all(not episode["expected_evidence_ids"] for episode in abstentions))

    def test_unconfirmed_same_name_is_never_fuzzy_matched(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = compile_scenarios(
                root,
                _write_source_bundle(root),
                root / "compiled",
                _contract(root),
                approved_snapshot_dir=_write_approved_snapshot(root),
            )
            episodes = _read_split_records(output, "episodes.jsonl")
            beta_info = [
                episode
                for episode in episodes
                if episode["scenario_kind"] == "record_and_drug_info"
                and "복용했다고" in episode["question"]
            ]
            self.assertEqual(len(beta_info), 1)
            self.assertTrue(beta_info[0]["should_abstain"])
            self.assertEqual(beta_info[0]["expected_evidence_ids"], [])
            lookup_calls = [
                call
                for call in beta_info[0]["gold_tool_calls"]
                if call["tool_name"] == "lookup_approved_drug_info"
            ]
            self.assertEqual(lookup_calls, [])

    def test_source_keys_and_direct_identifiers_do_not_enter_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = compile_scenarios(
                root,
                _write_source_bundle(root),
                root / "compiled",
                _contract(root),
            )
            serialized = "\n".join(
                path.read_text(encoding="utf-8")
                for path in output.rglob("*.json*")
            )
            manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["summary"]["medical_episode_count"], 0)
            self.assertEqual(manifest["summary"]["record_only_episode_count"], 3)
            self.assertNotIn("public_patient_alpha", serialized)
            self.assertNotIn("public_patient_beta", serialized)
            self.assertNotIn("EVENT-A-1", serialized)

            unsafe_root = root / "unsafe"
            unsafe_root.mkdir()
            unsafe_source = _write_source_bundle(unsafe_root, direct_identifiers=True)
            with self.assertRaisesRegex(ScenarioCompileError, "식별|identifier|privacy"):
                compile_scenarios(
                    unsafe_root,
                    unsafe_source,
                    unsafe_root / "compiled",
                    _contract(unsafe_root),
                )

    def test_tampered_approved_evidence_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = _write_source_bundle(root)
            approved = _write_approved_snapshot(root)
            with (approved / "approved_evidence_spans.jsonl").open("ab") as stream:
                stream.write(b" ")
            with self.assertRaisesRegex(ScenarioCompileError, "SHA-256|크기"):
                compile_scenarios(
                    root,
                    source,
                    root / "compiled",
                    _contract(root),
                    approved_snapshot_dir=approved,
                )

    def test_staged_unreviewed_knowledge_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = _write_source_bundle(root)
            staged = _write_approved_snapshot(root)
            manifest_path = staged / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["approval_state"] = "staged_unreviewed"
            manifest_path.write_bytes(_json_bytes(manifest))
            with self.assertRaisesRegex(ScenarioCompileError, "approved_snapshot|승인"):
                compile_scenarios(
                    root,
                    source,
                    root / "compiled",
                    _contract(root),
                    approved_snapshot_dir=staged,
                )

    def test_patient_group_never_crosses_splits(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = compile_scenarios(
                root,
                _write_source_bundle(root),
                root / "compiled",
                _contract(root),
                approved_snapshot_dir=_write_approved_snapshot(root),
                split_seed="group-test",
            )
            patient_splits: dict[str, set[str]] = {}
            group_splits: dict[str, set[str]] = {}
            for split in ("development", "validation", "frozen-test"):
                for entry in _read_jsonl(output / split / "care_entries.jsonl"):
                    patient_splits.setdefault(entry["patient_id"], set()).add(split)
                for episode in _read_jsonl(output / split / "episodes.jsonl"):
                    group_splits.setdefault(episode["episode_group_id"], set()).add(split)
            self.assertTrue(all(len(splits) == 1 for splits in patient_splits.values()))
            self.assertTrue(all(len(splits) == 1 for splits in group_splits.values()))

    def test_compilation_is_deterministic_and_refuses_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = _write_source_bundle(root)
            approved = _write_approved_snapshot(root)
            contract = _contract(root)
            first = compile_scenarios(
                root,
                source,
                root / "compiled-1",
                contract,
                approved_snapshot_dir=approved,
                split_seed="stable",
            )
            second = compile_scenarios(
                root,
                source,
                root / "compiled-2",
                contract,
                approved_snapshot_dir=approved,
                split_seed="stable",
            )
            first_files = {
                path.relative_to(first).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in first.rglob("*")
                if path.is_file()
            }
            second_files = {
                path.relative_to(second).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in second.rglob("*")
                if path.is_file()
            }
            self.assertEqual(first_files, second_files)
            with self.assertRaisesRegex(ScenarioCompileError, "덮어"):
                compile_scenarios(
                    root,
                    source,
                    first,
                    contract,
                    approved_snapshot_dir=approved,
                )


def _read_jsonl(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line
    ]


if __name__ == "__main__":
    unittest.main()
