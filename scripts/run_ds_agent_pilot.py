#!/usr/bin/env python3
"""Run compiled DS-AGENT episodes through the deterministic pilot host.

The current execution mode replays compiler gold calls as an oracle fixture.  It
validates contracts, scope isolation, host behavior, abstention, and trace
integrity.  It is intentionally not a measurement of an LLM or agent policy.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
from typing import Any, Iterable, Mapping, Sequence

try:
    from scripts.ds_agent_tool_host import (
        CONTRACT_VERSION,
        TRACE_SCHEMA_VERSION,
        DeterministicToolHost,
        HostContractError,
        InMemoryPilotRepository,
        TraceRecorder,
        deterministic_verify_answer,
        verify_trace_chain,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from ds_agent_tool_host import (  # type: ignore
        CONTRACT_VERSION,
        TRACE_SCHEMA_VERSION,
        DeterministicToolHost,
        HostContractError,
        InMemoryPilotRepository,
        TraceRecorder,
        deterministic_verify_answer,
        verify_trace_chain,
    )


SCRIPT_VERSION = "0.1.0"
EXECUTION_MODE = "oracle_tool_path_fixture_validation"
SPLITS = ("development", "validation", "frozen-test")
TOOL_ROLE = {
    "search_care_entries": "A1",
    "get_care_entry_details": "A2",
    "get_active_clinician_instructions": "A2",
    "lookup_approved_drug_info": "A3",
    "search_approved_evidence": "A3",
    "open_evidence_spans": "A3",
}


class PilotRunError(ValueError):
    """Raised for immutable bundle, fixture, or run-output violations."""


def _canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def _json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, sort_keys=False, indent=2, allow_nan=False)
        + "\n"
    ).encode("utf-8")


def _jsonl_bytes(values: Iterable[Mapping[str, Any]]) -> bytes:
    return b"".join(_canonical_bytes(value) + b"\n" for value in values)


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _resolve_inside(root: Path, path: Path) -> Path:
    root = root.resolve()
    resolved = path.resolve() if path.is_absolute() else (root / path).resolve()
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise PilotRunError(f"path leaves workspace: {path}") from exc
    return resolved


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PilotRunError(f"cannot read JSON: {path}") from exc
    if not isinstance(value, dict):
        raise PilotRunError(f"JSON root must be an object: {path}")
    return value


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    try:
        with path.open("r", encoding="utf-8") as stream:
            for line_number, line in enumerate(stream, start=1):
                if not line.strip():
                    continue
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise PilotRunError(f"JSONL row must be an object: {path}:{line_number}")
                values.append(value)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PilotRunError(f"cannot read JSONL: {path}") from exc
    return values


def _verify_compiled_bundle(bundle: Path) -> dict[str, Any]:
    manifest_path = bundle / "manifest.json"
    manifest = _read_json(manifest_path)
    if manifest.get("contract", {}).get("version") != CONTRACT_VERSION:
        raise PilotRunError("compiled bundle contract version is unsupported")
    outputs = manifest.get("outputs")
    if not isinstance(outputs, list):
        raise PilotRunError("compiled manifest outputs must be an array")
    seen: set[str] = set()
    for output in outputs:
        if not isinstance(output, dict) or not isinstance(output.get("file"), str):
            raise PilotRunError("invalid compiled output metadata")
        relative = Path(output["file"])
        if relative.is_absolute() or ".." in relative.parts or output["file"] in seen:
            raise PilotRunError("unsafe or duplicate compiled output path")
        seen.add(output["file"])
        path = bundle / relative
        if not path.is_file():
            raise PilotRunError(f"compiled output is missing: {relative}")
        if path.stat().st_size != output.get("bytes"):
            raise PilotRunError(f"compiled output byte count mismatch: {relative}")
        if _sha256_file(path) != output.get("sha256"):
            raise PilotRunError(f"compiled output hash mismatch: {relative}")
        if len(_read_jsonl(path)) != output.get("record_count"):
            raise PilotRunError(f"compiled output record count mismatch: {relative}")
    return manifest


def _write_atomic_tree(output_dir: Path, files: Mapping[str, bytes]) -> None:
    if output_dir.exists():
        raise PilotRunError(f"existing output cannot be overwritten: {output_dir}")
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output_dir.name}.", dir=output_dir.parent))
    try:
        for relative, content in files.items():
            destination = temporary / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("xb") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
        if output_dir.exists():
            raise PilotRunError(f"existing output cannot be overwritten: {output_dir}")
        temporary.rename(output_dir)
    except Exception:
        if temporary.exists():
            shutil.rmtree(temporary)
        raise


def _status_text(status: Any) -> str:
    return {
        "taken": "복용함",
        "missed": "복용하지 못함",
        "refused": "복용을 거부함",
        "held": "보류함",
        "unknown": "복용 여부를 확인하지 못함",
    }.get(str(status), str(status))


def _record_answer(record_pack: Mapping[str, Any], *, medical_required: bool) -> dict[str, Any]:
    records = record_pack.get("relevant_records", [])
    if not isinstance(records, list) or not records:
        return {
            "answer_mode": "abstain",
            "short_answer": "질문과 연결된 확정 간병기록을 찾지 못했습니다.",
            "safe_actions": [],
            "observe": [],
            "contact_guidance": [],
            "questions_for_clinician": [],
            "limitations": ["확정 기록이 없어 내용을 추정하지 않았습니다."],
            "claims": [],
        }
    record = records[0]
    occurred_at = str(record.get("occurred_at", ""))
    try:
        local_time = datetime.fromisoformat(occurred_at.replace("Z", "+00:00")).strftime(
            "%Y-%m-%d %H:%M"
        )
    except ValueError:
        local_time = occurred_at
    record_sentence = f"{local_time}에 {record.get('fact')}으로 기록했습니다."
    limitations: list[str] = []
    answer_mode = "grounded"
    short_answer = record_sentence
    if medical_required:
        answer_mode = "partial"
        short_answer += " 현재 실행에는 승인된 약물 지식 스냅샷이 없어 약의 효능은 설명하지 않습니다."
        limitations.append("승인 근거가 없어 의학적 설명을 보류했습니다.")
    return {
        "answer_mode": answer_mode,
        "short_answer": short_answer,
        "safe_actions": [],
        "observe": [],
        "contact_guidance": [],
        "questions_for_clinician": [],
        "limitations": limitations,
        "claims": [
            {
                "claim_id": "CL-RECORD-001",
                "claim_type": "record_summary",
                "text": record_sentence,
                "importance": "core",
                "evidence_span_ids": [],
                "care_entry_ids": [record["care_entry_id"]],
                "clinician_instruction_ids": [],
            }
        ],
    }


def _run_episode(
    *,
    run_id: str,
    split: str,
    episode: Mapping[str, Any],
    state: Mapping[str, Any],
    entries: Sequence[Mapping[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any]]:
    item_id = str(episode["item_id"])
    trace = TraceRecorder(
        run_id=run_id,
        item_id=item_id,
        split=split,
        contract_version=str(episode["contract_version"]),
    )
    trace.append(
        "trace_started",
        "HOST",
        {
            "execution_mode": EXECUTION_MODE,
            "dataset_item_id": item_id,
            "knowledge_snapshot_id": state.get("knowledge_snapshot_id"),
        },
    )
    trace.append(
        "safety_gate",
        "SAFETY",
        {"result": state.get("safety_gate_result"), "rule_version": "pilot-fixture-0.1.0"},
    )
    if state.get("safety_gate_result") != "continue":
        raise PilotRunError(f"pilot fixture did not pass safety gate: {item_id}")
    selected_patient_id = state.get("selected_patient_id")
    if selected_patient_id != episode.get("selected_patient_id"):
        raise PilotRunError(f"episode/state patient mismatch: {item_id}")
    scoped_entries = [
        entry for entry in entries if entry.get("care_entry_id") in state.get("visible_record_ids", [])
    ]
    repository = InMemoryPilotRepository(
        care_entries=scoped_entries,
        clinician_instructions=[],
        approved_products=[],
        evidence_spans=[],
    )
    host = DeterministicToolHost(
        repository,
        selected_patient_id=str(selected_patient_id),
        visible_record_ids=list(state.get("visible_record_ids", [])),
        reference_time=str(state["reference_time"]),
        knowledge_snapshot_id=state.get("knowledge_snapshot_id"),
        trace=trace,
    )
    trace.append(
        "role_input",
        "A1",
        {
            "question": episode.get("question"),
            "safety_gate_result": "continue",
            "reference_time": state.get("reference_time"),
            "knowledge_snapshot_id": state.get("knowledge_snapshot_id"),
            "allowed_tools": list(episode.get("available_tools", [])),
            "remaining_budget": 8,
        },
    )
    trace.append(
        "role_output",
        "A1",
        {
            "status": "plan_ready",
            "intent": "medication_record_and_general_info"
            if episode.get("scenario_kind") == "record_and_drug_info"
            else "medication_record_lookup",
            "subtasks": ["record_context"]
            + (["approved_drug_evidence"] if episode.get("scenario_kind") == "record_and_drug_info" else []),
            "tool_requests": [
                {
                    "local_call_id": f"call_{index}",
                    "tool_name": call.get("tool_name"),
                    "arguments": call.get("arguments", {}),
                    "reason_code": call.get("reason_code"),
                }
                for index, call in enumerate(episode.get("gold_tool_calls", []), start=1)
            ],
            "clarification_questions": [],
            "completion_conditions": ["record_context_resolved"]
            + (["evidence_coverage_resolved"] if episode.get("scenario_kind") == "record_and_drug_info" else []),
            "out_of_scope_reason": None,
        },
    )
    tool_results: list[dict[str, Any]] = []
    actual_tool_sequence: list[str] = []
    for index, gold_call in enumerate(episode.get("gold_tool_calls", []), start=1):
        tool_name = gold_call.get("tool_name")
        if tool_name not in TOOL_ROLE:
            raise PilotRunError(f"unsupported fixture tool: {tool_name}")
        request = {
            "local_call_id": f"call_{index}",
            "tool_name": tool_name,
            "arguments": gold_call.get("arguments", {}),
            "reason_code": gold_call.get("reason_code"),
        }
        result = host.execute(TOOL_ROLE[tool_name], request)
        tool_results.append(result)
        actual_tool_sequence.append(str(tool_name))
        if result["status"] not in {"ok", "empty"}:
            raise PilotRunError(
                f"oracle fixture tool failed for {item_id}: {tool_name}/{result['error_code']}"
            )
    detail_rows: list[dict[str, Any]] = []
    for result in tool_results:
        if result["tool_name"] == "get_care_entry_details" and result["status"] == "ok":
            detail_rows.extend(result["result"].get("entries", []))
    relevant_records: list[dict[str, Any]] = []
    for row in detail_rows:
        facts = row.get("structured_facts", {})
        intake_status = facts.get("intake_status")
        relevant_records.append(
            {
                "care_entry_id": row["care_entry_id"],
                "entry_version": row.get("entry_version"),
                "occurred_at": row.get("occurred_at"),
                "fact_type": row.get("entry_type"),
                "fact": f"{facts.get('medication_display_name', '기록된 약')}: {_status_text(intake_status)}",
                "polarity": "positive"
                if intake_status == "taken"
                else "unknown"
                if intake_status == "unknown"
                else "negative",
                "value": None,
                "unit": None,
                "certainty": "confirmed",
            }
        )
    record_pack = {
        "status": "complete" if relevant_records else "no_relevant_record",
        "relevant_records": relevant_records,
        "observed_changes": [],
        "missing_context": [],
        "source_record_ids": [row["care_entry_id"] for row in relevant_records],
    }
    trace.append(
        "role_input",
        "A2",
        {
            "tool_result_ids": [
                result["execution_id"]
                for result in tool_results
                if result["tool_name"] in {"search_care_entries", "get_care_entry_details"}
            ]
        },
    )
    trace.append("role_output", "A2", record_pack)
    evidence_pack = {
        "status": "no_evidence",
        "coverage": "none",
        "knowledge_snapshot_id": state.get("knowledge_snapshot_id"),
        "selected_evidence": [],
        "uncovered_aspects": ["general_drug_information"]
        if episode.get("scenario_kind") == "record_and_drug_info"
        else [],
        "conflicts": [],
    }
    medication_name = (
        str(detail_rows[0].get("structured_facts", {}).get("medication_display_name"))
        if detail_rows
        else "확인된 제품"
    )
    trace.append(
        "role_input",
        "A3",
        {
            "generalized_question": f"{medication_name}의 일반적인 제품 정보",
            "knowledge_snapshot_id": state.get("knowledge_snapshot_id"),
        },
    )
    trace.append("role_output", "A3", evidence_pack)
    medical_required = episode.get("scenario_kind") == "record_and_drug_info"
    trace.append(
        "role_input",
        "A4",
        {
            "question": episode.get("question"),
            "record_context_pack": record_pack,
            "evidence_pack": evidence_pack,
            "knowledge_snapshot_id": state.get("knowledge_snapshot_id"),
        },
    )
    answer = _record_answer(record_pack, medical_required=medical_required)
    trace.append("role_output", "A4", answer)
    allowed_record_ids = set(record_pack["source_record_ids"])
    verifier = deterministic_verify_answer(
        answer,
        allowed_record_ids=allowed_record_ids,
        allowed_evidence_ids=set(),
        allowed_instruction_ids=set(),
        evidence_coverage=str(evidence_pack["coverage"]),
        medical_answer_required=medical_required,
    )
    trace.append(
        "role_input",
        "A5",
        {
            "answer_claim_ids": [claim["claim_id"] for claim in answer["claims"]],
            "allowed_record_ids": sorted(allowed_record_ids),
            "allowed_evidence_ids": [],
            "evidence_coverage": evidence_pack["coverage"],
        },
    )
    trace.append("verifier_decision", "A5", verifier)
    if verifier["decision"] == "pass":
        actual_final_status = "record_answer"
    elif verifier["decision"] == "abstain" and allowed_record_ids:
        actual_final_status = "partial_record_answer_then_abstain"
    else:
        actual_final_status = verifier["decision"]
    expected_sequence = [str(call["tool_name"]) for call in episode.get("gold_tool_calls", [])]
    expected_final_status = str(episode.get("expected_final_status"))
    fixture_validation_pass = (
        actual_tool_sequence == expected_sequence
        and actual_final_status == expected_final_status
        and bool(allowed_record_ids)
    )
    hard_gate_passed = (
        verifier["decision"] == "pass"
        or (
            bool(episode.get("should_abstain"))
            and verifier["decision"] == "abstain"
            and "EVIDENCE_NOT_FOUND" in verifier["failure_codes"]
        )
    )
    trace.append(
        "trace_completed",
        "HOST",
        {
            "actual_final_status": actual_final_status,
            "fixture_validation_pass": fixture_validation_pass,
            "hard_gate_passed": hard_gate_passed,
        },
    )
    events = trace.events
    verify_trace_chain(events)
    summary = {
        "schema_version": "1.0",
        "trace_schema_version": TRACE_SCHEMA_VERSION,
        "trace_id": trace.trace_id,
        "run_id": run_id,
        "item_id": item_id,
        "split": split,
        "contract_version": str(episode["contract_version"]),
        "execution_mode": EXECUTION_MODE,
        "expected_final_status": expected_final_status,
        "actual_final_status": actual_final_status,
        "expected_tool_sequence": expected_sequence,
        "actual_tool_sequence": actual_tool_sequence,
        "fixture_validation_pass": fixture_validation_pass,
        "hard_gate_passed": hard_gate_passed,
        "verifier_decision": verifier["decision"],
        "failure_codes": verifier["failure_codes"],
        "event_count": len(events),
        "first_event_sha256": events[0]["event_sha256"],
        "last_event_sha256": events[-1]["event_sha256"],
    }
    final_output = {
        "schema_version": "1.0",
        "trace_id": trace.trace_id,
        "item_id": item_id,
        "split": split,
        "actual_final_status": actual_final_status,
        "answer": answer,
        "verifier": verifier,
        "referenced_records": sorted(allowed_record_ids),
        "citations": [],
    }
    return events, summary, final_output


def run_pilot_bundle(
    workspace_root: Path,
    compiled_bundle_dir: Path,
    output_dir: Path,
    *,
    run_id: str,
    split: str | None = None,
    limit: int | None = None,
) -> Path:
    """Run an immutable compiled candidate through the deterministic host."""

    root = workspace_root.resolve()
    bundle = _resolve_inside(root, compiled_bundle_dir)
    output = _resolve_inside(root, output_dir)
    if output.exists():
        raise PilotRunError(f"existing output cannot be overwritten: {output}")
    if not isinstance(run_id, str) or not run_id.strip():
        raise PilotRunError("run_id is required")
    if split is not None and split not in SPLITS:
        raise PilotRunError(f"unsupported split: {split}")
    if limit is not None and (isinstance(limit, bool) or not isinstance(limit, int) or limit < 1):
        raise PilotRunError("limit must be a positive integer")
    source_manifest = _verify_compiled_bundle(bundle)
    if source_manifest.get("knowledge", {}).get("included") is True:
        raise PilotRunError(
            "runner v0.1.0 only validates the no-approved-knowledge pilot; "
            "approved snapshot loading and grounded citation scoring are not implemented"
        )
    chosen_splits = (split,) if split else SPLITS
    work_items: list[tuple[str, dict[str, Any], dict[str, Any], list[dict[str, Any]]]] = []
    for split_name in chosen_splits:
        states = {
            row["initial_state_id"]: row
            for row in _read_jsonl(bundle / split_name / "states.jsonl")
        }
        entries = _read_jsonl(bundle / split_name / "care_entries.jsonl")
        episodes = _read_jsonl(bundle / split_name / "episodes.jsonl")
        for episode in episodes:
            state = states.get(episode.get("initial_state_id"))
            if state is None:
                raise PilotRunError(f"state not found for {episode.get('item_id')}")
            work_items.append((split_name, episode, state, entries))
    work_items.sort(key=lambda item: (item[0], str(item[1]["item_id"])))
    if limit is not None:
        work_items = work_items[:limit]
    all_events: list[dict[str, Any]] = []
    summaries: list[dict[str, Any]] = []
    final_outputs: list[dict[str, Any]] = []
    for split_name, episode, state, entries in work_items:
        events, summary, final_output = _run_episode(
            run_id=run_id,
            split=split_name,
            episode=episode,
            state=state,
            entries=entries,
        )
        all_events.extend(events)
        summaries.append(summary)
        final_outputs.append(final_output)
    summary_counts = Counter(summary["actual_final_status"] for summary in summaries)
    files = {
        "trace_events.jsonl": _jsonl_bytes(all_events),
        "trace_summaries.jsonl": _jsonl_bytes(summaries),
        "final_outputs.jsonl": _jsonl_bytes(final_outputs),
    }
    outputs = [
        {
            "file": filename,
            "bytes": len(content),
            "sha256": _sha256_bytes(content),
            "record_count": len(all_events)
            if filename == "trace_events.jsonl"
            else len(summaries),
        }
        for filename, content in sorted(files.items())
    ]
    manifest = {
        "schema_version": "1.0",
        "run_id": run_id,
        "runner": {
            "script": "scripts/run_ds_agent_pilot.py",
            "version": SCRIPT_VERSION,
            "execution_mode": EXECUTION_MODE,
            "network_access": False,
        },
        "contract_version": CONTRACT_VERSION,
        "trace_schema_version": TRACE_SCHEMA_VERSION,
        "source_bundle": {
            "dataset_id": source_manifest.get("dataset_id"),
            "manifest_sha256": _sha256_file(bundle / "manifest.json"),
            "review_status": source_manifest.get("review_status"),
            "evaluation_eligible": source_manifest.get("evaluation_eligible"),
        },
        "episode_count": len(summaries),
        "trace_event_count": len(all_events),
        "final_status_counts": dict(sorted(summary_counts.items())),
        "all_fixture_validations_passed": bool(summaries)
        and all(summary["fixture_validation_pass"] for summary in summaries),
        "all_hard_gates_passed": bool(summaries)
        and all(summary["hard_gate_passed"] for summary in summaries),
        "model_performance_result": False,
        "medical_release_gate_result": False,
        "evaluation_eligible": False,
        "usage": {
            "evaluation_only": True,
            "do_not_train": True,
            "mobile_bundle": False,
            "allowed": ["deterministic_host_and_trace_fixture_validation"],
        },
        "limitations": [
            "gold tool calls were replayed; tool-selection performance was not measured",
            "no LLM was invoked",
            "no approved medical snapshot was used in the no-knowledge pilot",
            "compiler-generated unreviewed cases are not release evidence",
        ],
        "outputs": outputs,
    }
    files["manifest.json"] = _json_bytes(manifest)
    _write_atomic_tree(output, files)
    return output


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace-root", type=Path, default=Path.cwd())
    parser.add_argument("--compiled-bundle-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--split", choices=SPLITS)
    parser.add_argument("--limit", type=int)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        output = run_pilot_bundle(
            args.workspace_root,
            args.compiled_bundle_dir,
            args.output_dir,
            run_id=args.run_id,
            split=args.split,
            limit=args.limit,
        )
    except (PilotRunError, HostContractError) as exc:
        print(f"ERROR: {exc}")
        return 1
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
