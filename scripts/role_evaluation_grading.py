"""Deterministic component graders and local grading reports."""
from __future__ import annotations

from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path
import re
from typing import Any, Mapping, Sequence
import unicodedata

try:
    from scripts.role_evaluation_artifacts import (
        _canonical_bytes,
        _canonical_hash,
        _load_jsonl,
        _load_verified_bundle,
        _nonempty_string,
        _output_declaration,
        _safe_path,
        _sha256_file,
        _stable_id,
        _write_atomic_bundle,
    )
    from scripts.role_evaluation_contracts import (
        HarnessError,
        SCHEMA_VERSION,
        SCRIPT_VERSION,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from role_evaluation_artifacts import (
        _canonical_bytes,
        _canonical_hash,
        _load_jsonl,
        _load_verified_bundle,
        _nonempty_string,
        _output_declaration,
        _safe_path,
        _sha256_file,
        _stable_id,
        _write_atomic_bundle,
    )
    from role_evaluation_contracts import (
        HarnessError,
        SCHEMA_VERSION,
        SCRIPT_VERSION,
    )


def _failure_score(case: Mapping[str, Any], response: Mapping[str, Any], code: str) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "score_id": _stable_id("SCORE", case.get("case_id"), response.get("response_id"), code),
        "case_id": case.get("case_id"),
        "response_id": response.get("response_id"),
        "role_id": (case.get("target") or {}).get("roles", [None])[0],
        "scored": False,
        "metrics": {},
        "failure_codes": [code],
    }

def _score(
    case: Mapping[str, Any],
    response: Mapping[str, Any],
    metrics: Mapping[str, Any],
    *,
    failure_codes: Sequence[str] = (),
    scored: bool = True,
) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "score_id": _stable_id("SCORE", case.get("case_id"), response.get("response_id"), metrics),
        "case_id": case.get("case_id"),
        "response_id": response.get("response_id"),
        "role_id": (case.get("target") or {}).get("roles", [None])[0],
        "scored": scored,
        "metrics": dict(metrics),
        "failure_codes": list(failure_codes),
    }

