"""Project public evaluation inputs into role requests; gold labels stay outside prompts."""
from __future__ import annotations

from collections import Counter
import json
from pathlib import Path
from typing import Any, Mapping, Sequence

try:
    from scripts.role_evaluation_artifacts import (
        _canonical_bytes,
        _canonical_hash,
        _declared_output,
        _load_json,
        _load_verified_bundle,
        _nonempty_string,
        _output_declaration,
        _relative,
        _safe_path,
        _sha256_file,
        _stable_id,
        _write_atomic_bundle,
    )
    from scripts.role_evaluation_contracts import (
        CONTRACT_VERSION,
        DEFAULT_CONTRACT_PATH,
        DEFAULT_DATA_LOCK,
        HarnessError,
        PROMPT_VERSION,
        ROLES,
        SCHEMA_VERSION,
        SCRIPT_VERSION,
        UnsupportedProjection,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from role_evaluation_artifacts import (
        _canonical_bytes,
        _canonical_hash,
        _declared_output,
        _load_json,
        _load_verified_bundle,
        _nonempty_string,
        _output_declaration,
        _relative,
        _safe_path,
        _sha256_file,
        _stable_id,
        _write_atomic_bundle,
    )
    from role_evaluation_contracts import (
        CONTRACT_VERSION,
        DEFAULT_CONTRACT_PATH,
        DEFAULT_DATA_LOCK,
        HarnessError,
        PROMPT_VERSION,
        ROLES,
        SCHEMA_VERSION,
        SCRIPT_VERSION,
        UnsupportedProjection,
    )


def _json_schema(properties: Mapping[str, Any], required: Sequence[str]) -> dict[str, Any]:
    return {
        "type": "object",
        "additionalProperties": False,
        "properties": dict(properties),
        "required": list(required),
    }

SYSTEM_PROMPTS = {
    "A1": (
        "You are running an A1 tool-selection component evaluation. Select only "
        "from the supplied tools. Do not answer the user's task. Return one JSON object "
        "matching the response schema, with no prose or markdown."
    ),
    "A2": (
        "You are running an A2 longitudinal-record comprehension component evaluation. "
        "Use only the supplied fictional documents, preserve time and negation, and return "
        "one JSON object matching the response schema."
    ),
    "A3": (
        "You are running an A3 retrieval component evaluation. Use the question only; "
        "answer options and medical advice are out of scope. Return one JSON object matching "
        "the response schema."
    ),
    "A4": (
        "You are running an A4 public medical-response component evaluation, not the care "
        "app's approved-evidence RAG. Answer the supplied public prompt and return one JSON "
        "object matching the response schema."
    ),
    "A5": (
        "You are running an A5 verifier component evaluation. Judge only the supplied "
        "candidate against the supplied source or rubric. Return one JSON object matching "
        "the response schema."
    ),
    "KO": (
        "You are running a Korean medical-language supporting evaluation. Return only one "
        "JSON object matching the response schema. Do not add patient-specific advice."
    ),
}

def _request(
    case: Mapping[str, Any],
    role_id: str,
    messages: Sequence[Mapping[str, Any]],
    response_schema: Mapping[str, Any],
    *,
    projection: str,
    runtime: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    case_id = _nonempty_string(case.get("case_id"), "case_id")
    source = case.get("source")
    if not isinstance(source, dict):
        raise HarnessError(f"case source 형식이 잘못되었습니다: {case_id}")
    dataset_id = _nonempty_string(source.get("dataset_id"), "source.dataset_id")
    return {
        "schema_version": SCHEMA_VERSION,
        "request_id": _stable_id(
            "REQ", case_id, role_id, PROMPT_VERSION, projection
        ),
        "case_id": case_id,
        "role_id": role_id,
        "source": {
            "dataset_id": dataset_id,
            "split": source.get("split"),
            "record_id": source.get("record_id"),
            "case_sha256": _canonical_hash(case),
        },
        "evaluation_contract": {
            "contract_version": CONTRACT_VERSION,
            "prompt_version": PROMPT_VERSION,
            "mode": "component_projection",
            "projection": projection,
            "project_end_to_end_contract_test": False,
            "medical_release_gate": False,
        },
        "messages": [dict(message) for message in messages],
        "response_schema": dict(response_schema),
        "runtime": dict(runtime or {}),
        "policy": {
            "local_execution_only": True,
            "network_access": False,
            "do_not_train": True,
            "gold_in_prompt": False,
        },
    }

def _projection_support(case: Mapping[str, Any]) -> tuple[bool, str | None, str | None]:
    """Return whether a case can be evaluated without changing its native semantics."""

    target = case.get("target")
    source = case.get("source")
    input_value = case.get("input")
    if not isinstance(target, dict) or not isinstance(source, dict) or not isinstance(
        input_value, dict
    ):
        raise HarnessError("component case target/source/input 형식이 잘못되었습니다.")
    roles = target.get("roles")
    if not isinstance(roles, list) or len(roles) != 1:
        raise HarnessError("component case에는 정확히 하나의 역할이 있어야 합니다.")
    role_id = roles[0]
    dataset_id = source.get("dataset_id")
    if role_id != "A1" or dataset_id != "EVAL-FC-BFCL-V4":
        return True, None, None

    upstream = input_value.get("upstream_case")
    if not isinstance(upstream, dict):
        raise HarnessError("BFCL upstream_case 형식이 잘못되었습니다.")
    question = upstream.get("question")
    if not isinstance(question, list) or not question:
        raise HarnessError("BFCL question은 비어 있지 않은 turn 배열이어야 합니다.")
    functions = upstream.get("function")
    if "function" not in upstream or len(question) != 1:
        return (
            False,
            "BFCL_OFFICIAL_RUNTIME_REQUIRED",
            (
                "BFCL multi-turn, memory, web-search/agentic cases require the "
                "upstream stateful runtime and official turn-by-turn checker."
            ),
        )
    if not isinstance(functions, list):
        raise HarnessError("BFCL function은 배열이어야 합니다.")
    return True, None, None

def _longhealth_documents(
    case: Mapping[str, Any],
    source_root: Path,
    cache: dict[Path, Any],
) -> list[dict[str, str]]:
    input_value = case.get("input")
    if not isinstance(input_value, dict):
        raise HarnessError("LongHealth input 형식이 잘못되었습니다.")
    locator = input_value.get("document_locator")
    if not isinstance(locator, dict) or locator.get("materialize_at_runtime") is not True:
        raise HarnessError("LongHealth runtime document locator가 없습니다.")
    relative_file = Path(_nonempty_string(locator.get("file"), "document_locator.file"))
    path = (source_root / relative_file).resolve()
    if not path.is_relative_to(source_root.resolve()):
        raise HarnessError("LongHealth locator가 source root 밖을 가리킵니다.")
    if path not in cache:
        cache[path] = _load_json(path)
    benchmark = cache[path]
    patient_key = _nonempty_string(locator.get("patient_key"), "patient_key")
    if not isinstance(benchmark, dict) or not isinstance(benchmark.get(patient_key), dict):
        raise HarnessError(f"LongHealth patient를 찾을 수 없습니다: {patient_key}")
    patient = benchmark[patient_key]
    texts = patient.get("texts")
    if not isinstance(texts, dict):
        raise HarnessError(f"LongHealth texts 형식 오류: {patient_key}")
    name = patient.get("name") if isinstance(patient.get("name"), str) else ""
    birthday = patient.get("birthday") if isinstance(patient.get("birthday"), str) else ""
    text_ids = locator.get("text_ids")
    if not isinstance(text_ids, list) or any(not isinstance(v, str) for v in text_ids):
        raise HarnessError("LongHealth text_ids 형식이 잘못되었습니다.")
    result: list[dict[str, str]] = []
    for text_id in text_ids:
        text = texts.get(text_id)
        if not isinstance(text, str):
            raise HarnessError(f"LongHealth text를 찾을 수 없습니다: {patient_key}:{text_id}")
        if name:
            text = text.replace(name, "[PATIENT]")
        if birthday:
            text = text.replace(birthday, "[DATE_OF_BIRTH]")
        result.append({"text_id": text_id, "text": text})
    serialized = json.dumps(result, ensure_ascii=False)
    if (name and name in serialized) or (birthday and birthday in serialized):
        raise HarnessError("LongHealth 직접 식별성 필드 마스킹에 실패했습니다.")
    return result

def render_component_case(
    case: Mapping[str, Any],
    workspace_root: Path,
    *,
    source_roots: Mapping[str, Path] | None = None,
    source_cache: dict[Path, Any] | None = None,
) -> dict[str, Any]:
    """Render one adapted case without placing its gold labels in the request."""

    role_values = case.get("target", {}).get("roles", [])
    if not isinstance(role_values, list) or len(role_values) != 1:
        raise HarnessError("component case는 역할을 정확히 하나 가져야 합니다.")
    role_id = _nonempty_string(role_values[0], "target.roles[0]")
    if role_id not in ROLES:
        raise HarnessError(f"지원하지 않는 역할입니다: {role_id}")
    policy = case.get("policy")
    if (
        not isinstance(policy, dict)
        or policy.get("do_not_train") is not True
        or policy.get("mobile_bundle") is not False
        or policy.get("scenario_compiler_input") is not False
    ):
        raise HarnessError("component case의 평가 전용 경계가 안전하지 않습니다.")
    source = case.get("source")
    input_value = case.get("input")
    if not isinstance(source, dict) or not isinstance(input_value, dict):
        raise HarnessError("component case source/input 형식이 잘못되었습니다.")
    dataset_id = _nonempty_string(source.get("dataset_id"), "source.dataset_id")
    system = {"role": "system", "content": SYSTEM_PROMPTS[role_id]}

    supported, reason_code, reason = _projection_support(case)
    if not supported:
        raise UnsupportedProjection(
            _nonempty_string(reason_code, "reason_code"),
            _nonempty_string(reason, "reason"),
        )

    if role_id == "A1" and dataset_id == "EVAL-FC-BFCL-V4":
        upstream = input_value.get("upstream_case")
        if not isinstance(upstream, dict):
            raise HarnessError("BFCL upstream_case 형식이 잘못되었습니다.")
        user = {
            "role": "user",
            "content": json.dumps(
                {
                    "conversation": upstream.get("question"),
                    "available_tools": upstream.get("function", []),
                    "initial_state": {
                        key: value
                        for key, value in upstream.items()
                        if key not in {"question", "function"}
                    },
                },
                ensure_ascii=False,
            ),
        }
        schema = _json_schema(
            {
                "tool_calls": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "additionalProperties": False,
                        "properties": {
                            "name": {"type": "string"},
                            "arguments": {"type": "object"},
                        },
                        "required": ["name", "arguments"],
                    },
                }
            },
            ["tool_calls"],
        )
        return _request(
            case,
            role_id,
            [system, user],
            schema,
            projection="bfcl_native_tool_selection",
        )

    if role_id == "A2" and dataset_id == "EVAL-LONGHEALTH":
        roots = source_roots or {}
        if dataset_id not in roots:
            raise HarnessError("LongHealth source root가 필요합니다.")
        documents = _longhealth_documents(
            case, roots[dataset_id], source_cache if source_cache is not None else {}
        )
        user = {
            "role": "user",
            "content": json.dumps(
                {
                    "fictional_documents": documents,
                    "question": input_value.get("question"),
                    "options": input_value.get("options"),
                    "instruction": "Choose one option and preserve time and negation.",
                },
                ensure_ascii=False,
            ),
        }
        schema = _json_schema(
            {"answer_label": {"type": "string", "enum": ["A", "B", "C", "D", "E"]}},
            ["answer_label"],
        )
        return _request(
            case,
            role_id,
            [system, user],
            schema,
            projection="longhealth_record_comprehension",
        )

    if role_id == "A3" and dataset_id == "EVAL-MIRAGE":
        user = {
            "role": "user",
            "content": json.dumps(
                {
                    "retrieval_query": input_value.get("question"),
                    "instruction": "Return ranked document identifiers only.",
                },
                ensure_ascii=False,
            ),
        }
        schema = _json_schema(
            {
                "ranked_document_ids": {
                    "type": "array",
                    "items": {"type": "string"},
                },
                "ranked_scores": {
                    "type": "array",
                    "items": {"type": "number"},
                },
            },
            ["ranked_document_ids"],
        )
        return _request(
            case,
            role_id,
            [system, user],
            schema,
            projection="mirage_question_only_retrieval",
            runtime={
                "subset": source.get("subset"),
                "retrieval_artifact_key": input_value.get("retrieval_artifact_key"),
            },
        )

    if role_id == "A4" and dataset_id == "EVAL-HEALTHBENCH":
        prompt = input_value.get("prompt")
        if not isinstance(prompt, list):
            raise HarnessError("HealthBench prompt 형식이 잘못되었습니다.")
        messages = [system]
        for message in prompt:
            if not isinstance(message, dict):
                raise HarnessError("HealthBench message 형식이 잘못되었습니다.")
            messages.append({"role": message.get("role"), "content": message.get("content")})
        schema = _json_schema({"answer": {"type": "string"}}, ["answer"])
        return _request(
            case,
            role_id,
            messages,
            schema,
            projection="healthbench_response_generation",
        )

    if role_id == "A5" and dataset_id == "EVAL-HEALTHBENCH":
        user = {
            "role": "user",
            "content": json.dumps(
                {
                    "conversation": input_value.get("prompt"),
                    "candidate_completion": input_value.get("candidate_completion"),
                    "criterion": input_value.get("rubric"),
                    "instruction": "Decide whether the candidate satisfies the criterion.",
                },
                ensure_ascii=False,
            ),
        }
        schema = _json_schema(
            {
                "criterion_met": {"type": "boolean"},
                "rationale": {"type": "string"},
            },
            ["criterion_met"],
        )
        return _request(
            case,
            role_id,
            [system, user],
            schema,
            projection="healthbench_meta_verification",
        )

    if role_id == "A5" and dataset_id == "EVAL-RAGTRUTH":
        user = {
            "role": "user",
            "content": json.dumps(
                {
                    "task_type": input_value.get("task_type"),
                    "source_context": input_value.get("source_context"),
                    "prompt": input_value.get("prompt"),
                    "candidate_response": input_value.get("candidate_response"),
                    "instruction": (
                        "Identify unsupported or conflicting character spans in the candidate."
                    ),
                },
                ensure_ascii=False,
            ),
        }
        schema = _json_schema(
            {
                "has_hallucination": {"type": "boolean"},
                "spans": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "additionalProperties": False,
                        "properties": {
                            "start": {"type": "integer", "minimum": 0},
                            "end": {"type": "integer", "minimum": 0},
                            "label_type": {"type": "string"},
                        },
                        "required": ["start", "end"],
                    },
                },
            },
            ["has_hallucination", "spans"],
        )
        return _request(
            case,
            role_id,
            [system, user],
            schema,
            projection="ragtruth_groundedness_verification",
        )

    if role_id == "KO" and dataset_id in {"EVAL-KOMEDQA", "EVAL-KORMEDMCQA"}:
        content: dict[str, Any] = {
            "question": input_value.get("question"),
            "instruction": "Answer the Korean medical-language evaluation item.",
        }
        if "options" in input_value:
            content["options"] = input_value.get("options")
            schema = _json_schema(
                {
                    "answer_label": {
                        "type": "string",
                        "enum": ["A", "B", "C", "D", "E"],
                    }
                },
                ["answer_label"],
            )
        else:
            schema = _json_schema({"answer": {"type": "string"}}, ["answer"])
        return _request(
            case,
            role_id,
            [system, {"role": "user", "content": json.dumps(content, ensure_ascii=False)}],
            schema,
            projection="korean_medical_language_support",
        )

    raise HarnessError(f"지원하지 않는 role/dataset 조합입니다: {role_id}/{dataset_id}")

