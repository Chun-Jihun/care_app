#!/usr/bin/env python3
"""Run immutable DS-AGENT bundles with A1--A5 local-model JSON contracts.

This is an evaluation-only runner.  It persists validated contract objects,
deterministic tool traces, output hashes and usage metadata; it does not persist
raw prompts or raw model generations.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
from typing import Any, Mapping, Sequence

try:
    from scripts.compile_agent_evaluation_scenarios import (
        ScenarioCompileError,
        _validate_approved_snapshot,
    )
    from scripts.ds_agent_model_runner import (
        EXECUTION_MODE,
        ModelRunnerError,
        Qwen35Nf4Backend,
        ReplayRoleBackend,
        RoleModelBackend,
        run_model_episode,
    )
    from scripts.ds_agent_tool_host import (
        CONTRACT_VERSION,
        TRACE_SCHEMA_VERSION,
        HostContractError,
        InMemoryPilotRepository,
    )
    from scripts.run_ds_agent_pilot import (
        SPLITS,
        PilotRunError,
        _json_bytes,
        _jsonl_bytes,
        _read_jsonl,
        _resolve_inside,
        _sha256_bytes,
        _sha256_file,
        _verify_compiled_bundle,
        _write_atomic_tree,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from compile_agent_evaluation_scenarios import (  # type: ignore
        ScenarioCompileError,
        _validate_approved_snapshot,
    )
    from ds_agent_model_runner import (  # type: ignore
        EXECUTION_MODE,
        ModelRunnerError,
        Qwen35Nf4Backend,
        ReplayRoleBackend,
        RoleModelBackend,
        run_model_episode,
    )
    from ds_agent_tool_host import (  # type: ignore
        CONTRACT_VERSION,
        TRACE_SCHEMA_VERSION,
        HostContractError,
        InMemoryPilotRepository,
    )
    from run_ds_agent_pilot import (  # type: ignore
        SPLITS,
        PilotRunError,
        _json_bytes,
        _jsonl_bytes,
        _read_jsonl,
        _resolve_inside,
        _sha256_bytes,
        _sha256_file,
        _verify_compiled_bundle,
        _write_atomic_tree,
    )


SCRIPT_VERSION = "0.1.0"


def _declared_output_files(manifest: Mapping[str, Any]) -> set[str]:
    outputs = manifest.get("outputs", [])
    if not isinstance(outputs, list):
        return set()
    return {
        str(value["file"])
        for value in outputs
        if isinstance(value, Mapping) and isinstance(value.get("file"), str)
    }


def _load_knowledge(
    root: Path, source_manifest: Mapping[str, Any]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    knowledge = source_manifest.get("knowledge")
    if not isinstance(knowledge, Mapping):
        raise ModelRunnerError("compiled bundle knowledge metadata is invalid")
    if knowledge.get("included") is not True:
        if any(
            knowledge.get(field) is not None
            for field in (
                "approval_id",
                "approved_snapshot_local_path",
                "approved_manifest_sha256",
            )
        ):
            raise ModelRunnerError("excluded knowledge must not declare a snapshot")
        return [], [], {"included": False, "approval_id": None}

    relative = knowledge.get("approved_snapshot_local_path")
    declared_hash = knowledge.get("approved_manifest_sha256")
    approval_id = knowledge.get("approval_id")
    if not all(isinstance(value, str) and value for value in (relative, declared_hash, approval_id)):
        raise ModelRunnerError("included knowledge requires path, hash and approval_id")
    approved_dir = _resolve_inside(root, Path(str(relative)))
    approved_manifest, products, _, actual_hash = _validate_approved_snapshot(approved_dir)
    if actual_hash != declared_hash:
        raise ModelRunnerError("approved snapshot manifest hash changed after compilation")
    if approved_manifest.get("approval_id") != approval_id:
        raise ModelRunnerError("approved snapshot ID changed after compilation")
    spans = _read_jsonl(approved_dir / "approved_evidence_spans.jsonl")
    return (
        [dict(value) for value in products.values()],
        spans,
        {
            "included": True,
            "approval_id": approval_id,
            "manifest_sha256": actual_hash,
        },
    )


def _attach_expected_checks(
    summary: dict[str, Any], final_output: Mapping[str, Any], episode: Mapping[str, Any]
) -> None:
    allowed_sequences = episode.get("allowed_call_sequences", [])
    actual_sequence = summary.get("actual_tool_sequence", [])
    expected_records = {
        str(value) for value in episode.get("expected_record_ids", []) if isinstance(value, str)
    }
    actual_records = {
        str(value)
        for value in final_output.get("referenced_records", [])
        if isinstance(value, str)
    }
    expected_evidence = {
        str(value)
        for value in episode.get("expected_evidence_ids", [])
        if isinstance(value, str)
    }
    actual_evidence = {
        str(value.get("evidence_span_id"))
        for value in final_output.get("citations", [])
        if isinstance(value, Mapping) and isinstance(value.get("evidence_span_id"), str)
    }
    checks = {
        "expected_final_status_match": (
            summary.get("actual_final_status") == episode.get("expected_final_status")
        ),
        "allowed_tool_sequence_match": (
            isinstance(allowed_sequences, list)
            and any(actual_sequence == sequence for sequence in allowed_sequences)
        ),
        "expected_records_referenced": expected_records.issubset(actual_records),
        "expected_evidence_cited": expected_evidence.issubset(actual_evidence),
    }
    summary["expected_checks"] = checks
    summary["all_expected_checks_passed"] = all(checks.values())
    summary["source_review_status"] = episode.get("review_status")
    summary["source_evaluation_eligible"] = episode.get("evaluation_eligible") is True


def run_model_bundle(
    workspace_root: Path,
    compiled_bundle_dir: Path,
    output_dir: Path,
    *,
    run_id: str,
    backend: RoleModelBackend,
    split: str | None = None,
    limit: int | None = None,
) -> Path:
    """Run a verified compiled bundle without mutating it or its source assets."""

    root = workspace_root.resolve()
    bundle = _resolve_inside(root, compiled_bundle_dir)
    output = _resolve_inside(root, output_dir)
    if output.exists():
        raise ModelRunnerError(f"existing output cannot be overwritten: {output}")
    if not isinstance(run_id, str) or not run_id.strip():
        raise ModelRunnerError("run_id is required")
    if split is not None and split not in SPLITS:
        raise ModelRunnerError(f"unsupported split: {split}")
    if limit is not None and (isinstance(limit, bool) or not isinstance(limit, int) or limit < 1):
        raise ModelRunnerError("limit must be a positive integer")

    source_manifest = _verify_compiled_bundle(bundle)
    approved_products, evidence_spans, knowledge = _load_knowledge(root, source_manifest)
    declared_files = _declared_output_files(source_manifest)
    chosen_splits = (split,) if split else SPLITS
    work_items: list[
        tuple[str, dict[str, Any], dict[str, Any], list[dict[str, Any]], list[dict[str, Any]]]
    ] = []
    for split_name in chosen_splits:
        states = {
            str(row["initial_state_id"]): row
            for row in _read_jsonl(bundle / split_name / "states.jsonl")
        }
        entries = _read_jsonl(bundle / split_name / "care_entries.jsonl")
        instruction_file = f"{split_name}/clinician_instructions.jsonl"
        instructions = (
            _read_jsonl(bundle / instruction_file) if instruction_file in declared_files else []
        )
        for episode in _read_jsonl(bundle / split_name / "episodes.jsonl"):
            state = states.get(str(episode.get("initial_state_id")))
            if state is None:
                raise ModelRunnerError(f"state not found for {episode.get('item_id')}")
            work_items.append((split_name, episode, state, entries, instructions))
    work_items.sort(key=lambda value: (value[0], str(value[1].get("item_id"))))
    if limit is not None:
        work_items = work_items[:limit]

    all_events: list[dict[str, Any]] = []
    summaries: list[dict[str, Any]] = []
    final_outputs: list[dict[str, Any]] = []
    model_calls: list[dict[str, Any]] = []
    for split_name, episode, state, entries, instructions in work_items:
        state_snapshot = state.get("knowledge_snapshot_id")
        if state_snapshot != knowledge["approval_id"]:
            raise ModelRunnerError(
                f"state knowledge snapshot mismatch: {episode.get('item_id')}"
            )
        repository = InMemoryPilotRepository(
            care_entries=entries,
            clinician_instructions=instructions,
            approved_products=approved_products,
            evidence_spans=evidence_spans,
        )
        events, summary, final_output, calls = run_model_episode(
            run_id=run_id,
            split=split_name,
            episode=episode,
            state=state,
            repository=repository,
            backend=backend,
        )
        _attach_expected_checks(summary, final_output, episode)
        all_events.extend(events)
        summaries.append(summary)
        final_outputs.append(final_output)
        model_calls.extend(calls)

    files = {
        "trace_events.jsonl": _jsonl_bytes(all_events),
        "trace_summaries.jsonl": _jsonl_bytes(summaries),
        "final_outputs.jsonl": _jsonl_bytes(final_outputs),
        "model_calls.jsonl": _jsonl_bytes(model_calls),
    }
    record_counts = {
        "trace_events.jsonl": len(all_events),
        "trace_summaries.jsonl": len(summaries),
        "final_outputs.jsonl": len(final_outputs),
        "model_calls.jsonl": len(model_calls),
    }
    outputs = [
        {
            "file": name,
            "bytes": len(content),
            "sha256": _sha256_bytes(content),
            "record_count": record_counts[name],
        }
        for name, content in sorted(files.items())
    ]
    status_counts = Counter(str(value["actual_final_status"]) for value in summaries)
    role_call_counts = Counter(str(value["role_id"]) for value in model_calls)
    source_eligible = source_manifest.get("evaluation_eligible") is True
    backend_metadata = dict(backend.metadata)
    actual_local_model_invoked = backend_metadata.get("backend") != "replay_role_outputs"
    manifest = {
        "schema_version": "1.0",
        "run_id": run_id,
        "runner": {
            "script": "scripts/run_ds_agent_model.py",
            "version": SCRIPT_VERSION,
            "execution_mode": EXECUTION_MODE,
            "network_access": False,
            "actual_local_model_invoked": actual_local_model_invoked,
            "raw_prompt_persisted": False,
            "raw_generation_persisted": False,
        },
        "backend": backend_metadata,
        "contract_version": CONTRACT_VERSION,
        "trace_schema_version": TRACE_SCHEMA_VERSION,
        "source_bundle": {
            "dataset_id": source_manifest.get("dataset_id"),
            "manifest_sha256": _sha256_file(bundle / "manifest.json"),
            "review_status": source_manifest.get("review_status"),
            "evaluation_eligible": source_eligible,
        },
        "knowledge": knowledge,
        "episode_count": len(summaries),
        "trace_event_count": len(all_events),
        "model_call_count": len(model_calls),
        "model_role_call_counts": dict(sorted(role_call_counts.items())),
        "final_status_counts": dict(sorted(status_counts.items())),
        "all_expected_checks_passed": bool(summaries)
        and all(value["all_expected_checks_passed"] for value in summaries),
        "model_performance_result": False,
        "medical_release_gate_result": False,
        "evaluation_eligible": source_eligible,
        "usage": {
            "evaluation_only": True,
            "do_not_train": True,
            "mobile_bundle": False,
            "allowed": ["A1_to_A5_local_model_trace_generation"],
        },
        "limitations": [
            "this runner emits raw evaluation artifacts; a separate scorer is required",
            "compiler-generated unreviewed cases are not model-performance or release evidence",
            "validated parsed role objects are stored in traces, but raw prompts and generations are not",
        ],
        "outputs": outputs,
    }
    files["manifest.json"] = _json_bytes(manifest)
    _write_atomic_tree(output, files)
    return output


def _load_replay_backend(root: Path, replay_path: Path) -> ReplayRoleBackend:
    path = _resolve_inside(root, replay_path)
    return ReplayRoleBackend(_read_jsonl(path), source_sha256=_sha256_file(path))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace-root", type=Path, default=Path.cwd())
    parser.add_argument("--compiled-bundle-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--split", choices=SPLITS)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--backend", choices=("qwen35-nf4", "replay"), required=True)
    parser.add_argument("--replay-jsonl", type=Path)
    parser.add_argument(
        "--runtime-profile",
        type=Path,
        default=Path("experiments/agent_eval/manifests/runtime_profiles.json"),
    )
    parser.add_argument("--runtime-profile-id", default="RT-M1-HF-BNB-NF4-WIN-001")
    parser.add_argument(
        "--generation-profile",
        choices=("smoke", "primary_scored", "supplier_recommended_secondary"),
        default="primary_scored",
    )
    parser.add_argument("--seed", type=int)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root = args.workspace_root.resolve()
    try:
        if args.backend == "replay":
            if args.replay_jsonl is None:
                raise ModelRunnerError("--replay-jsonl is required for replay backend")
            backend: RoleModelBackend = _load_replay_backend(root, args.replay_jsonl)
        else:
            if args.replay_jsonl is not None:
                raise ModelRunnerError("--replay-jsonl is only valid for replay backend")
            profile_path = _resolve_inside(root, args.runtime_profile)
            backend = Qwen35Nf4Backend(
                root,
                profile_path,
                profile_id=args.runtime_profile_id,
                generation_profile=args.generation_profile,
                seed=args.seed,
            )
        output = run_model_bundle(
            root,
            args.compiled_bundle_dir,
            args.output_dir,
            run_id=args.run_id,
            backend=backend,
            split=args.split,
            limit=args.limit,
        )
    except (
        ModelRunnerError,
        PilotRunError,
        HostContractError,
        ScenarioCompileError,
        OSError,
        json.JSONDecodeError,
    ) as exc:
        print(f"ERROR: {exc}")
        return 1
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = ["build_parser", "run_model_bundle"]
