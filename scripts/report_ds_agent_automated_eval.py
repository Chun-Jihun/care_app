#!/usr/bin/env python3
"""Verify and aggregate DS-AGENT T0--T3 automated development diagnostics.

This scorer deliberately refuses to turn unreviewed compiler fixtures into a
medical performance or release result. It validates immutable artifacts, trace
chains and project-oracle checks, then reports contract behavior and runtime
costs only.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path
from statistics import mean
from typing import Any, Iterable, Mapping, Sequence

try:
    from scripts.ds_agent_tool_host import HostContractError, verify_trace_chain
    from scripts.run_ds_agent_pilot import (
        SPLITS,
        _json_bytes,
        _read_jsonl,
        _resolve_inside,
        _sha256_file,
        _verify_compiled_bundle,
        _write_atomic_tree,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from ds_agent_tool_host import HostContractError, verify_trace_chain  # type: ignore
    from run_ds_agent_pilot import (  # type: ignore
        SPLITS,
        _json_bytes,
        _read_jsonl,
        _resolve_inside,
        _sha256_file,
        _verify_compiled_bundle,
        _write_atomic_tree,
    )


SCRIPT_VERSION = "0.1.0"
EXPECTED_SPLIT_COUNTS = {"development": 28, "validation": 14, "frozen-test": 6}
EXPECTED_TOTAL = sum(EXPECTED_SPLIT_COUNTS.values())


class AutomatedEvalReportError(RuntimeError):
    """Raised when an input run cannot support a trustworthy automated report."""


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AutomatedEvalReportError(f"cannot read JSON: {path}") from exc
    if not isinstance(value, dict):
        raise AutomatedEvalReportError(f"JSON root must be an object: {path}")
    return value


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    try:
        with path.open("r", encoding="utf-8") as stream:
            for line_number, line in enumerate(stream, start=1):
                if not line.strip():
                    continue
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise AutomatedEvalReportError(
                        f"JSONL row must be an object: {path}:{line_number}"
                    )
                rows.append(value)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AutomatedEvalReportError(f"cannot read JSONL: {path}") from exc
    return rows


def _percentile95(values: Sequence[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)], 3)


def _rate(numerator: int, denominator: int) -> dict[str, Any]:
    return {
        "passed": numerator,
        "total": denominator,
        "rate": round(numerator / denominator, 6) if denominator else None,
    }


def _verify_declared_outputs(run_dir: Path, manifest: Mapping[str, Any]) -> None:
    outputs = manifest.get("outputs")
    if not isinstance(outputs, list) or not outputs:
        raise AutomatedEvalReportError(f"run manifest has no declared outputs: {run_dir}")
    for row in outputs:
        if not isinstance(row, Mapping) or not isinstance(row.get("file"), str):
            raise AutomatedEvalReportError(f"invalid output declaration: {run_dir}")
        relative = Path(str(row["file"]))
        if relative.is_absolute() or ".." in relative.parts:
            raise AutomatedEvalReportError(f"unsafe output declaration: {relative}")
        path = (run_dir / relative).resolve()
        if not path.is_relative_to(run_dir) or not path.is_file():
            raise AutomatedEvalReportError(f"declared output is missing: {path}")
        if path.stat().st_size != row.get("bytes") or _sha256_file(path) != row.get("sha256"):
            raise AutomatedEvalReportError(f"declared output hash or size changed: {path}")
        declared_count = row.get("record_count")
        if isinstance(declared_count, int) and relative.suffix == ".jsonl":
            actual_count = sum(1 for line in path.read_text(encoding="utf-8").splitlines() if line)
            if actual_count != declared_count:
                raise AutomatedEvalReportError(f"declared record count changed: {path}")


def _verify_traces(
    events: Sequence[Mapping[str, Any]], summaries: Sequence[Mapping[str, Any]]
) -> None:
    grouped: defaultdict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for event in events:
        grouped[str(event.get("trace_id"))].append(event)
    if len(grouped) != len(summaries):
        raise AutomatedEvalReportError("trace and summary counts differ")
    by_trace = {str(row.get("trace_id")): row for row in summaries}
    if len(by_trace) != len(summaries) or set(grouped) != set(by_trace):
        raise AutomatedEvalReportError("trace IDs are missing or duplicated")
    for trace_id, trace_events in grouped.items():
        ordered = sorted(trace_events, key=lambda value: int(value.get("sequence", 0)))
        verify_trace_chain(ordered)
        summary = by_trace[trace_id]
        if (
            summary.get("event_count") != len(ordered)
            or summary.get("first_event_sha256") != ordered[0].get("event_sha256")
            or summary.get("last_event_sha256") != ordered[-1].get("event_sha256")
        ):
            raise AutomatedEvalReportError(f"trace summary hash mismatch: {trace_id}")


def _infer_topology(manifest: Mapping[str, Any]) -> str:
    topology = manifest.get("topology")
    if isinstance(topology, Mapping) and topology.get("id") in {"T1", "T2", "T3"}:
        return str(topology["id"])
    runner = manifest.get("runner")
    script = str(runner.get("script")) if isinstance(runner, Mapping) else ""
    if script.endswith("run_ds_agent_pilot.py"):
        return "T0"
    if script.endswith("run_ds_agent_model.py"):
        return "T3-legacy"
    raise AutomatedEvalReportError("cannot infer run topology")


def _normalized_checks(summary: Mapping[str, Any], topology_id: str) -> dict[str, bool]:
    checks = summary.get("expected_checks")
    if isinstance(checks, Mapping):
        return {
            "expected_final_status_match": checks.get("expected_final_status_match") is True,
            "allowed_tool_sequence_match": checks.get("allowed_tool_sequence_match") is True,
            "expected_records_referenced": checks.get("expected_records_referenced") is True,
            "expected_evidence_cited": checks.get("expected_evidence_cited") is True,
        }
    if topology_id == "T0":
        expected_sequence = summary.get("expected_tool_sequence")
        actual_sequence = summary.get("actual_tool_sequence")
        return {
            "expected_final_status_match": (
                summary.get("actual_final_status") == summary.get("expected_final_status")
            ),
            "allowed_tool_sequence_match": expected_sequence == actual_sequence,
            "expected_records_referenced": summary.get("fixture_validation_pass") is True,
            "expected_evidence_cited": True,
        }
    raise AutomatedEvalReportError(
        f"model summary lacks expected checks: {summary.get('item_id')}"
    )


def _failure_category(code: str) -> str:
    if "SCHEMA" in code or "JSON_PARSE" in code or "FORMAT" in code:
        return "model_contract_format"
    if code in {"CONTEXT_DISTORTION", "RECORD_NOT_FOUND"}:
        return "record_context_preservation"
    if any(token in code for token in ("EVIDENCE", "CITATION", "UNSUPPORTED")):
        return "evidence_or_grounding"
    if any(token in code for token in ("TOOL", "SCOPE", "ARGUMENT", "CAPABILITY")):
        return "tool_or_scope_contract"
    if any(token in code for token in ("PROHIBITED", "SAFETY", "POLICY")):
        return "safety_policy"
    return "answer_or_verifier_policy"


def _normalized_tool_call(value: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "tool_name": value.get("tool_name"),
        "arguments": value.get("arguments"),
        "reason_code": value.get("reason_code"),
    }


def _a1_tool_calls(events: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    for event in events:
        if event.get("event_type") == "role_output" and event.get("role_id") == "A1":
            payload = event.get("payload")
            requests = payload.get("tool_requests") if isinstance(payload, Mapping) else None
            if isinstance(requests, list):
                return [
                    _normalized_tool_call(value)
                    for value in requests
                    if isinstance(value, Mapping)
                ]
    return []


def _failure_attribution(
    summary: Mapping[str, Any],
    checks: Mapping[str, bool],
    events: Sequence[Mapping[str, Any]],
    calls: Sequence[Mapping[str, Any]],
) -> list[str]:
    causes: list[str] = []
    if any(
        event.get("event_type") == "tool_result"
        and isinstance(event.get("payload"), Mapping)
        and event["payload"].get("tool_name") == "search_care_entries"
        and event["payload"].get("status") == "empty"
        for event in events
    ):
        causes.append("a1_search_returned_empty")
    if not checks["allowed_tool_sequence_match"]:
        causes.append("a1_or_host_tool_sequence_mismatch")
    if not checks["expected_records_referenced"]:
        causes.append("record_retrieval_or_context_preservation_failure")
    codes = [str(value) for value in summary.get("failure_codes", [])]
    if "CONTEXT_DISTORTION" in codes:
        causes.append("a2_context_distortion_detected")
    if any(code in {"CITATION_MISMATCH", "UNSUPPORTED_CLAIM"} for code in codes):
        causes.append("a3_or_a4_grounding_contract_failure")
    if not checks["expected_final_status_match"] and checks["expected_records_referenced"]:
        causes.append("a4_or_a5_status_mismatch_after_record_retrieval")
    if any(str(call.get("status")) in {"parse_error", "schema_error"} for call in calls):
        causes.append("model_json_contract_repair_or_failure")
    if not causes:
        causes.append("unclassified_contract_mismatch")
    return list(dict.fromkeys(causes))


def _load_run(run_dir: Path) -> dict[str, Any]:
    manifest = _read_json(run_dir / "manifest.json")
    if (
        manifest.get("evaluation_eligible") is True
        or manifest.get("model_performance_result") is True
        or manifest.get("medical_release_gate_result") is True
    ):
        raise AutomatedEvalReportError(
            "automated diagnostic refuses inputs already labelled as scored or release evidence"
        )
    _verify_declared_outputs(run_dir, manifest)
    summaries = _read_jsonl(run_dir / "trace_summaries.jsonl")
    events = _read_jsonl(run_dir / "trace_events.jsonl")
    final_outputs = _read_jsonl(run_dir / "final_outputs.jsonl")
    calls_path = run_dir / "model_calls.jsonl"
    calls = _read_jsonl(calls_path) if calls_path.is_file() else []
    _verify_traces(events, summaries)
    if len(summaries) != len(final_outputs) or len(summaries) != manifest.get("episode_count"):
        raise AutomatedEvalReportError(f"episode artifacts are incomplete: {run_dir}")
    summary_items = {str(row.get("item_id")) for row in summaries}
    output_items = {str(row.get("item_id")) for row in final_outputs}
    if len(summary_items) != len(summaries) or summary_items != output_items:
        raise AutomatedEvalReportError(f"episode IDs are missing or duplicated: {run_dir}")
    return {
        "path": run_dir,
        "manifest": manifest,
        "manifest_sha256": _sha256_file(run_dir / "manifest.json"),
        "topology_id": _infer_topology(manifest),
        "summaries": summaries,
        "events": events,
        "calls": calls,
    }


def _aggregate_topology(
    topology_id: str,
    runs: Sequence[Mapping[str, Any]],
    episode_oracles: Mapping[str, Mapping[str, Any]] | None = None,
) -> dict[str, Any]:
    summaries = [row for run in runs for row in run["summaries"]]
    calls = [row for run in runs for row in run["calls"]]
    events = [row for run in runs for row in run["events"]]
    events_by_item: defaultdict[str, list[Mapping[str, Any]]] = defaultdict(list)
    calls_by_item: defaultdict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for event in events:
        events_by_item[str(event.get("item_id"))].append(event)
    for call in calls:
        calls_by_item[str(call.get("item_id"))].append(call)
    item_ids = [str(row.get("item_id")) for row in summaries]
    if len(item_ids) != len(set(item_ids)):
        raise AutomatedEvalReportError(f"duplicate item across {topology_id} runs")
    split_counts = Counter(str(row.get("split")) for row in summaries)
    check_names = (
        "expected_final_status_match",
        "allowed_tool_sequence_match",
        "expected_records_referenced",
        "expected_evidence_cited",
    )
    check_counts = Counter()
    failed_items: list[dict[str, Any]] = []
    failure_codes: Counter[str] = Counter()
    failure_categories: Counter[str] = Counter()
    failure_attribution: Counter[str] = Counter()
    a1_exact_pass = 0
    a1_exact_total = 0
    for summary in summaries:
        item_id = str(summary.get("item_id"))
        checks = _normalized_checks(summary, topology_id)
        for name in check_names:
            check_counts[name] += int(checks[name])
        codes = [str(value) for value in summary.get("failure_codes", [])]
        for code in codes:
            failure_codes[code] += 1
            failure_categories[_failure_category(code)] += 1
        failed = [name for name, passed in checks.items() if not passed]
        a1_exact: bool | None = None
        if episode_oracles is not None and topology_id != "T0":
            oracle = episode_oracles.get(item_id)
            if oracle is None:
                raise AutomatedEvalReportError(f"episode oracle is missing: {item_id}")
            gold = [
                _normalized_tool_call(value)
                for value in oracle.get("gold_tool_calls", [])
                if isinstance(value, Mapping)
                and value.get("tool_name") == "search_care_entries"
            ]
            actual = _a1_tool_calls(events_by_item[item_id])
            a1_exact = actual == gold
            a1_exact_total += 1
            a1_exact_pass += int(a1_exact)
        if failed:
            attributions = _failure_attribution(
                summary,
                checks,
                events_by_item[item_id],
                calls_by_item[item_id],
            )
            for cause in attributions:
                failure_attribution[cause] += 1
            failed_items.append(
                {
                    "item_id": item_id,
                    "split": summary.get("split"),
                    "failed_checks": failed,
                    "failure_codes": codes,
                    "failure_attribution": attributions,
                    "a1_gold_request_exact_match": a1_exact,
                }
            )
    call_status = Counter(str(row.get("status")) for row in calls)
    role_calls = Counter(str(row.get("role_id")) for row in calls)
    role_errors: defaultdict[str, Counter[str]] = defaultdict(Counter)
    generation_ms: list[float] = []
    episode_generation: Counter[str] = Counter()
    input_tokens = 0
    output_tokens = 0
    peak_vram = 0
    throughput: list[float] = []
    for call in calls:
        role_id = str(call.get("role_id"))
        if call.get("status") != "ok":
            role_errors[role_id][str(call.get("status"))] += 1
        usage = call.get("usage")
        if not isinstance(usage, Mapping):
            continue
        wall = usage.get("generation_wall_time_ms")
        if isinstance(wall, (int, float)) and not isinstance(wall, bool):
            generation_ms.append(float(wall))
            episode_generation[str(call.get("item_id"))] += float(wall)
        for field, target in (("input_tokens", "input"), ("output_tokens", "output")):
            value = usage.get(field)
            if isinstance(value, int) and not isinstance(value, bool):
                if target == "input":
                    input_tokens += value
                else:
                    output_tokens += value
        vram = usage.get("peak_vram_bytes")
        if isinstance(vram, int) and not isinstance(vram, bool):
            peak_vram = max(peak_vram, vram)
        speed = usage.get("output_tokens_per_second")
        if isinstance(speed, (int, float)) and not isinstance(speed, bool):
            throughput.append(float(speed))
    total = len(summaries)
    complete_split_set = dict(split_counts) == EXPECTED_SPLIT_COUNTS
    all_check_pass = all(check_counts[name] == total for name in check_names) if total else False
    return {
        "topology_id": topology_id,
        "run_ids": [run["manifest"].get("run_id") for run in runs],
        "episode_count": total,
        "split_counts": dict(sorted(split_counts.items())),
        "standard_48_complete": complete_split_set and total == EXPECTED_TOTAL,
        "contract_checks": {name: _rate(check_counts[name], total) for name in check_names},
        "all_contract_checks_passed": all_check_pass,
        "final_status_counts": dict(
            sorted(Counter(str(row.get("actual_final_status")) for row in summaries).items())
        ),
        "failure_codes": dict(sorted(failure_codes.items())),
        "failure_categories": dict(sorted(failure_categories.items())),
        "failure_attribution": dict(sorted(failure_attribution.items())),
        "oracle_diagnostics": {
            "a1_gold_request_exact_match": (
                _rate(a1_exact_pass, a1_exact_total) if a1_exact_total else None
            ),
            "interpretation": (
                "Exact match compares the model-authored A1 search request with the compiler "
                "oracle after removing local_call_id. T0 is excluded because it replays gold calls."
            ),
        },
        "failed_episodes": failed_items,
        "rewrite_episode_count": sum(int(row.get("rewrite_count", 0)) > 0 for row in summaries),
        "model_calls": {
            "count": len(calls),
            "per_episode": round(len(calls) / total, 6) if total else None,
            "role_counts": dict(sorted(role_calls.items())),
            "status_counts": dict(sorted(call_status.items())),
            "role_error_counts": {
                role: dict(sorted(counts.items())) for role, counts in sorted(role_errors.items())
            },
        },
        "runtime": {
            "total_generation_wall_time_ms": round(sum(generation_ms), 3),
            "mean_generation_wall_time_per_episode_ms": (
                round(mean(episode_generation.values()), 3) if episode_generation else None
            ),
            "p95_generation_wall_time_per_episode_ms": _percentile95(
                list(episode_generation.values())
            ),
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "mean_output_tokens_per_second": (
                round(mean(throughput), 6) if throughput else None
            ),
            "peak_vram_bytes": peak_vram or None,
        },
    }


def _technical_preference(rows: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    eligible = [
        row
        for row in rows
        if row.get("topology_id") in {"T1", "T2", "T3"}
        and row.get("standard_48_complete") is True
        and row.get("all_contract_checks_passed") is True
    ]
    if not eligible:
        return {
            "status": "not_selected",
            "reason": "No agent topology completed all 48 cases with every automated contract check passing.",
        }
    ordered = sorted(
        eligible,
        key=lambda row: (
            float(row.get("model_calls", {}).get("per_episode") or math.inf),
            float(row.get("runtime", {}).get("mean_generation_wall_time_per_episode_ms") or math.inf),
            str(row.get("topology_id")),
        ),
    )
    chosen = ordered[0]
    return {
        "status": "technical_development_preference_only",
        "topology_id": chosen["topology_id"],
        "reason": (
            "Among contract-clean complete agent runs, this topology used the fewest model calls; "
            "latency and topology ID were tie-breakers."
        ),
        "not_a_medical_model_selection": True,
    }


def _markdown(report: Mapping[str, Any]) -> str:
    lines = [
        "# DS-AGENT automated development diagnostic",
        "",
        "> This is not a medical performance score, clinical validation, or release approval.",
        "",
        "## Comparison",
        "",
        "| Topology | Episodes | Complete 48 | Contract checks | Calls/episode | Mean ms/episode | Peak VRAM |",
        "|---|---:|---|---|---:|---:|---:|",
    ]
    for row in report["topologies"]:
        runtime = row["runtime"]
        calls = row["model_calls"]
        lines.append(
            "| {topology} | {episodes} | {complete} | {checks} | {calls} | {latency} | {vram} |".format(
                topology=row["topology_id"],
                episodes=row["episode_count"],
                complete="yes" if row["standard_48_complete"] else "no",
                checks="pass" if row["all_contract_checks_passed"] else "fail",
                calls=calls["per_episode"] if calls["per_episode"] is not None else "n/a",
                latency=(
                    runtime["mean_generation_wall_time_per_episode_ms"]
                    if runtime["mean_generation_wall_time_per_episode_ms"] is not None
                    else "n/a"
                ),
                vram=runtime["peak_vram_bytes"] or "n/a",
            )
        )
    preference = report["technical_preference"]
    lines.extend(
        [
            "",
            "## Automated interpretation",
            "",
            f"- Technical preference: `{preference.get('topology_id', 'not selected')}` ({preference['status']}).",
            "- T0 replays oracle tool calls, so it is a deterministic fixture/host reference and not tool-selection performance.",
            "- T1 is a staged same-policy proxy; it is not a single uninterrupted generation.",
            "- Failures are attributed from contract checks and trace failure codes, not from human clinical judgment.",
            "",
            "## Mandatory gates",
            "",
            "- `automated_development_diagnostic=true`",
            "- `evaluation_eligible=false`",
            "- `model_performance_result=false`",
            "- `medical_release_gate_result=false`",
            "",
            "Human/clinical review and an approved medical snapshot remain required before medical performance or release claims.",
            "",
        ]
    )
    return "\n".join(lines)


def generate_report(
    workspace_root: Path,
    run_dirs: Sequence[Path],
    output_dir: Path,
    *,
    require_complete: bool = True,
    compiled_bundle_dir: Path | None = None,
) -> Path:
    root = workspace_root.resolve()
    output = _resolve_inside(root, output_dir)
    if output.exists():
        raise AutomatedEvalReportError(f"existing output cannot be overwritten: {output}")
    if not run_dirs:
        raise AutomatedEvalReportError("at least one run directory is required")
    loaded = [_load_run(_resolve_inside(root, path)) for path in run_dirs]
    episode_oracles: dict[str, dict[str, Any]] | None = None
    compiled_bundle: dict[str, Any] | None = None
    if compiled_bundle_dir is not None:
        bundle = _resolve_inside(root, compiled_bundle_dir)
        bundle_manifest = _verify_compiled_bundle(bundle)
        bundle_hash = _sha256_file(bundle / "manifest.json")
        for run in loaded:
            source = run["manifest"].get("source_bundle")
            if not isinstance(source, Mapping) or source.get("manifest_sha256") != bundle_hash:
                raise AutomatedEvalReportError(
                    f"run source bundle differs from the supplied oracle bundle: {run['path']}"
                )
        episode_oracles = {}
        for split_name in SPLITS:
            for episode in _read_jsonl(bundle / split_name / "episodes.jsonl"):
                item_id = str(episode.get("item_id"))
                if not item_id or item_id in episode_oracles:
                    raise AutomatedEvalReportError("compiled bundle episode IDs are invalid")
                episode_oracles[item_id] = episode
        compiled_bundle = {
            "path": bundle.relative_to(root).as_posix(),
            "dataset_id": bundle_manifest.get("dataset_id"),
            "manifest_sha256": bundle_hash,
            "review_status": bundle_manifest.get("review_status"),
            "evaluation_eligible": bundle_manifest.get("evaluation_eligible") is True,
        }
    grouped: defaultdict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for run in loaded:
        grouped[str(run["topology_id"])].append(run)
    topologies = [
        _aggregate_topology(topology_id, runs, episode_oracles)
        for topology_id, runs in sorted(grouped.items())
    ]
    if require_complete:
        incomplete = [row["topology_id"] for row in topologies if not row["standard_48_complete"]]
        if incomplete:
            raise AutomatedEvalReportError(
                f"standard 28/14/6 run set is incomplete for: {', '.join(incomplete)}"
            )
    report: dict[str, Any] = {
        "schema_version": "1.0",
        "reporter": {
            "script": "scripts/report_ds_agent_automated_eval.py",
            "version": SCRIPT_VERSION,
        },
        "result_kind": "automated_development_diagnostic_not_medical_performance",
        "automated_development_diagnostic": True,
        "evaluation_eligible": False,
        "model_performance_result": False,
        "medical_release_gate_result": False,
        "expected_standard_set": {
            "split_counts": EXPECTED_SPLIT_COUNTS,
            "episode_count": EXPECTED_TOTAL,
        },
        "inputs": [
            {
                "path": run["path"].relative_to(root).as_posix(),
                "manifest_sha256": run["manifest_sha256"],
                "run_id": run["manifest"].get("run_id"),
                "topology_id": run["topology_id"],
            }
            for run in loaded
        ],
        "compiled_oracle_bundle": compiled_bundle,
        "topologies": topologies,
        "technical_preference": _technical_preference(topologies),
        "interpretation_limits": [
            "The 48 DS-AGENT cases are compiler-generated and unreviewed.",
            "No approved medical knowledge snapshot is attached to this pilot.",
            "Automated oracle agreement cannot establish medical correctness or usability.",
            "T0 replays gold tool calls and is not an agent tool-selection baseline.",
        ],
        "blocked_claims": [
            "medical accuracy",
            "clinical safety approval",
            "medical release readiness",
            "final medical model selection",
        ],
    }
    report_json = _json_bytes(report)
    report_md = _markdown(report).encode("utf-8")
    files = {
        "automated_evaluation_report.json": report_json,
        "automated_evaluation_report.md": report_md,
    }
    manifest = {
        "schema_version": "1.0",
        "automated_development_diagnostic": True,
        "evaluation_eligible": False,
        "model_performance_result": False,
        "medical_release_gate_result": False,
        "outputs": [
            {
                "file": name,
                "bytes": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
            }
            for name, payload in sorted(files.items())
        ],
    }
    files["manifest.json"] = _json_bytes(manifest)
    _write_atomic_tree(output, files)
    return output


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace-root", type=Path, default=Path.cwd())
    parser.add_argument("--run-dir", type=Path, action="append", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--compiled-bundle-dir", type=Path)
    parser.add_argument("--allow-partial", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        output = generate_report(
            args.workspace_root,
            args.run_dir,
            args.output_dir,
            require_complete=not args.allow_partial,
            compiled_bundle_dir=args.compiled_bundle_dir,
        )
    except (AutomatedEvalReportError, HostContractError, OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}")
        return 1
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = ["AutomatedEvalReportError", "build_parser", "generate_report"]