def _source_roots_from_lock(workspace_root: Path) -> dict[str, Path]:
    lock_path = workspace_root / DEFAULT_DATA_LOCK
    if not lock_path.is_file():
        return {}
    lock = _load_json(lock_path)
    roots: dict[str, Path] = {}
    if not isinstance(lock, dict):
        raise HarnessError("data source lock 형식이 잘못되었습니다.")
    for entry in lock.get("data_sources", []):
        if not isinstance(entry, dict):
            continue
        dataset_id, local_path = entry.get("id"), entry.get("local_path")
        if isinstance(dataset_id, str) and isinstance(local_path, str):
            roots[dataset_id] = _safe_path(workspace_root, workspace_root / local_path)
    return roots

def render_request_bundle(
    workspace_root: Path,
    case_bundle_dir: Path,
    output_dir: Path,
    *,
    role_id: str,
    limit: int | None = None,
) -> Path:
    workspace_root = workspace_root.resolve()
    if role_id not in ROLES:
        raise HarnessError(f"지원하지 않는 역할입니다: {role_id}")
    if limit is not None and limit <= 0:
        raise HarnessError("limit은 양의 정수여야 합니다.")
    case_bundle = _safe_path(workspace_root, case_bundle_dir)
    output = _safe_path(workspace_root, output_dir)
    case_manifest, cases = _load_verified_bundle(case_bundle, "cases.jsonl")
    if case_manifest.get("usage", {}).get("do_not_train") is not True:
        raise HarnessError("case bundle의 do-not-train 경계가 없습니다.")
    selected = [
        case
        for case in cases
        if isinstance(case.get("target"), dict)
        and role_id in case["target"].get("roles", [])
    ]
    total_matching = len(selected)
    if not selected:
        raise HarnessError(f"case bundle에 {role_id} case가 없습니다.")
    supported_cases: list[dict[str, Any]] = []
    skipped_cases: list[dict[str, Any]] = []
    for case in selected:
        supported, reason_code, reason = _projection_support(case)
        if supported:
            supported_cases.append(case)
            continue
        source = case.get("source")
        skipped_cases.append(
            {
                "schema_version": SCHEMA_VERSION,
                "case_id": _nonempty_string(case.get("case_id"), "case_id"),
                "role_id": role_id,
                "source": {
                    "dataset_id": source.get("dataset_id")
                    if isinstance(source, dict)
                    else None,
                    "split": source.get("split") if isinstance(source, dict) else None,
                    "record_id": source.get("record_id")
                    if isinstance(source, dict)
                    else None,
                    "case_sha256": _canonical_hash(case),
                },
                "reason_code": reason_code,
                "detail": reason,
            }
        )
    cases_to_render = supported_cases[:limit] if limit is not None else supported_cases
    roots = _source_roots_from_lock(workspace_root)
    cache: dict[Path, Any] = {}
    requests = [
        render_component_case(
            case,
            workspace_root,
            source_roots=roots,
            source_cache=cache,
        )
        for case in cases_to_render
    ]
    request_ids = [request["request_id"] for request in requests]
    if len(set(request_ids)) != len(request_ids):
        raise HarnessError("중복 request_id가 생성되었습니다.")
    request_bytes = b"".join(_canonical_bytes(request) + b"\n" for request in requests)
    skipped_bytes = b"".join(
        _canonical_bytes(skipped) + b"\n" for skipped in skipped_cases
    )
    contract_path = workspace_root / DEFAULT_CONTRACT_PATH
    source_bundle_partial = case_manifest.get("is_partial") is True
    limit_partial = len(requests) < len(supported_cases)
    is_partial = source_bundle_partial or limit_partial
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "renderer": {
            "script": "scripts/role_evaluation_harness.py",
            "version": SCRIPT_VERSION,
            "contract_version": CONTRACT_VERSION,
            "prompt_version": PROMPT_VERSION,
            "role_id": role_id,
            "network_access": False,
        },
        "case_bundle": {
            "path": _relative(workspace_root, case_bundle),
            "manifest_sha256": _sha256_file(case_bundle / "manifest.json"),
            "cases_sha256": _declared_output(case_manifest, "cases.jsonl").get("sha256"),
        },
        "contract": {
            "file": _relative(workspace_root, contract_path)
            if contract_path.is_file()
            else None,
            "sha256": _sha256_file(contract_path) if contract_path.is_file() else None,
        },
        "record_count": len(requests),
        "matching_case_count": total_matching,
        "projection_supported_case_count": len(supported_cases),
        "skipped_case_count": len(skipped_cases),
        "skip_reason_counts": dict(
            sorted(Counter(row["reason_code"] for row in skipped_cases).items())
        ),
        "source_bundle_partial": source_bundle_partial,
        "limit_partial": limit_partial,
        "is_partial": is_partial,
        "projection_coverage_complete": not is_partial and not skipped_cases,
        "evaluation_mode": "component_projection",
        "project_end_to_end_contract_test": False,
        "gold_in_requests": False,
        "usage": {
            "evaluation_only": True,
            "do_not_train": True,
            "mobile_bundle": False,
            "external_transmission_allowed": False,
        },
        "outputs": [
            _output_declaration("requests.jsonl", request_bytes, len(requests)),
            _output_declaration(
                "skipped_cases.jsonl", skipped_bytes, len(skipped_cases)
            ),
        ],
    }
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode(
        "utf-8"
    )
    return _write_atomic_bundle(
        output,
        {
            "requests.jsonl": request_bytes,
            "skipped_cases.jsonl": skipped_bytes,
            "manifest.json": manifest_bytes,
        },
    )
