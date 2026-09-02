#!/usr/bin/env python3
"""Consolidate verified DS-AGENT and public component smoke diagnostics."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any, Mapping, Sequence

try:
    from scripts.run_ds_agent_pilot import (
        _json_bytes,
        _resolve_inside,
        _sha256_file,
        _write_atomic_tree,
    )
except ModuleNotFoundError:  # pragma: no cover
    from run_ds_agent_pilot import (  # type: ignore
        _json_bytes,
        _resolve_inside,
        _sha256_file,
        _write_atomic_tree,
    )


SCRIPT_VERSION = "0.1.0"


class ConsolidatedReportError(RuntimeError):
    pass


def _json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ConsolidatedReportError(f"cannot read JSON: {path}") from exc
    if not isinstance(value, dict):
        raise ConsolidatedReportError(f"JSON root must be an object: {path}")
    return value


def _jsonl(path: Path) -> list[dict[str, Any]]:
    try:
        values = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ConsolidatedReportError(f"cannot read JSONL: {path}") from exc
    if any(not isinstance(value, dict) for value in values):
        raise ConsolidatedReportError(f"JSONL rows must be objects: {path}")
    return values


def _verify_outputs(directory: Path, manifest: Mapping[str, Any]) -> None:
    outputs = manifest.get("outputs")
    if not isinstance(outputs, list) or not outputs:
        raise ConsolidatedReportError(f"manifest outputs are missing: {directory}")
    for row in outputs:
        if not isinstance(row, Mapping) or not isinstance(row.get("file"), str):
            raise ConsolidatedReportError(f"invalid output declaration: {directory}")
        relative = Path(str(row["file"]))
        if relative.is_absolute() or ".." in relative.parts:
            raise ConsolidatedReportError("unsafe output declaration")
        path = (directory / relative).resolve()
        if not path.is_relative_to(directory) or not path.is_file():
            raise ConsolidatedReportError(f"declared output missing: {path}")
        if path.stat().st_size != row.get("bytes") or _sha256_file(path) != row.get("sha256"):
            raise ConsolidatedReportError(f"declared output changed: {path}")


def _component(root: Path, row: Mapping[str, Any]) -> dict[str, Any]:
    response_dir = _resolve_inside(root, Path(str(row.get("response_dir"))))
    score_dir = _resolve_inside(root, Path(str(row.get("score_dir"))))
    response_manifest = _json(response_dir / "manifest.json")
    score_manifest = _json(score_dir / "manifest.json")
    score_summary = _json(score_dir / "summary.json")
    _verify_outputs(response_dir, response_manifest)
    _verify_outputs(score_dir, score_manifest)
    if (
        response_manifest.get("project_end_to_end_result") is True
        or response_manifest.get("medical_release_gate_result") is True
        or score_summary.get("official_benchmark_result") is True
        or score_summary.get("project_end_to_end_result") is True
        or score_summary.get("medical_release_gate_result") is True
    ):
        raise ConsolidatedReportError("component smoke cannot be promoted to official or release evidence")
    responses = _jsonl(response_dir / "responses.jsonl")
    repairs = sum(
        int(value.get("usage", {}).get("format_repair_count", 0))
        for value in responses
        if isinstance(value.get("usage"), Mapping)
    )
    return {
        "id": row.get("id"),
        "role": row.get("role"),
        "source": row.get("source"),
        "case_count": response_manifest.get("record_count"),
        "response_status_counts": response_manifest.get("status_counts"),
        "format_repair_count": repairs,
        "scored_responses": score_summary.get("scored_responses"),
        "unscored_responses": score_summary.get("unscored_responses"),
        "scoring_coverage": score_summary.get("scoring_coverage"),
        "metric_means": score_summary.get("metric_means"),
        "failure_counts": score_summary.get("failure_counts"),
        "response_manifest_sha256": _sha256_file(response_dir / "manifest.json"),
        "score_manifest_sha256": _sha256_file(score_dir / "manifest.json"),
        "interpretation": "two-case connectivity smoke; not an official benchmark score",
    }


def _best_observed(topologies: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    agents = [value for value in topologies if value.get("topology_id") in {"T1", "T2", "T3"}]
    if not agents:
        raise ConsolidatedReportError("DS report has no agent topology")
    chosen = max(
        agents,
        key=lambda value: (
            float(value.get("contract_checks", {}).get("expected_records_referenced", {}).get("rate") or 0),
            float(value.get("contract_checks", {}).get("expected_final_status_match", {}).get("rate") or 0),
            -float(value.get("model_calls", {}).get("per_episode") or 999),
        ),
    )
    return {
        "topology_id": chosen["topology_id"],
        "status": "best_observed_nonpassing_development_baseline",
        "reason": "Highest record-reference rate, then expected-status rate, then fewer model calls.",
        "selected_for_medical_use": False,
    }


def _markdown(report: Mapping[str, Any]) -> str:
    lines = [
        "# Automated agent evaluation — final development report",
        "",
        "> Development diagnostics only. Not clinical validation, medical performance, or release approval.",
        "",
        "## DS-AGENT topology comparison",
        "",
        "| Topology | Status match | Tool sequence | Records referenced | A1 exact request | Calls/episode | Mean latency |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for value in report["ds_agent"]["topologies"]:
        exact = value["oracle_diagnostics"]["a1_gold_request_exact_match"]
        lines.append(
            "| {id} | {status:.1%} | {tools:.1%} | {records:.1%} | {exact} | {calls:.2f} | {latency} ms |".format(
                id=value["topology_id"],
                status=value["contract_checks"]["expected_final_status_match"]["rate"],
                tools=value["contract_checks"]["allowed_tool_sequence_match"]["rate"],
                records=value["contract_checks"]["expected_records_referenced"]["rate"],
                exact=(f"{exact['rate']:.1%}" if exact else "oracle replay"),
                calls=value["model_calls"]["per_episode"],
                latency=value["runtime"]["mean_generation_wall_time_per_episode_ms"] or "n/a",
            )
        )
    lines.extend(
        [
            "",
            "## Public component connectivity smoke",
            "",
            "| Component | Valid responses | Scored | Metrics / blocker |",
            "|---|---:|---:|---|",
        ]
    )
    for value in report["components"]:
        status = value.get("response_status_counts") or {}
        valid = int(status.get("ok", 0))
        detail = value.get("metric_means") or value.get("failure_counts") or status
        lines.append(
            f"| {value['id']} | {valid}/{value['case_count']} | "
            f"{value['scored_responses']}/{value['case_count']} | `{json.dumps(detail, ensure_ascii=False)}` |"
        )
    lines.extend(
        [
            "",
            "## Conclusion",
            "",
            f"- Best observed non-passing baseline: `{report['technical_conclusion']['topology_id']}`.",
            "- No T1–T3 topology passed all automated contracts; no agent is selected for medical use.",
            "- T3 added latency and generative failure surfaces in A2/A3 without improving record retrieval.",
            "- Automated pre-research cutoff is reached; the next implementation priority is the mobile record skeleton.",
            "- Approved medical snapshot and clinical review remain blockers for medical E2E and release claims.",
            "",
        ]
    )
    return "\n".join(lines)


def generate_report(root: Path, input_manifest_path: Path, output_dir: Path) -> Path:
    workspace = root.resolve()
    input_path = _resolve_inside(workspace, input_manifest_path)
    output = _resolve_inside(workspace, output_dir)
    if output.exists():
        raise ConsolidatedReportError(f"existing output cannot be overwritten: {output}")
    inputs = _json(input_path)
    ds_dir = _resolve_inside(workspace, Path(str(inputs.get("ds_agent_report_dir"))))
    ds_manifest = _json(ds_dir / "manifest.json")
    _verify_outputs(ds_dir, ds_manifest)
    ds_report = _json(ds_dir / "automated_evaluation_report.json")
    if any(
        ds_report.get(field) is True
        for field in ("evaluation_eligible", "model_performance_result", "medical_release_gate_result")
    ):
        raise ConsolidatedReportError("DS automated report was promoted beyond development use")
    raw_components = inputs.get("components")
    if not isinstance(raw_components, list) or not raw_components:
        raise ConsolidatedReportError("component input list is missing")
    components = [_component(workspace, value) for value in raw_components if isinstance(value, Mapping)]
    if len(components) != len(raw_components):
        raise ConsolidatedReportError("component input row is invalid")
    complete_ds = all(value.get("standard_48_complete") is True for value in ds_report["topologies"])
    report: dict[str, Any] = {
        "schema_version": "1.0",
        "reporter": {"script": "scripts/report_automated_agent_evaluation.py", "version": SCRIPT_VERSION},
        "result_kind": "automated_development_diagnostic_not_medical_performance",
        "automated_development_diagnostic": True,
        "evaluation_eligible": False,
        "model_performance_result": False,
        "medical_release_gate_result": False,
        "input_manifest": {
            "path": input_path.relative_to(workspace).as_posix(),
            "sha256": _sha256_file(input_path),
        },
        "ds_agent": ds_report,
        "components": components,
        "technical_conclusion": _best_observed(ds_report["topologies"]),
        "automated_research_cutoff": {
            "reached": complete_ds,
            "next_priority": "mobile_record_skeleton_and_encrypted_persistence",
        },
        "remaining_external_or_human_blockers": [
            "No approved, clinically reviewed medical snapshot exists for grounded A3-A5 E2E.",
            "MIRAGE PubMed chunk-to-PMID mapping is absent, so retrieval scoring is disabled.",
            "LongHealth smoke exceeds the fixed 4096-token input budget and needs deterministic chunking.",
            "HealthBench A4 has no independent judgments; human review is unavailable.",
            "BFCL stateful multi-turn official runtime and MedAgentBench Docker execution remain outside this run.",
        ],
    }
    report_json = _json_bytes(report)
    report_md = _markdown(report).encode("utf-8")
    files = {
        "automated_agent_evaluation.json": report_json,
        "automated_agent_evaluation.md": report_md,
    }
    manifest = {
        "schema_version": "1.0",
        "evaluation_eligible": False,
        "model_performance_result": False,
        "medical_release_gate_result": False,
        "outputs": [
            {"file": name, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
            for name, payload in sorted(files.items())
        ],
    }
    files["manifest.json"] = _json_bytes(manifest)
    _write_atomic_tree(output, files)
    return output


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace-root", type=Path, default=Path.cwd())
    parser.add_argument("--input-manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = generate_report(args.workspace_root, args.input_manifest, args.output_dir)
    except (ConsolidatedReportError, OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}")
        return 1
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

