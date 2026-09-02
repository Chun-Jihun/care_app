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


SCRIPT_VERSION = "0.3.0"


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
    screening_by_model = {run["model_id"]: run for run in report["screening_runs"]}
    protocol_by_model: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for check in report["protocol_checks"]:
        protocol_by_model[str(check["model_id"])].append(check)

    def performance_summary(model_id: str) -> str:
        parts: list[str] = []
        run = screening_by_model.get(model_id)
        if run is not None:
            checks = run["contract_checks"]
            parts.append(
                "T1 8건: 전체 {all:.1%}, 기록 {records:.1%}, 도구 {tools:.1%}, "
                "상태 {status:.1%}, 평균 {latency:.1f}s, p95 {p95:.1f}s, VRAM {vram:.2f}GiB".format(
                    all=checks["all_expected_checks_passed"]["rate"],
                    records=checks["expected_records_referenced"]["rate"],
                    tools=checks["allowed_tool_sequence_match"]["rate"],
                    status=checks["expected_final_status_match"]["rate"],
                    latency=run["runtime"]["mean_generation_wall_time_per_episode_ms"] / 1000,
                    p95=run["runtime"]["p95_generation_wall_time_per_episode_ms"] / 1000,
                    vram=run["runtime"]["peak_vram_bytes"] / (1024**3),
                )
            )
        for check in protocol_by_model.get(model_id, []):
            parts.append(
                f"{check['role']} probe: 유효 {check['valid_contract_rate']:.0%}, "
                f"수리 {check['format_repair_count']}회, {check['total_latency_ms'] / 1000:.1f}s"
            )
        return "<br>".join(parts) if parts else "실행 없음"

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
        "## 지표를 보기 전에 알아야 할 용어",
        "",
        "이 보고서의 `성능`은 환자에게 의료 조언을 얼마나 잘하는지가 아니라, 합성 간병기록을 대상으로 정해진 에이전트 계약을 얼마나 정확히 수행했는지를 뜻한다.",
        "",
    ]
    for section in report["glossary_sections"]:
        lines.extend(
            [
                f"### {section['title']}",
                "",
                "| 용어 | 뜻 | 이 실험에서의 예 |",
                "|---|---|---|",
            ]
        )
        for entry in section["entries"]:
            lines.append(f"| {entry['term']} | {entry['definition']} | {entry['example']} |")
        lines.append("")
    lines.extend(
        [
        "## 성능지표를 읽는 방법",
        "",
        "| 지표 | 계산·판정 방식 | 실제 계산 예 | 좋은 방향 | 해석 한계 |",
        "|---|---|---|---|---|",
        ]
    )
    for metric in report["metric_definitions"]:
        lines.append(
            f"| {metric['name']} | {metric['definition']} | {metric['example']} | "
            f"{metric['direction']} | {metric['not_measured']} |"
        )
    lines.extend(
        [
        "",
        "`근거 ID`는 이번 8건에서 정답 집합이 비어 있어 세 모델 모두 자동으로 통과했다. 따라서 100%라는 값은 근거 충실도 성능이 아니며 모델 선정 표에서 제외했다.",
        "",
        "## 동일 DS-AGENT 8건 선별 결과",
        "",
        "| 모델 | 전체 계약 | 기록 ID | 도구 순서 | 최종 상태 | 수리 | 평균 지연/건 | 최대 VRAM |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
        ]
    )
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
    lines.extend(
        [
            "",
            "`protocol probe 유효`는 JSON 파싱과 역할 스키마 통과만 뜻한다. 답변의 의학적 정확성이나 공식 BFCL·HealthBench 점수가 아니다.",
            "",
            "## 모델별 성능과 대표 출력 예시",
            "",
            "| 모델 | 측정된 성능 | 실제 출력 예시(축약) | 해석 |",
            "|---|---|---|---|",
        ]
    )
    labels = {run["model_id"]: run["label"] for run in report["screening_runs"]}
    labels.update({check["model_id"]: check["label"] for check in report["protocol_checks"]})
    for example in report["output_examples"]:
        rendered_example = str(example["example"]).replace("|", "\\|")
        lines.append(
            f"| {labels.get(example['model_id'], example['model_id'])}<br>`{example['scope']}` | "
            f"{performance_summary(str(example['model_id']))} | `{rendered_example}` | "
            f"{example['interpretation']} |"
        )
    lines.extend(
        [
            "",
            "예시는 결과 원문의 필요한 필드만 선택하거나 의료 내용을 제거한 구조적 축약이다. M5는 개인정보 최소화 정책에 따라 원문을 저장하지 않았으므로 검증 오류에서 재구성한 형태이며 원문 인용이 아니다.",
        ]
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
    output_examples = inputs.get("output_examples")
    if not isinstance(output_examples, list) or {
        str(value.get("model_id")) for value in output_examples if isinstance(value, Mapping)
    } != {"M1", "M2", "M3", "M4", "M5"}:
        raise ModelComparisonReportError("one output example is required for each model")
    metric_definitions = [
        {
            "id": "all_expected_checks_passed_rate",
            "name": "전체 계약 통과율",
            "definition": "최종 상태·허용 도구 순서·기대 기록 ID·기대 근거 ID의 네 검사가 모두 참인 episode 수 ÷ 8",
            "meaning": "현재 DS-AGENT 계약을 끝까지 일관되게 수행한 비율",
            "example": "Qwen3.5는 8건 중 5건 통과: 5 ÷ 8 = 62.5%",
            "direction": "높을수록 좋음. 단, 의료 hard gate 통과를 대신하지 않음",
            "not_measured": "의학적 정확도·사용자 유용성·공식 benchmark 점수",
        },
        {
            "id": "expected_records_referenced_rate",
            "name": "기록 참조율",
            "definition": "정답의 모든 care_entry_id가 최종 referenced_records에 포함된 episode 수 ÷ 8",
            "meaning": "질문과 관련된 로컬 기록을 찾아 최종 출력까지 보존했는지",
            "example": "Qwen3.5는 기대 기록을 5건에서 보존: 5 ÷ 8 = 62.5%",
            "direction": "높을수록 좋음",
            "not_measured": "요약 문장의 의미·시각·수치가 모두 정확한지",
        },
        {
            "id": "allowed_tool_sequence_match_rate",
            "name": "도구 순서 일치율",
            "definition": "실제 도구 이름 순서가 허용된 호출 순서 중 하나와 정확히 같은 episode 수 ÷ 8",
            "meaning": "필요한 검색→상세조회 흐름을 지켰는지",
            "example": "Qwen3는 1건만 허용 순서와 일치: 1 ÷ 8 = 12.5%",
            "direction": "높을수록 좋음",
            "not_measured": "검색 인자의 모든 값이나 검색어 품질",
        },
        {
            "id": "expected_final_status_match_rate",
            "name": "최종 상태 일치율",
            "definition": "record_answer·partial…abstain·abstain 상태가 기대 상태와 같은 episode 수 ÷ 8",
            "meaning": "답변·부분답변·보류의 라우팅이 맞았는지",
            "example": "Qwen3.5는 5건 일치: 5 ÷ 8 = 62.5%",
            "direction": "높을수록 좋음",
            "not_measured": "사용자에게 표시된 문장 자체의 품질",
        },
        {
            "id": "expected_evidence_cited_rate",
            "name": "근거 ID 충족률",
            "definition": "기대 evidence_span_id 집합이 실제 citation 집합에 포함된 episode 수 ÷ 8",
            "meaning": "승인 근거가 있는 case에서 요구 근거를 빠뜨리지 않았는지",
            "example": "이번 8건은 기대 집합이 ∅라서 ∅ ⊆ 실제 집합이 항상 참: 8 ÷ 8 = 100%",
            "direction": "이번 실행에서는 비교 방향 없음",
            "not_measured": "이번 8건은 기대 근거가 비어 있어 근거 성능 비교에 사용할 수 없음",
        },
        {
            "id": "format_repair_count",
            "name": "형식 수리 횟수",
            "definition": "첫 JSON 파싱·스키마 검사가 실패해 허용된 1회 재생성을 사용한 호출 수",
            "meaning": "현재 역할 JSON 계약을 한 번에 따르는 안정성",
            "example": "EXAONE은 8개 episode마다 A1을 한 번씩 수리: 총 8회",
            "direction": "낮을수록 좋고 0회가 가장 안정적",
            "not_measured": "수리된 내용의 의학적 정확성",
        },
        {
            "id": "latency",
            "name": "평균·p95 지연",
            "definition": "episode의 A1+A4 생성시간 합계 평균과 8건 중 nearest-rank 95백분위",
            "meaning": "이 PC에서 느끼는 순차 생성 비용과 느린 꼬리 사례",
            "example": "Qwen3.5 평균 39.8초, p95 42.0초. N=8에서는 nearest-rank p95가 사실상 가장 느린 1건",
            "direction": "품질·안전조건을 만족한 후보 사이에서 낮을수록 좋음",
            "not_measured": "모델 로드시간·모바일 지연·동시 처리량",
        },
        {
            "id": "peak_vram",
            "name": "최대 VRAM",
            "definition": "NF4 실행 중 torch가 관찰한 모델 호출 최대 GPU 메모리",
            "meaning": "RTX 3060 Ti 8GB에서의 상대적 실행 메모리",
            "example": "EXAONE 최대 1.54GiB, Qwen3.5 최대 3.53GiB",
            "direction": "품질·안전조건을 만족한 후보 사이에서 낮을수록 좋음",
            "not_measured": "Android RAM·앱 전체 메모리·모델 저장용량",
        },
        {
            "id": "protocol_valid_contract_rate",
            "name": "protocol JSON 유효율",
            "definition": "역할별 1건에서 출력이 JSON으로 파싱되고 해당 response schema를 통과한 비율",
            "meaning": "긴 출력 예산에서도 현재 A1/A4 인터페이스에 연결 가능한지",
            "example": "MedGemma A4는 1건 실패: 0 ÷ 1 = 0%. Qwen3.5 A4는 수리 후 1 ÷ 1 = 100%",
            "direction": "높을수록 좋지만 N=1이므로 통과·실패 신호로만 사용",
            "not_measured": "답변 정답률·공식 BFCL/HealthBench 점수·의료 안전성",
        },
    ]
    glossary_sections = [
        {
            "title": "1. 실험 단위와 데이터",
            "entries": [
                {
                    "term": "후보 모델",
                    "definition": "같은 역할과 조건에서 비교하는 로컬 언어모델이다. 모델마다 크기·학습 목적·chat template가 다르다.",
                    "example": "Qwen3.5-4B, Qwen3-4B, MedGemma, Nanbeige, EXAONE",
                },
                {
                    "term": "로컬 추론",
                    "definition": "질문과 기록을 외부 모델 API로 보내지 않고 이 PC의 GPU에서 모델 출력을 생성하는 실행 방식이다.",
                    "example": "모든 비교 실행은 network_access=false로 수행",
                },
                {
                    "term": "case / episode",
                    "definition": "질문 하나, 가상 환자 범위, 조회 가능한 기록, 허용 도구, 기대 결과를 묶은 평가 1건이다. 이 보고서에서는 두 단어를 같은 평가 단위로 사용한다.",
                    "example": "‘어제 저녁에 복용한 약 기록을 찾아 설명하라’가 episode 1건",
                },
                {
                    "term": "DS-AGENT",
                    "definition": "간병 앱의 기록 검색→상세조회→답변 또는 보류 흐름을 시험하기 위해 프로젝트가 자동 생성한 평가 episode 묶음이다.",
                    "example": "이번 비교는 development episode 중 정렬된 첫 8건 사용",
                },
                {
                    "term": "development split",
                    "definition": "개발 중 오류를 찾고 프롬프트·코드를 개선하는 데 사용하는 분할이다. 최종 성능을 주장하는 동결 시험 세트가 아니다.",
                    "example": "동일 8건 결과는 후보 선별용 개발 진단",
                },
                {
                    "term": "compiler_generated_unreviewed",
                    "definition": "프로그램이 원천 데이터를 조합해 만들었고 사람이 문항과 정답을 검수하지 않았다는 상태다.",
                    "example": "이번 DS-AGENT 8건 모두 evaluation_eligible=false",
                },
                {
                    "term": "gold / oracle / 기대값",
                    "definition": "채점기가 정답으로 비교하는 기대 도구 순서·기록 ID·최종 상태다. 현재는 scenario compiler가 만든 자동 기대값이다.",
                    "example": "기대 기록 ID CE-SYN-…가 최종 출력에 남았는지 검사",
                },
                {
                    "term": "N",
                    "definition": "해당 비율이나 통계를 계산한 평가 건수다. N이 작으면 한 건이 전체 비율에 크게 영향을 준다.",
                    "example": "T1은 N=8이라 1건이 12.5%p, protocol probe는 N=1",
                },
            ],
        },
        {
            "title": "2. 에이전트·역할·도구",
            "entries": [
                {
                    "term": "에이전트",
                    "definition": "모델이 정해진 역할 정책과 도구 명세를 받아 다음 행동이나 구조화된 답변을 만드는 실행 구성요소다. 모델 자체와 동일한 뜻은 아니다.",
                    "example": "같은 Qwen 모델도 A1 정책으로 실행하면 코디네이터 역할을 수행",
                },
                {
                    "term": "A1 코디네이터",
                    "definition": "질문의 의도를 파악하고 어떤 읽기 도구가 필요한지 JSON으로 계획한다. DB를 직접 읽거나 의료 결론을 만들지는 않는다.",
                    "example": "search_care_entries의 시간 범위와 query_terms 생성",
                },
                {
                    "term": "A2 기록 맥락 분석",
                    "definition": "도구가 반환한 기록에서 관련 사건·시간·상태를 원본 기록 ID와 함께 정리한다.",
                    "example": "‘19:00, 복용함’과 care_entry_id를 함께 보존",
                },
                {
                    "term": "A3 승인 근거 조사",
                    "definition": "승인된 지식 스냅샷에서 답변을 뒷받침할 근거 구간을 찾는다. 인터넷을 임의 검색해 근거로 추가하지 않는다.",
                    "example": "승인 근거가 없으면 no_evidence 반환",
                },
                {
                    "term": "A4 답변 작성",
                    "definition": "확인된 기록과 승인 근거 안에서만 쉬운 설명·관찰 항목·한계를 구조화해 작성한다.",
                    "example": "기록 사실은 말하되 약의 효능 근거가 없으면 그 부분은 보류",
                },
                {
                    "term": "A5 검증기",
                    "definition": "A4의 주장과 실제 근거·정책을 대조해 통과, 보류 전환 또는 제한된 재작성을 결정한다. 새 의료사실을 추가하지 않는다.",
                    "example": "EVIDENCE_NOT_FOUND이면 승인된 보류 템플릿으로 전환",
                },
                {
                    "term": "도구 / tool call",
                    "definition": "모델이 직접 DB에 접근하는 대신 이름과 인자를 JSON으로 요청하는 허용된 읽기 기능이다.",
                    "example": "search_care_entries, get_care_entry_details",
                },
                {
                    "term": "결정적 도구 호스트",
                    "definition": "동일한 요청에는 동일한 결과를 반환하며 환자 범위·인자·호출 예산을 코드로 강제하는 실행기다.",
                    "example": "다른 환자 ID나 허용되지 않은 인자는 LLM 판단과 무관하게 거부",
                },
                {
                    "term": "T1 토폴로지",
                    "definition": "A1과 A4만 같은 후보 모델로 생성하고 A2·A3·A5는 결정적 코드로 처리한 단일 정책 proxy 구성이다.",
                    "example": "모델당 episode 기본 2회 호출: 도구 전 A1, 도구 후 A4",
                },
            ],
        },
        {
            "title": "3. 출력·근거·안전",
            "entries": [
                {
                    "term": "JSON 계약 / response schema",
                    "definition": "각 역할이 반드시 포함할 필드·자료형·허용값을 정한 기계 검증 규칙이다. 문장이 그럴듯해도 계약을 어기면 실행할 수 없다.",
                    "example": "A1 tool_request에는 tool_name, arguments, reason_code가 필요",
                },
                {
                    "term": "care_entry_id / 기록 ID",
                    "definition": "간병일기의 특정 원본 기록을 가리키는 식별자다. 답변 문장을 원본 기록으로 역추적하는 데 사용한다.",
                    "example": "CE-SYN-10C…는 특정 복약 기록 1건을 지칭",
                },
                {
                    "term": "evidence_span_id / 근거 ID",
                    "definition": "승인 문서 안에서 주장을 직접 뒷받침하는 특정 문장·구간의 식별자다. 문서 제목만 표시하는 것보다 좁은 단위다.",
                    "example": "의학적 핵심 주장마다 evidence_span_id 연결 필요",
                },
                {
                    "term": "citation / 인용",
                    "definition": "답변의 주장과 evidence_span_id를 연결한 출처 레코드다. 기록 ID와 달리 의료 문서 근거를 가리킨다.",
                    "example": "약의 일반 효능 주장→승인 문서의 근거 문장",
                },
                {
                    "term": "최종 상태",
                    "definition": "파이프라인이 사용자에게 어느 수준까지 답할 수 있는지를 나타내는 결과 분류다.",
                    "example": "record_answer, partial_record_answer_then_abstain, abstain",
                },
                {
                    "term": "record_answer",
                    "definition": "필요한 기록을 찾아 기록 사실에 관한 답변을 제공한 상태다. 그 자체로 의료 설명까지 승인됐다는 뜻은 아니다.",
                    "example": "‘어제 19:00에 복용 기록이 있다’",
                },
                {
                    "term": "partial_record_answer_then_abstain",
                    "definition": "확인된 기록 사실은 알려주지만 승인 근거가 필요한 의료 설명 부분은 보류한 상태다.",
                    "example": "복용 여부는 확인, 약 효능 설명은 근거 부족으로 보류",
                },
                {
                    "term": "abstain / 답변 보류",
                    "definition": "필요한 기록·근거가 없거나 계약을 충족하지 못해 추측하지 않고 답변하지 않는 안전 행동이다. 무조건 많이 보류한다고 좋은 것은 아니다.",
                    "example": "관련 기록을 못 찾으면 ‘확인할 정보가 부족하다’고 종료",
                },
                {
                    "term": "형식 수리 / format repair",
                    "definition": "첫 모델 출력이 JSON 파싱이나 schema 검증에 실패했을 때 오류 목록을 주고 딱 한 번 다시 생성하는 절차다.",
                    "example": "EXAONE은 누락 필드를 고치도록 요청했지만 같은 오류 반복",
                },
                {
                    "term": "fail-closed",
                    "definition": "출력이 불완전하거나 검증에 실패하면 임의로 실행·답변하지 않고 차단 또는 보류하는 원칙이다.",
                    "example": "유효하지 않은 A1 도구 요청은 DB 도구에 전달하지 않음",
                },
                {
                    "term": "protocol probe",
                    "definition": "현재 역할 인터페이스와 연결 가능한지만 빠르게 보는 1건 시험이다. 2,048 출력 token과 1회 수리를 허용했다.",
                    "example": "MedGemma A4 1건, Nanbeige A1 1건",
                },
                {
                    "term": "component projection",
                    "definition": "공개 benchmark case를 프로젝트의 A1 또는 A4 JSON 요청 형식으로 변환한 것이다. 공식 benchmark 전체 프로토콜과 점수가 아니다.",
                    "example": "BFCL case→A1, HealthBench case→A4",
                },
            ],
        },
        {
            "title": "4. 실행 성능과 통계",
            "entries": [
                {
                    "term": "통과율",
                    "definition": "조건을 통과한 건수 ÷ 평가한 전체 건수다. 표본 수 N을 함께 보지 않으면 오해하기 쉽다.",
                    "example": "5/8=62.5%, 1/1=100%는 신뢰도가 같지 않음",
                },
                {
                    "term": "평균 지연시간",
                    "definition": "각 episode에서 모델 생성에 걸린 시간을 합산한 뒤 episode 수로 나눈 값이다.",
                    "example": "T1은 보통 A1 생성시간+A4 생성시간",
                },
                {
                    "term": "p95 지연시간",
                    "definition": "실행의 약 95%가 이 시간 안에 끝난다는 꼬리 지연 지표다. 여기서는 nearest-rank 방식을 사용한다.",
                    "example": "N=8이면 ceil(0.95×8)=8이므로 정렬한 가장 느린 값과 같음",
                },
                {
                    "term": "VRAM",
                    "definition": "GPU가 모델 가중치와 추론 중간값을 저장하는 메모리다. 수치가 작을수록 같은 GPU에서 실행하기 쉽다.",
                    "example": "RTX 3060 Ti 8GB에서 관찰한 최대값",
                },
                {
                    "term": "NF4 4비트 양자화",
                    "definition": "원본 가중치를 실행 시 4비트 NormalFloat 형식으로 압축해 VRAM을 줄이는 방식이다. 원본 정밀도와 결과가 완전히 같다고 가정할 수 없다.",
                    "example": "다섯 모델 모두 bitsandbytes NF4, BF16 compute로 비교",
                },
                {
                    "term": "input/output token",
                    "definition": "모델이 읽거나 생성한 텍스트 조각 수다. 글자 수와 같지 않으며 모델 tokenizer마다 분할 방식이 다르다.",
                    "example": "출력 token 상한 512, protocol probe는 2,048",
                },
                {
                    "term": "0%와 N/A",
                    "definition": "0%는 실제로 실행했지만 통과하지 못했다는 뜻이고, N/A는 해당 실험을 실행하지 않아 값이 없다는 뜻이다.",
                    "example": "MedGemma의 T1은 N/A, A4 protocol은 0/1",
                },
            ],
        },
    ]
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
        "metric_definitions": metric_definitions,
        "glossary_sections": glossary_sections,
        "output_examples": output_examples,
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