def _normalize_label(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    label = unicodedata.normalize("NFKC", value).strip().upper()
    return label if label in {"A", "B", "C", "D", "E"} else None

def _normalized_text(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    return " ".join(unicodedata.normalize("NFKC", value).split()).casefold()

def _expected_bfcl_calls(value: Any) -> list[dict[str, Any]] | None:
    if not isinstance(value, list):
        return None
    result: list[dict[str, Any]] = []
    for call in value:
        if not isinstance(call, dict) or len(call) != 1:
            return None
        name, arguments = next(iter(call.items()))
        if not isinstance(name, str) or not isinstance(arguments, dict):
            return None
        result.append({"name": name, "arguments": arguments})
    return result

def _candidate_calls(value: Any) -> list[dict[str, Any]] | None:
    if not isinstance(value, list):
        return None
    result: list[dict[str, Any]] = []
    for call in value:
        if (
            not isinstance(call, dict)
            or not isinstance(call.get("name"), str)
            or not isinstance(call.get("arguments"), dict)
        ):
            return None
        result.append({"name": call["name"], "arguments": call["arguments"]})
    return result

def _call_keys(calls: Sequence[Mapping[str, Any]], unordered: bool) -> list[str]:
    values = [_canonical_bytes(call).decode("utf-8") for call in calls]
    return sorted(values) if unordered else values

def _pubmed_normalize(value: str) -> str:
    if re.fullmatch(r"PMID:\d+", value, re.IGNORECASE):
        return "PMID:" + value.split(":", 1)[1]
    match = re.search(r"(?:pubmed/|/)(\d+)/?$", value)
    return f"PMID:{match.group(1)}" if match else value

def _span_characters(spans: Any) -> set[int] | None:
    if not isinstance(spans, list):
        return None
    result: set[int] = set()
    for span in spans:
        if not isinstance(span, dict):
            return None
        start, end = span.get("start"), span.get("end")
        if not isinstance(start, int) or not isinstance(end, int) or start < 0 or end < start:
            return None
        result.update(range(start, end))
    return result

def grade_response(
    case: Mapping[str, Any],
    response: Mapping[str, Any],
    *,
    judgment: Mapping[str, Any] | None = None,
    retrieval_k: int = 10,
) -> dict[str, Any]:
    """Grade one response only where the upstream gold supports the metric."""

    if response.get("status") != "ok" or not isinstance(response.get("parsed_output"), dict):
        return _failure_score(case, response, "RESPONSE_NOT_OK")
    output = response["parsed_output"]
    source = case.get("source")
    target = case.get("target")
    gold = case.get("gold")
    if not isinstance(source, dict) or not isinstance(target, dict) or not isinstance(gold, dict):
        return _failure_score(case, response, "CASE_SCHEMA_INVALID")
    roles = target.get("roles")
    if not isinstance(roles, list) or len(roles) != 1:
        return _failure_score(case, response, "CASE_ROLE_INVALID")
    role_id, dataset_id = roles[0], source.get("dataset_id")

    if role_id == "A1" and dataset_id == "EVAL-FC-BFCL-V4":
        if gold.get("label_available") is not True:
            return _failure_score(case, response, "BFCL_GOLD_UNAVAILABLE")
        expected = _expected_bfcl_calls(gold.get("function_calls"))
        candidate = _candidate_calls(output.get("tool_calls"))
        if expected is None:
            return _failure_score(case, response, "BFCL_OFFICIAL_CHECKER_REQUIRED")
        if candidate is None:
            return _failure_score(case, response, "OUTPUT_SCHEMA_INVALID")
        category = str(source.get("category", ""))
        unordered = "parallel" in category
        expected_names = [call["name"] for call in expected]
        candidate_names = [call["name"] for call in candidate]
        if unordered:
            expected_names, candidate_names = sorted(expected_names), sorted(candidate_names)
        tool_match = expected_names == candidate_names
        exact = _call_keys(expected, unordered) == _call_keys(candidate, unordered)
        return _score(
            case,
            response,
            {
                "tool_selection_accuracy": float(tool_match),
                "argument_exact_match": float(exact),
                "adapter_call_exact_match": float(exact),
                "official_bfcl_score": False,
            },
        )

    if role_id == "A2" and dataset_id == "EVAL-LONGHEALTH":
        label = _normalize_label(output.get("answer_label"))
        acceptable = gold.get("acceptable_option_labels")
        if label is None or not isinstance(acceptable, list):
            return _failure_score(case, response, "OUTPUT_SCHEMA_INVALID")
        return _score(
            case,
            response,
            {"answer_accuracy": float(label in acceptable)},
        )

    if role_id == "A3" and dataset_id == "EVAL-MIRAGE":
        retrieval = gold.get("retrieval")
        if not isinstance(retrieval, dict) or retrieval.get("labels_available") is not True:
            return _failure_score(case, response, "RETRIEVAL_GOLD_UNAVAILABLE")
        ranked = output.get("ranked_document_ids")
        gold_ids = retrieval.get("document_ids")
        if (
            not isinstance(ranked, list)
            or any(not isinstance(value, str) for value in ranked)
            or not isinstance(gold_ids, list)
            or any(not isinstance(value, str) for value in gold_ids)
        ):
            return _failure_score(case, response, "OUTPUT_SCHEMA_INVALID")
        if ranked and all(re.fullmatch(r"pubmed\d+n\d+_\d+", value) for value in ranked):
            return _failure_score(case, response, "RETRIEVAL_ID_MAPPING_MISSING")
        if retrieval_k <= 0:
            raise HarnessError("retrieval_k는 양수여야 합니다.")
        expected = {_pubmed_normalize(value) for value in gold_ids}
        top = [_pubmed_normalize(value) for value in ranked[:retrieval_k]]
        hits = expected.intersection(top)
        recall = len(hits) / len(expected) if expected else 0.0
        first_rank = next((index for index, value in enumerate(top, 1) if value in expected), None)
        reciprocal_rank = 1.0 / first_rank if first_rank is not None else 0.0
        return _score(
            case,
            response,
            {
                "recall_at_k": recall,
                "mean_reciprocal_rank": reciprocal_rank,
                "retrieval_k": retrieval_k,
            },
        )

    if role_id == "A4" and dataset_id == "EVAL-HEALTHBENCH":
        if not isinstance(output.get("answer"), str) or not output["answer"].strip():
            return _failure_score(case, response, "OUTPUT_SCHEMA_INVALID")
        if judgment is None:
            return _failure_score(case, response, "HEALTHBENCH_JUDGMENT_REQUIRED")
        rubrics, results = gold.get("rubrics"), judgment.get("rubric_results")
        if not isinstance(rubrics, list) or not isinstance(results, list):
            return _failure_score(case, response, "HEALTHBENCH_JUDGMENT_INVALID")
        by_index: dict[int, bool] = {}
        for item in results:
            if (
                not isinstance(item, dict)
                or not isinstance(item.get("rubric_index"), int)
                or not isinstance(item.get("met"), bool)
            ):
                return _failure_score(case, response, "HEALTHBENCH_JUDGMENT_INVALID")
            by_index[item["rubric_index"]] = item["met"]
        if set(by_index) != set(range(len(rubrics))):
            return _failure_score(case, response, "HEALTHBENCH_JUDGMENT_INCOMPLETE")
        raw_score = 0.0
        positive_total = 0.0
        for index, rubric in enumerate(rubrics):
            if not isinstance(rubric, dict) or not isinstance(rubric.get("points"), (int, float)):
                return _failure_score(case, response, "HEALTHBENCH_RUBRIC_INVALID")
            points = float(rubric["points"])
            positive_total += max(points, 0.0)
            if by_index[index]:
                raw_score += points
        fraction = min(1.0, max(0.0, raw_score / positive_total)) if positive_total else 0.0
        return _score(
            case,
            response,
            {
                "local_weighted_rubric_fraction": fraction,
                "local_weighted_rubric_raw_points": raw_score,
                "official_healthbench_score": False,
            },
        )

    if role_id == "A5" and dataset_id == "EVAL-HEALTHBENCH":
        predicted = output.get("criterion_met")
        expected = gold.get("majority_label")
        if not isinstance(predicted, bool) or not isinstance(expected, bool):
            return _failure_score(case, response, "OUTPUT_SCHEMA_INVALID")
        return _score(
            case,
            response,
            {
                "verifier_accuracy": float(predicted == expected),
                "false_approval": float(predicted and not expected),
                "false_block": float(not predicted and expected),
            },
        )

    if role_id == "A5" and dataset_id == "EVAL-RAGTRUTH":
        predicted = output.get("has_hallucination")
        expected = gold.get("has_hallucination")
        if not isinstance(predicted, bool) or not isinstance(expected, bool):
            return _failure_score(case, response, "OUTPUT_SCHEMA_INVALID")
        predicted_chars = _span_characters(output.get("spans"))
        gold_chars = _span_characters(gold.get("hallucination_spans"))
        if predicted_chars is None or gold_chars is None:
            return _failure_score(case, response, "OUTPUT_SCHEMA_INVALID")
        overlap = len(predicted_chars.intersection(gold_chars))
        precision = overlap / len(predicted_chars) if predicted_chars else float(not gold_chars)
        recall = overlap / len(gold_chars) if gold_chars else float(not predicted_chars)
        span_f1 = (
            2 * precision * recall / (precision + recall)
            if precision + recall > 0
            else 0.0
        )
        return _score(
            case,
            response,
            {
                "hallucination_detection_accuracy": float(predicted == expected),
                "false_approval": float(not predicted and expected),
                "false_block": float(predicted and not expected),
                "hallucination_span_precision": precision,
                "hallucination_span_recall": recall,
                "hallucination_span_f1": span_f1,
            },
        )

    if role_id == "KO" and dataset_id == "EVAL-KORMEDMCQA":
        predicted = _normalize_label(output.get("answer_label"))
        expected = _normalize_label(gold.get("answer_label"))
        if predicted is None or expected is None:
            return _failure_score(case, response, "OUTPUT_SCHEMA_INVALID")
        return _score(case, response, {"answer_accuracy": float(predicted == expected)})

    if role_id == "KO" and dataset_id == "EVAL-KOMEDQA":
        predicted = _normalized_text(output.get("answer"))
        expected = _normalized_text(gold.get("answer"))
        if predicted is None or expected is None:
            return _failure_score(case, response, "OUTPUT_SCHEMA_INVALID")
        return _score(case, response, {"answer_exact_match": float(predicted == expected)})

    return _failure_score(case, response, "GRADER_NOT_IMPLEMENTED")

def _load_judgments(path: Path | None) -> dict[str, dict[str, Any]]:
    if path is None:
        return {}
    values = _load_jsonl(path)
    result: dict[str, dict[str, Any]] = {}
    for value in values:
        case_id = _nonempty_string(value.get("case_id"), "judgment.case_id")
        if case_id in result:
            raise HarnessError(f"중복 judgment case_id입니다: {case_id}")
        result[case_id] = value
    return result

def grade_response_bundle(
    workspace_root: Path,
    case_bundle_dir: Path,
    request_bundle_dir: Path,
    response_bundle_dir: Path,
    output_dir: Path,
    *,
    judgments_path: Path | None = None,
    retrieval_k: int = 10,
) -> Path:
    workspace_root = workspace_root.resolve()
    case_bundle = _safe_path(workspace_root, case_bundle_dir)
    request_bundle = _safe_path(workspace_root, request_bundle_dir)
    response_bundle = _safe_path(workspace_root, response_bundle_dir)
    output = _safe_path(workspace_root, output_dir)
    case_manifest, cases = _load_verified_bundle(case_bundle, "cases.jsonl")
    request_manifest, requests = _load_verified_bundle(request_bundle, "requests.jsonl")
    response_manifest, responses = _load_verified_bundle(response_bundle, "responses.jsonl")
    if response_manifest.get("request_bundle", {}).get("manifest_sha256") != _sha256_file(
        request_bundle / "manifest.json"
    ):
        raise HarnessError("response bundle이 현재 request bundle을 참조하지 않습니다.")
    if request_manifest.get("case_bundle", {}).get("manifest_sha256") != _sha256_file(
        case_bundle / "manifest.json"
    ):
        raise HarnessError("request bundle이 현재 case bundle을 참조하지 않습니다.")
    cases_by_id = {_nonempty_string(case.get("case_id"), "case_id"): case for case in cases}
    requests_by_id = {
        _nonempty_string(request.get("request_id"), "request_id"): request
        for request in requests
    }
    if len(cases_by_id) != len(cases) or len(requests_by_id) != len(requests):
        raise HarnessError("case 또는 request ID가 중복되었습니다.")
    response_request_ids = [
        _nonempty_string(response.get("request_id"), "response.request_id")
        for response in responses
    ]
    if len(set(response_request_ids)) != len(response_request_ids):
        raise HarnessError("response request_id가 중복되었습니다.")
    if set(response_request_ids) != set(requests_by_id):
        missing = sorted(set(requests_by_id).difference(response_request_ids))
        extra = sorted(set(response_request_ids).difference(requests_by_id))
        raise HarnessError(
            "response bundle이 request bundle을 정확히 덮지 않습니다. "
            f"missing={missing[:5]}, extra={extra[:5]}"
        )
    for request in requests:
        case_id = _nonempty_string(request.get("case_id"), "request.case_id")
        if case_id not in cases_by_id:
            raise HarnessError(f"request에 대응하는 case가 없습니다: {case_id}")
        declared_case_hash = (request.get("source") or {}).get("case_sha256")
        if declared_case_hash != _canonical_hash(cases_by_id[case_id]):
            raise HarnessError(f"request의 case SHA-256이 일치하지 않습니다: {case_id}")
    resolved_judgments = (
        _safe_path(workspace_root, judgments_path) if judgments_path else None
    )
    judgments = _load_judgments(resolved_judgments)
    scores: list[dict[str, Any]] = []
    for response in responses:
        request_id = _nonempty_string(response.get("request_id"), "response.request_id")
        if request_id not in requests_by_id:
            raise HarnessError(f"response에 대응하는 request가 없습니다: {request_id}")
        request = requests_by_id[request_id]
        case_id = _nonempty_string(request.get("case_id"), "request.case_id")
        if case_id not in cases_by_id or response.get("case_id") != case_id:
            raise HarnessError(f"response case 연결이 잘못되었습니다: {request_id}")
        scores.append(
            grade_response(
                cases_by_id[case_id],
                response,
                judgment=judgments.get(case_id),
                retrieval_k=retrieval_k,
            )
        )
    failure_counts: Counter[str] = Counter()
    metric_values: defaultdict[str, list[float]] = defaultdict(list)
    for score in scores:
        failure_counts.update(score.get("failure_codes", []))
        if score.get("scored") is not True:
            continue
        for name, value in score.get("metrics", {}).items():
            if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
                metric_values[name].append(float(value))
    scored_count = sum(score.get("scored") is True for score in scores)
    summary = {
        "schema_version": SCHEMA_VERSION,
        "evaluation_mode": "component_projection",
        "project_end_to_end_result": False,
        "medical_release_gate_result": False,
        "official_benchmark_result": False,
        "total_responses": len(scores),
        "scored_responses": scored_count,
        "unscored_responses": len(scores) - scored_count,
        "scoring_coverage": scored_count / len(scores) if scores else 0.0,
        "metric_means": {
            name: sum(values) / len(values)
            for name, values in sorted(metric_values.items())
            if values
        },
        "metric_denominators": {
            name: len(values) for name, values in sorted(metric_values.items())
        },
        "failure_counts": dict(sorted(failure_counts.items())),
        "limitations": [
            "Public component scores are not DS-AGENT end-to-end results.",
            "BFCL adapter exact match is not the official BFCL score.",
            "HealthBench A4 requires independently supplied rubric judgments.",
            "Medical release hard gates require project cases and clinical review.",
        ],
    }
    score_bytes = b"".join(_canonical_bytes(score) + b"\n" for score in scores)
    summary_bytes = (json.dumps(summary, ensure_ascii=False, indent=2) + "\n").encode(
        "utf-8"
    )
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "grader": {
            "script": "scripts/role_evaluation_harness.py",
            "version": SCRIPT_VERSION,
            "network_access": False,
            "retrieval_k": retrieval_k,
        },
        "inputs": {
            "case_manifest_sha256": _sha256_file(case_bundle / "manifest.json"),
            "request_manifest_sha256": _sha256_file(request_bundle / "manifest.json"),
            "response_manifest_sha256": _sha256_file(response_bundle / "manifest.json"),
            "judgments_sha256": _sha256_file(resolved_judgments)
            if resolved_judgments is not None
            else None,
        },
        "record_count": len(scores),
        "evaluation_mode": "component_projection",
        "project_end_to_end_result": False,
        "medical_release_gate_result": False,
        "outputs": [
            _output_declaration("scores.jsonl", score_bytes, len(scores)),
            {
                "file": "summary.json",
                "bytes": len(summary_bytes),
                "sha256": hashlib.sha256(summary_bytes).hexdigest(),
            },
        ],
    }
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode(
        "utf-8"
    )
    return _write_atomic_bundle(
        output,
        {
            "scores.jsonl": score_bytes,
            "summary.json": summary_bytes,
            "manifest.json": manifest_bytes,
        },
    )
