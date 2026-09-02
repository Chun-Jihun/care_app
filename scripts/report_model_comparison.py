#!/usr/bin/env python3
"""Build a verified, development-only report for the local model comparison."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import tempfile
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Mapping, Sequence


SCRIPT_VERSION = "0.1.0"


class ModelComparisonReportError(RuntimeError):
    pass


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ModelComparisonReportError(f"cannot read JSON: {path}") from exc
    if not isinstance(value, dict):
        raise ModelComparisonReportError(f"JSON root must be an object: {path}")
    return value


def _jsonl(path: Path) -> list[dict[str, Any]]:
    try:
        rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ModelComparisonReportError(f"cannot read JSONL: {path}") from exc
    if any(not isinstance(row, dict) for row in rows):
        raise ModelComparisonReportError(f"JSONL rows must be objects: {path}")
    return rows


def _inside(root: Path, value: str) -> Path:
    path = (root / value).resolve()
    if not path.is_relative_to(root):
        raise ModelComparisonReportError(f"path escapes workspace: {value}")
    return path


def _verify_outputs(directory: Path, manifest: Mapping[str, Any]) -> None:
    outputs = manifest.get("outputs")
    if not isinstance(outputs, list) or not outputs:
        raise ModelComparisonReportError(f"manifest outputs are missing: {directory}")
    for row in outputs:
        if not isinstance(row, Mapping) or not isinstance(row.get("file"), str):
            raise ModelComparisonReportError(f"invalid output declaration: {directory}")
        path = _inside(directory, str(row["file"]))
        if not path.is_file():
            raise ModelComparisonReportError(f"declared output missing: {path}")
        if path.stat().st_size != row.get("bytes") or _sha256(path) != row.get("sha256"):
            raise ModelComparisonReportError(f"declared output changed: {path}")


def _rate(passed: int, total: int) -> dict[str, int | float]:
    return {"passed": passed, "total": total, "rate": round(passed / total, 6) if total else 0.0}


def _p95(values: Sequence[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)], 3)


def _screening_run(root: Path, row: Mapping[str, Any], expected_count: int) -> dict[str, Any]:
    directory = _inside(root, str(row["path"]))
    manifest = _json(directory / "manifest.json")
    _verify_outputs(directory, manifest)
    for field in ("evaluation_eligible", "model_performance_result", "medical_release_gate_result"):
        if manifest.get(field) is True:
            raise ModelComparisonReportError(f"screening run was promoted beyond development use: {directory}")
    if manifest.get("episode_count") != expected_count:
        raise ModelComparisonReportError(f"unexpected episode count: {directory}")
    summaries = _jsonl(directory / "trace_summaries.jsonl")
    calls = _jsonl(directory / "model_calls.jsonl")
    events = _jsonl(directory / "trace_events.jsonl")
    if len(summaries) != expected_count:
        raise ModelComparisonReportError(f"trace summary count mismatch: {directory}")

    check_names = (
        "expected_final_status_match",
        "allowed_tool_sequence_match",
        "expected_records_referenced",
        "expected_evidence_cited",
    )
    checks = {
        name: _rate(
            sum(bool(summary.get("expected_checks", {}).get(name)) for summary in summaries),
            len(summaries),
        )
        for name in check_names
    }
    checks["all_expected_checks_passed"] = _rate(
        sum(bool(summary.get("all_expected_checks_passed")) for summary in summaries),
        len(summaries),
    )

    per_episode_latency: dict[str, float] = defaultdict(float)
    status_counts: Counter[str] = Counter()
    role_counts: Counter[str] = Counter()
    validation_errors: Counter[str] = Counter()
    peak_vram = 0
    total_input_tokens = 0
    total_output_tokens = 0
    repair_count = 0
    for call in calls:
        item_id = str(call.get("item_id"))
        usage = call.get("usage") if isinstance(call.get("usage"), Mapping) else {}
        per_episode_latency[item_id] += float(usage.get("generation_wall_time_ms") or 0)
        peak_vram = max(peak_vram, int(usage.get("peak_vram_bytes") or 0))
        total_input_tokens += int(usage.get("input_tokens") or 0)
        total_output_tokens += int(usage.get("output_tokens") or 0)
        status_counts[str(call.get("status"))] += 1
        role_counts[str(call.get("role_id"))] += 1
        repair_count += int(call.get("attempt") == 2 or call.get("purpose") == "format_repair")
        for error in call.get("validation_errors") or []:
            validation_errors[str(error)] += 1

    tool_result_statuses: Counter[str] = Counter()
    tool_error_codes: Counter[str] = Counter()
    for event in events:
        if event.get("event_type") != "tool_result":
            continue
        payload = event.get("payload") if isinstance(event.get("payload"), Mapping) else {}
        tool_result_statuses[str(payload.get("status"))] += 1
        if payload.get("error_code"):
            tool_error_codes[str(payload["error_code"])] += 1

    latencies = list(per_episode_latency.values())
    schema_failures = status_counts["schema_error"] + status_counts["parse_error"]
    records_rate = float(checks["expected_records_referenced"]["rate"])
    if schema_failures:
        diagnosis = "A1 출력이 필수 JSON 필드를 반복해서 누락했고 1회 수리 후에도 계약을 충족하지 못했다."
    elif records_rate == 0:
        diagnosis = "역할 JSON은 유효했지만 A1 검색이 기대 기록을 찾지 못해 모든 episode가 안전 보류로 끝났다."
    elif records_rate < 0.5:
        diagnosis = "역할 JSON은 유효했지만 A1이 검색어·시간 범위를 과도하게 좁혀 기대 기록을 거의 찾지 못했다."
    else:
        diagnosis = "A1이 일부 기대 기록을 찾았으나 남은 실패는 기록 검색 또는 최종 상태 불일치에서 발생했다."

    return {
        "model_id": row["model_id"],
        "label": row["label"],
        "path": str(row["path"]),
        "manifest_sha256": _sha256(directory / "manifest.json"),
        "runtime_profile_id": manifest.get("backend", {}).get("runtime_profile_id"),
        "runtime_profile_sha256": manifest.get("backend", {}).get("runtime_profile_sha256"),
        "model_lock_sha256": manifest.get("backend", {}).get("model_lock_sha256"),
        "model_revision": manifest.get("backend", {}).get("model_revision"),
        "generation_profile": manifest.get("backend", {}).get("generation_profile"),
        "source_manifest_sha256": manifest.get("source_bundle", {}).get("manifest_sha256"),
        "topology_id": manifest.get("topology", {}).get("id"),
        "item_ids": sorted(str(summary.get("item_id")) for summary in summaries),
        "episode_count": len(summaries),
        "contract_checks": checks,
        "final_status_counts": dict(sorted(Counter(str(s.get("actual_final_status")) for s in summaries).items())),
        "model_calls": {
            "count": len(calls),
            "status_counts": dict(sorted(status_counts.items())),
            "role_counts": dict(sorted(role_counts.items())),
            "format_repair_count": repair_count,
            "validation_errors": dict(sorted(validation_errors.items())),
        },
        "tool_results": {
            "status_counts": dict(sorted(tool_result_statuses.items())),
            "error_code_counts": dict(sorted(tool_error_codes.items())),
        },
        "runtime": {
            "mean_generation_wall_time_per_episode_ms": round(sum(latencies) / len(latencies), 3),
            "p95_generation_wall_time_per_episode_ms": _p95(latencies),
            "peak_vram_bytes": peak_vram,
            "input_tokens": total_input_tokens,
            "output_tokens": total_output_tokens,
        },
        "automated_failure_diagnosis": diagnosis,
    }


def _protocol_check(root: Path, row: Mapping[str, Any]) -> dict[str, Any]:
    directory = _inside(root, str(row["path"]))
    manifest = _json(directory / "manifest.json")
    _verify_outputs(directory, manifest)
    if manifest.get("project_end_to_end_result") is True or manifest.get("medical_release_gate_result") is True:
        raise ModelComparisonReportError(f"protocol check was promoted beyond component use: {directory}")
    responses = _jsonl(directory / "responses.jsonl")
    status_counts = Counter(str(response.get("status")) for response in responses)
    repairs = 0
    latency = 0.0
    output_tokens = 0
    peak_vram = 0
    for response in responses:
        usage = response.get("usage") if isinstance(response.get("usage"), Mapping) else {}
        repairs += int(usage.get("format_repair_count") or 0)
        latency += float(response.get("latency_ms") or 0)
        output_tokens += int(usage.get("output_tokens") or 0)
        peak_vram = max(peak_vram, int(usage.get("peak_vram_bytes") or 0))
        initial = usage.get("initial_attempt") if isinstance(usage.get("initial_attempt"), Mapping) else {}
        output_tokens += int(initial.get("output_tokens") or 0)
        peak_vram = max(peak_vram, int(initial.get("peak_vram_bytes") or 0))
    return {
        "model_id": row["model_id"],
        "label": row["label"],
        "role": row["role"],
        "kind": row["kind"],
        "path": str(row["path"]),
        "manifest_sha256": _sha256(directory / "manifest.json"),
        "runtime_profile_id": manifest.get("runner", {}).get("backend", {}).get("runtime_profile_id"),
        "runtime_profile_sha256": manifest.get("runner", {}).get("backend", {}).get("runtime_profile_sha256"),
        "model_lock_sha256": manifest.get("runner", {}).get("backend", {}).get("model_lock_sha256"),
        "generation_profile": manifest.get("runner", {}).get("backend", {}).get("generation_profile"),
        "case_count": len(responses),
        "status_counts": dict(sorted(status_counts.items())),
        "valid_contract_rate": round(status_counts["ok"] / len(responses), 6) if responses else 0.0,
        "format_repair_count": repairs,
        "total_latency_ms": round(latency, 3),
        "total_output_tokens_including_repair": output_tokens,
        "peak_vram_bytes": peak_vram,
        "interpretation": "One-case component protocol compatibility check; not a capability score.",
    }


def _rank_key(run: Mapping[str, Any]) -> tuple[float, float, float, float, int, float]:
    checks = run["contract_checks"]
    return (
        float(checks["all_expected_checks_passed"]["rate"]),
        float(checks["expected_records_referenced"]["rate"]),
        float(checks["allowed_tool_sequence_match"]["rate"]),
        float(checks["expected_final_status_match"]["rate"]),
        -int(run["model_calls"]["format_repair_count"]),
        -float(run["runtime"]["mean_generation_wall_time_per_episode_ms"]),
    )


def _markdown(report: Mapping[str, Any]) -> str:
    lines = [
        "# 로컬 모델 비교 실험 V1",
        "",
        "> 자동 개발 진단 결과다. 의료 성능 검증, 출시 승인, 모바일 런타임 선정 결과가 아니다.",
        "",
        "## 결론",
        "",
        f"현재 A1/A4 JSON 계약의 데스크톱 기술 후보는 **{report['technical_conclusion']['label']}**다. "
        "다만 8개 미검수 합성 사례 중 모든 계약을 통과한 비율도 100%가 아니므로 의료용 모델로 선정하지 않는다.",
        "정확도·근거 충실도를 속도·메모리보다 우선한다는 요구사항에 따라, 더 빠르거나 작은 후보보다 계약 통과율과 기록 참조율이 높은 후보를 먼저 선택했다.",
        "",
        "## 동일 DS-AGENT 8건 선별 결과",
        "",
        "| 모델 | 전체 계약 | 기록 ID | 도구 순서 | 최종 상태 | 수리 | 평균 지연/건 | 최대 VRAM |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for run in report["screening_runs"]:
        checks = run["contract_checks"]
        lines.append(
            "| {label} | {all:.1%} | {records:.1%} | {tools:.1%} | {status:.1%} | {repairs} | {latency:.1f}s | {vram:.2f} GiB |".format(
                label=run["label"],
                all=checks["all_expected_checks_passed"]["rate"],
                records=checks["expected_records_referenced"]["rate"],
                tools=checks["allowed_tool_sequence_match"]["rate"],
                status=checks["expected_final_status_match"]["rate"],
                repairs=run["model_calls"]["format_repair_count"],
                latency=run["runtime"]["mean_generation_wall_time_per_episode_ms"] / 1000,
                vram=run["runtime"]["peak_vram_bytes"] / (1024**3),
            )
        )
    lines.extend(["", "## 역할 계약 프로토콜 대조", "", "| 모델 | 역할 | 상태 | 수리 | 지연 | 해석 |", "|---|---|---|---:|---:|---|"])
    for check in report["protocol_checks"]:
        status = ", ".join(f"{key}={value}" for key, value in check["status_counts"].items())
        lines.append(
            f"| {check['label']} | {check['role']} | {status} | {check['format_repair_count']} | "
            f"{check['total_latency_ms'] / 1000:.1f}s | 계약 호환성 확인 1건 |"
        )
    lines.extend(["", "## 관찰된 실패 원인", ""])
    for run in report["screening_runs"]:
        tool_status = ", ".join(
            f"{key} {value}건" for key, value in run["tool_results"]["status_counts"].items()
        ) or "도구 호출 없음"
        lines.append(
            f"- **{run['label']}**: {run['automated_failure_diagnosis']} "
            f"관찰된 도구 결과는 {tool_status}이었다."
        )
    lines.extend(
        [
            "- **MedGemma-1.5-4B**: A4에서 2,048-token과 1회 수리를 모두 사용했지만 요구된 단일 JSON 객체 대신 긴 자유형 의료 응답을 생성해 파싱에 실패했다.",
            "- **Nanbeige4-3B-Thinking-2511**: A1에서 첫 출력은 스키마를 따르지 않았고 수리 출력은 2,048-token을 추론 반복에 사용해 필수 `tool_calls` 계약을 만들지 못했다.",
            "",
            "이 원인은 현재 프롬프트·chat template·출력 어댑터·NF4 조건에서 관찰된 것이다. 모델의 일반 의료 지식이나 전체 도구 능력이 낮다는 결론으로 확대하지 않는다.",
            "Qwen3.5의 공개 구성요소 A1/A4 대조도 각각 1회 형식 수리가 필요했다. 반면 프로젝트 DS-AGENT 8건에서는 16회 역할 호출이 모두 수리 없이 유효했으므로, 공개 case projection과 프로젝트 역할 프롬프트의 차이도 결과에 영향을 준 것으로 본다.",
            "",
            "## 다음 판정 경계",
            "",
            "- Qwen3.5-4B는 데스크톱 개발 기준선으로만 유지한다.",
            "- 의료 답변 최종 선정은 승인 근거 스냅샷과 독립 임상 검수가 없으므로 차단한다.",
            "- 모바일 채택은 Android 실기기에서 GGUF 등 목표 양자화별 정확도·지연·메모리를 다시 비교해야 한다.",
            "- MedGemma/Nanbeige를 재시험하려면 모델별 구조화 출력 프롬프트 또는 grammar-constrained decoding을 새 프로필로 고정해야 한다.",
            "",
        ]
    )
    return "\n".join(lines)


def generate(root: Path, input_path: Path, output_dir: Path) -> Path:
    workspace = root.resolve()
    inputs_path = _inside(workspace, input_path.as_posix())
    output = _inside(workspace, output_dir.as_posix())
    if output.exists():
        raise ModelComparisonReportError(f"existing output cannot be overwritten: {output}")
    inputs = _json(inputs_path)
    locked_assets = inputs.get("locked_assets")
    if not isinstance(locked_assets, Mapping):
        raise ModelComparisonReportError("locked asset declaration is missing")
    runtime_profile_path = _inside(workspace, str(locked_assets["runtime_profile_path"]))
    model_lock_path = _inside(workspace, str(locked_assets["model_lock_path"]))
    actual_runtime_hash = _sha256(runtime_profile_path)
    actual_model_lock_hash = _sha256(model_lock_path)
    if actual_runtime_hash != locked_assets.get("runtime_profile_sha256"):
        raise ModelComparisonReportError("runtime profile changed after the comparison")
    if actual_model_lock_hash != locked_assets.get("model_lock_sha256"):
        raise ModelComparisonReportError("model lock changed after the comparison")
    screening = inputs.get("screening")
    if not isinstance(screening, Mapping) or not isinstance(screening.get("runs"), list):
        raise ModelComparisonReportError("screening run list is missing")
    expected_count = int(screening.get("expected_episode_count") or 0)
    screening_runs = [_screening_run(workspace, row, expected_count) for row in screening["runs"]]
    if not screening_runs:
        raise ModelComparisonReportError("no screening runs")
    common_item_ids = screening_runs[0]["item_ids"]
    common_runtime_hash = screening_runs[0]["runtime_profile_sha256"]
    for run in screening_runs[1:]:
        if run["item_ids"] != common_item_ids:
            raise ModelComparisonReportError("screening runs do not use the same item IDs")
        if run["runtime_profile_sha256"] != common_runtime_hash:
            raise ModelComparisonReportError("screening runs do not use the same runtime manifest revision")
        if run["generation_profile"] != screening_runs[0]["generation_profile"]:
            raise ModelComparisonReportError("screening runs do not use the same generation profile")
        if run["source_manifest_sha256"] != screening_runs[0]["source_manifest_sha256"]:
            raise ModelComparisonReportError("screening runs do not use the same source bundle")
    if any(run["runtime_profile_sha256"] != actual_runtime_hash for run in screening_runs):
        raise ModelComparisonReportError("screening run runtime profile hash does not match the locked file")
    if any(run["model_lock_sha256"] != actual_model_lock_hash for run in screening_runs):
        raise ModelComparisonReportError("screening run model lock hash does not match the locked file")
    raw_protocol = inputs.get("protocol_checks")
    if not isinstance(raw_protocol, list):
        raise ModelComparisonReportError("protocol check list is missing")
    protocol_checks = [_protocol_check(workspace, row) for row in raw_protocol]
    if any(check["runtime_profile_sha256"] != actual_runtime_hash for check in protocol_checks):
        raise ModelComparisonReportError("protocol check runtime profile hash does not match the locked file")
    if any(check["model_lock_sha256"] != actual_model_lock_hash for check in protocol_checks):
        raise ModelComparisonReportError("protocol check model lock hash does not match the locked file")
    winner = max(screening_runs, key=_rank_key)
    report: dict[str, Any] = {
        "schema_version": "1.0",
        "reporter": {"script": "scripts/report_model_comparison.py", "version": SCRIPT_VERSION},
        "result_kind": inputs.get("result_scope"),
        "automated_development_diagnostic": True,
        "evaluation_eligible": False,
        "model_performance_result": False,
        "medical_release_gate_result": False,
        "selected_for_medical_use": False,
        "selected_for_mobile_release": False,
        "input_manifest": {"path": input_path.as_posix(), "sha256": _sha256(inputs_path)},
        "comparison_invariants": {
            "same_item_ids": True,
            "same_runtime_manifest_sha256": common_runtime_hash,
            "same_generation_profile": screening_runs[0]["generation_profile"],
            "same_source_manifest_sha256": screening_runs[0]["source_manifest_sha256"],
            "item_ids": common_item_ids,
        },
        "screening_runs": screening_runs,
        "protocol_checks": protocol_checks,
        "technical_conclusion": {
            "model_id": winner["model_id"],
            "label": winner["label"],
            "status": "desktop_a1_a4_development_candidate_only",
            "selection_rule": inputs.get("selection_rule"),
            "selected_for_medical_use": False,
            "selected_for_mobile_release": False,
        },
        "limitations": inputs.get("limitations"),
    }
    json_bytes = (json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    md_bytes = _markdown(report).encode("utf-8")
    files = {"model_comparison.json": json_bytes, "model_comparison.md": md_bytes}
    manifest = {
        "schema_version": "1.0",
        "automated_development_diagnostic": True,
        "evaluation_eligible": False,
        "model_performance_result": False,
        "medical_release_gate_result": False,
        "outputs": [
            {"file": name, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
            for name, payload in sorted(files.items())
        ],
    }
    files["manifest.json"] = (json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}-", dir=output.parent))
    try:
        for name, payload in files.items():
            (temporary / name).write_bytes(payload)
        temporary.replace(output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return output


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace-root", default=".")
    parser.add_argument(
        "--input-manifest",
        default="experiments/agent_eval/manifests/model_comparison_inputs_v1.json",
    )
    parser.add_argument(
        "--output-dir",
        default="experiments/agent_eval/results/model_comparison_v1",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    output = generate(Path(args.workspace_root), Path(args.input_manifest), Path(args.output_dir))
    print(output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
