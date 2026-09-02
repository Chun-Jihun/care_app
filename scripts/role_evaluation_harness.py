#!/usr/bin/env python3
"""Role-oriented renderer, local runner, and deterministic component graders.

Public benchmark cases are projected onto A1~A5 responsibilities without
pretending that their native tasks are project end-to-end contract tests. Gold
labels never enter model request messages. All backends are local/offline.
"""

from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass, field
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import tempfile
import time
from typing import Any, Iterable, Iterator, Mapping, Protocol, Sequence
import unicodedata


SCRIPT_VERSION = "0.2.0"
SCHEMA_VERSION = "1.0"
CONTRACT_VERSION = "0.1.0"
PROMPT_VERSION = "component-projection-v0.1.0"
DEFAULT_CONTRACT_PATH = Path("docs/agent_role_and_tool_contracts.md")
DEFAULT_DATA_LOCK = Path("experiments/agent_eval/manifests/data_sources.lock.json")
ROLES = {"A1", "A2", "A3", "A4", "A5", "KO"}


class HarnessError(RuntimeError):
    """Raised when an evaluation artifact violates the local harness contract."""


class UnsupportedProjection(HarnessError):
    """Raised when an upstream case needs a runtime this projection does not emulate."""

    def __init__(self, reason_code: str, message: str) -> None:
        super().__init__(message)
        self.reason_code = reason_code


@dataclass(frozen=True)
class BackendResult:
    raw_text: str
    usage: dict[str, Any] = field(default_factory=dict)


class LocalBackend(Protocol):
    @property
    def metadata(self) -> Mapping[str, Any]: ...

    def generate(self, request: Mapping[str, Any]) -> BackendResult: ...


def _canonical_bytes(value: object) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def _canonical_hash(value: object) -> str:
    return hashlib.sha256(_canonical_bytes(value)).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except FileNotFoundError as exc:
        raise HarnessError(f"필수 파일을 찾을 수 없습니다: {path}") from exc
    return digest.hexdigest()


def _stable_id(prefix: str, *parts: object, length: int = 20) -> str:
    text = "\x1f".join(str(part) for part in parts).encode("utf-8")
    return f"{prefix}-{hashlib.sha256(text).hexdigest()[:length].upper()}"


def _nonempty_string(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise HarnessError(f"{name}이 비어 있습니다.")
    return value.strip()


def _load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError as exc:
        raise HarnessError(f"필수 JSON을 찾을 수 없습니다: {path}") from exc
    except json.JSONDecodeError as exc:
        raise HarnessError(f"JSON 형식이 잘못되었습니다: {path}: {exc}") from exc


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as stream:
            for line_number, line in enumerate(stream, 1):
                if not line.strip():
                    raise HarnessError(f"JSONL에 빈 행이 있습니다: {path}:{line_number}")
                try:
                    value = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise HarnessError(
                        f"JSONL 형식이 잘못되었습니다: {path}:{line_number}: {exc}"
                    ) from exc
                if not isinstance(value, dict):
                    raise HarnessError(
                        f"JSONL 행은 object여야 합니다: {path}:{line_number}"
                    )
                values.append(value)
    except FileNotFoundError as exc:
        raise HarnessError(f"필수 JSONL을 찾을 수 없습니다: {path}") from exc
    return values


def _safe_path(workspace_root: Path, path: Path) -> Path:
    root = workspace_root.resolve()
    resolved = path.resolve()
    if not resolved.is_relative_to(root):
        raise HarnessError(f"workspace 밖의 경로는 사용할 수 없습니다: {path}")
    return resolved


def _relative(workspace_root: Path, path: Path) -> str:
    return _safe_path(workspace_root, path).relative_to(workspace_root.resolve()).as_posix()


def _declared_output(manifest: Mapping[str, Any], filename: str) -> Mapping[str, Any]:
    outputs = manifest.get("outputs")
    if not isinstance(outputs, list):
        raise HarnessError("bundle manifest outputs 형식이 잘못되었습니다.")
    matches = [
        value
        for value in outputs
        if isinstance(value, dict) and value.get("file") == filename
    ]
    if len(matches) != 1:
        raise HarnessError(f"manifest에서 {filename} 선언을 정확히 하나 찾아야 합니다.")
    return matches[0]


def _load_verified_bundle(
    bundle_dir: Path, filename: str
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    manifest = _load_json(bundle_dir / "manifest.json")
    if not isinstance(manifest, dict):
        raise HarnessError("bundle manifest 최상위 값은 object여야 합니다.")
    declaration = _declared_output(manifest, filename)
    path = bundle_dir / filename
    try:
        size = path.stat().st_size
    except FileNotFoundError as exc:
        raise HarnessError(f"bundle 출력 파일이 없습니다: {path}") from exc
    if size != declaration.get("bytes"):
        raise HarnessError(f"{filename} 크기가 manifest와 다릅니다.")
    if _sha256_file(path) != declaration.get("sha256"):
        raise HarnessError(f"{filename} SHA-256이 manifest와 다릅니다.")
    rows = _load_jsonl(path)
    if declaration.get("record_count") != len(rows):
        raise HarnessError(f"{filename} 레코드 수가 manifest와 다릅니다.")
    return manifest, rows


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


def _output_declaration(filename: str, content: bytes, count: int) -> dict[str, Any]:
    return {
        "file": filename,
        "bytes": len(content),
        "sha256": hashlib.sha256(content).hexdigest(),
        "record_count": count,
    }


def _write_atomic_bundle(
    output: Path,
    files: Mapping[str, bytes],
) -> Path:
    if output.exists():
        raise HarnessError(f"출력 경로가 이미 존재합니다: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}-", dir=output.parent))
    try:
        for filename, content in files.items():
            (temporary / filename).write_bytes(content)
        os.replace(temporary, output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return output


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


def _first_balanced_object(text: str) -> str | None:
    start = text.find("{")
    while start >= 0:
        depth = 0
        in_string = False
        escaped = False
        for index in range(start, len(text)):
            character = text[index]
            if in_string:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    in_string = False
                continue
            if character == '"':
                in_string = True
            elif character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
                if depth == 0:
                    return text[start : index + 1]
        start = text.find("{", start + 1)
    return None


def parse_json_response(raw_text: str) -> dict[str, Any]:
    if not isinstance(raw_text, str) or not raw_text.strip():
        raise HarnessError("모델 응답이 비어 있습니다.")
    fenced = re.search(r"```(?:json)?\s*(.*?)\s*```", raw_text, re.DOTALL | re.IGNORECASE)
    candidate = fenced.group(1) if fenced else raw_text.strip()
    try:
        value = json.loads(candidate)
    except json.JSONDecodeError:
        balanced = _first_balanced_object(candidate)
        if balanced is None:
            raise HarnessError("모델 응답에서 JSON object를 찾을 수 없습니다.")
        try:
            value = json.loads(balanced)
        except json.JSONDecodeError as exc:
            raise HarnessError(f"모델 JSON object 형식이 잘못되었습니다: {exc}") from exc
    if not isinstance(value, dict):
        raise HarnessError("모델 응답 JSON은 object여야 합니다.")
    return value


def _schema_errors(value: Any, schema: Mapping[str, Any], path: str = "$") -> list[str]:
    errors: list[str] = []
    expected_type = schema.get("type")
    type_matches = {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "boolean": isinstance(value, bool),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
    }
    if isinstance(expected_type, str) and not type_matches.get(expected_type, False):
        return [f"{path}: expected {expected_type}"]
    enum = schema.get("enum")
    if isinstance(enum, list) and value not in enum:
        errors.append(f"{path}: value is not in enum")
    minimum = schema.get("minimum")
    if isinstance(minimum, (int, float)) and isinstance(value, (int, float)):
        if value < minimum:
            errors.append(f"{path}: value is below minimum")
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        required = schema.get("required", [])
        if isinstance(required, list):
            for field_name in required:
                if field_name not in value:
                    errors.append(f"{path}.{field_name}: required field is missing")
        if schema.get("additionalProperties") is False and isinstance(properties, dict):
            for field_name in value:
                if field_name not in properties:
                    errors.append(f"{path}.{field_name}: additional field is forbidden")
        if isinstance(properties, dict):
            for field_name, field_value in value.items():
                child_schema = properties.get(field_name)
                if isinstance(child_schema, dict):
                    errors.extend(
                        _schema_errors(field_value, child_schema, f"{path}.{field_name}")
                    )
    if isinstance(value, list) and isinstance(schema.get("items"), dict):
        for index, item in enumerate(value):
            errors.extend(_schema_errors(item, schema["items"], f"{path}[{index}]"))
    return errors


class ReplayBackend:
    """Replay local raw outputs keyed by request ID; never reads case gold."""

    def __init__(self, responses: Mapping[str, str], *, replay_id: str) -> None:
        self._responses = dict(responses)
        self._replay_id = replay_id

    @property
    def metadata(self) -> Mapping[str, Any]:
        return {
            "backend": "replay",
            "replay_id": self._replay_id,
            "network_access": False,
        }

    def generate(self, request: Mapping[str, Any]) -> BackendResult:
        request_id = _nonempty_string(request.get("request_id"), "request_id")
        if request_id not in self._responses:
            raise HarnessError(f"replay 응답이 없습니다: {request_id}")
        return BackendResult(raw_text=self._responses[request_id], usage={})


class MirageCachedRetrievalBackend:
    """Read MIRAGE's local ranked IDs/scores without loading the 110GB payloads."""

    def __init__(
        self,
        source_root: Path,
        *,
        corpus: str,
        retriever: str,
        top_k: int,
    ) -> None:
        if top_k <= 0 or top_k > 10_000:
            raise HarnessError("MIRAGE top_k는 1~10000이어야 합니다.")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", corpus) or not re.fullmatch(
            r"[A-Za-z0-9._-]+", retriever
        ):
            raise HarnessError("MIRAGE corpus/retriever 형식이 안전하지 않습니다.")
        self._source_root = source_root.resolve()
        self._corpus = corpus
        self._retriever = retriever
        self._top_k = top_k

    @property
    def metadata(self) -> Mapping[str, Any]:
        return {
            "backend": "mirage_cached_retrieval",
            "corpus": self._corpus,
            "retriever": self._retriever,
            "top_k": self._top_k,
            "network_access": False,
            "retrieval_id_mapping_applied": False,
        }

    def generate(self, request: Mapping[str, Any]) -> BackendResult:
        runtime = request.get("runtime")
        if not isinstance(runtime, dict):
            raise HarnessError("A3 request runtime 형식이 잘못되었습니다.")
        subset = _nonempty_string(runtime.get("subset"), "runtime.subset")
        artifact_key = _nonempty_string(
            runtime.get("retrieval_artifact_key"), "runtime.retrieval_artifact_key"
        )
        if not re.fullmatch(r"[A-Za-z0-9._-]+", subset) or not re.fullmatch(
            r"[A-Za-z0-9._-]+", artifact_key
        ):
            raise HarnessError("MIRAGE runtime locator 형식이 안전하지 않습니다.")
        leaf = (
            self._source_root
            / "retrieved_snippets_10k"
            / subset
            / self._corpus
            / self._retriever
        ).resolve()
        if not leaf.is_relative_to(self._source_root):
            raise HarnessError("MIRAGE locator가 source root 밖을 가리킵니다.")
        score_path = leaf / "scores" / f"{artifact_key}.json"
        snippet_path = leaf / "snippets" / f"{artifact_key}.json"
        scores, snippets = _load_json(score_path), _load_json(snippet_path)
        if not isinstance(scores, list) or not isinstance(snippets, list):
            raise HarnessError("MIRAGE score/snippet 파일은 배열이어야 합니다.")
        if len(scores) != len(snippets):
            raise HarnessError("MIRAGE score와 snippet 수가 다릅니다.")
        selected_scores = scores[: self._top_k]
        selected_ids: list[str] = []
        for index, snippet in enumerate(snippets[: self._top_k]):
            if not isinstance(snippet, dict) or not isinstance(snippet.get("id"), str):
                raise HarnessError(f"MIRAGE snippet ID 형식 오류: {snippet_path}:{index}")
            selected_ids.append(snippet["id"])
        raw = json.dumps(
            {
                "ranked_document_ids": selected_ids,
                "ranked_scores": selected_scores,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
        return BackendResult(
            raw_text=raw,
            usage={
                "retrieved_count": len(selected_ids),
                "score_file_sha256": _sha256_file(score_path),
                "snippet_file_sha256": _sha256_file(snippet_path),
            },
        )


class TransformersLocalBackend:
    """Optional fully-local Transformers backend; imports dependencies lazily."""

    def __init__(
        self,
        model_path: Path,
        *,
        max_new_tokens: int = 512,
        temperature: float = 0.0,
        device_map: str = "auto",
    ) -> None:
        try:
            import torch  # type: ignore[import-not-found]
            from transformers import (  # type: ignore[import-not-found]
                AutoModelForImageTextToText,
                AutoProcessor,
            )
        except ImportError as exc:
            raise HarnessError(
                "transformers backend에는 torch와 최신 transformers가 필요합니다. "
                "현재 원본 4B 모델은 8GB GPU용 양자화도 아직 준비되지 않았습니다."
            ) from exc
        if max_new_tokens <= 0:
            raise HarnessError("max_new_tokens는 양수여야 합니다.")
        if temperature < 0:
            raise HarnessError("temperature는 0 이상이어야 합니다.")
        self._torch = torch
        self._processor = AutoProcessor.from_pretrained(
            str(model_path), local_files_only=True
        )
        self._model = AutoModelForImageTextToText.from_pretrained(
            str(model_path),
            local_files_only=True,
            torch_dtype="auto",
            device_map=device_map,
        )
        self._model.eval()
        self._model_path = model_path.resolve()
        self._max_new_tokens = max_new_tokens
        self._temperature = temperature
        self._device_map = device_map

    @property
    def metadata(self) -> Mapping[str, Any]:
        return {
            "backend": "transformers_local",
            "model_path": self._model_path.as_posix(),
            "config_sha256": _sha256_file(self._model_path / "config.json"),
            "max_new_tokens": self._max_new_tokens,
            "temperature": self._temperature,
            "device_map": self._device_map,
            "network_access": False,
            "local_files_only": True,
        }

    def generate(self, request: Mapping[str, Any]) -> BackendResult:
        messages = request.get("messages")
        if not isinstance(messages, list):
            raise HarnessError("request messages 형식이 잘못되었습니다.")
        prompt = self._processor.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        inputs = self._processor(text=[prompt], return_tensors="pt")
        device = next(self._model.parameters()).device
        inputs = {key: value.to(device) for key, value in inputs.items()}
        generation_kwargs: dict[str, Any] = {
            "max_new_tokens": self._max_new_tokens,
            "do_sample": self._temperature > 0,
        }
        if self._temperature > 0:
            generation_kwargs["temperature"] = self._temperature
        with self._torch.inference_mode():
            generated = self._model.generate(**inputs, **generation_kwargs)
        prompt_length = inputs["input_ids"].shape[1]
        decoded = self._processor.batch_decode(
            generated[:, prompt_length:], skip_special_tokens=True
        )[0]
        return BackendResult(
            raw_text=decoded,
            usage={
                "input_tokens": int(prompt_length),
                "output_tokens": int(generated.shape[1] - prompt_length),
            },
        )


def _generate_with_format_repair(
    backend: LocalBackend, request: Mapping[str, Any]
) -> BackendResult:
    """Allow one schema-only repair without changing benchmark facts or labels."""

    first = backend.generate(request)
    response_schema = request.get("response_schema")
    if not isinstance(response_schema, Mapping):
        return first
    try:
        parsed = parse_json_response(first.raw_text)
        errors = _schema_errors(parsed, response_schema)
    except HarnessError as exc:
        errors = [f"JSON_PARSE_ERROR:{exc}"]
    if not errors:
        usage = dict(first.usage)
        usage["format_repair_count"] = 0
        return BackendResult(raw_text=first.raw_text, usage=usage)
    messages = request.get("messages")
    if not isinstance(messages, list):
        return first
    repair_request = dict(request)
    repair_request["messages"] = [
        *messages,
        {
            "role": "user",
            "content": json.dumps(
                {
                    "format_repair": True,
                    "validation_errors": errors,
                    "invalid_output": first.raw_text,
                    "response_schema": dict(response_schema),
                    "instruction": (
                        "Return exactly one JSON object matching the schema. Correct keys and "
                        "structure only; do not add facts, labels, reasoning, or tool calls."
                    ),
                },
                ensure_ascii=False,
                separators=(",", ":"),
            ),
        },
    ]
    repaired = backend.generate(repair_request)
    usage = dict(repaired.usage)
    usage["format_repair_count"] = 1
    usage["initial_attempt"] = dict(first.usage)
    usage["initial_raw_output_sha256"] = hashlib.sha256(
        first.raw_text.encode("utf-8")
    ).hexdigest()
    return BackendResult(raw_text=repaired.raw_text, usage=usage)


def run_request_bundle(
    workspace_root: Path,
    request_bundle_dir: Path,
    output_dir: Path,
    backend: LocalBackend,
) -> Path:
    workspace_root = workspace_root.resolve()
    request_bundle = _safe_path(workspace_root, request_bundle_dir)
    output = _safe_path(workspace_root, output_dir)
    request_manifest, requests = _load_verified_bundle(
        request_bundle, "requests.jsonl"
    )
    responses: list[dict[str, Any]] = []
    for request in requests:
        request_id = _nonempty_string(request.get("request_id"), "request_id")
        started = time.perf_counter()
        try:
            backend_result = _generate_with_format_repair(backend, request)
            raw_text = backend_result.raw_text
            usage = dict(backend_result.usage)
            try:
                parsed = parse_json_response(raw_text)
                response_schema = request.get("response_schema")
                if not isinstance(response_schema, dict):
                    raise HarnessError("request response_schema 형식이 잘못되었습니다.")
                validation_errors = _schema_errors(parsed, response_schema)
                if validation_errors:
                    parsed = None
                    status, error_code = "schema_error", "RESPONSE_SCHEMA_INVALID"
                else:
                    status, error_code = "ok", None
            except HarnessError:
                parsed = None
                validation_errors = []
                status, error_code = "parse_error", "RESPONSE_JSON_INVALID"
        except Exception as exc:
            raw_text = ""
            parsed = None
            usage = {}
            validation_errors = []
            status, error_code = "backend_error", type(exc).__name__
        elapsed_ms = (time.perf_counter() - started) * 1000.0
        responses.append(
            {
                "schema_version": SCHEMA_VERSION,
                "response_id": _stable_id("RESP", request_id, backend.metadata),
                "request_id": request_id,
                "case_id": request.get("case_id"),
                "role_id": request.get("role_id"),
                "status": status,
                "raw_text": raw_text,
                "parsed_output": parsed,
                "error_code": error_code,
                "validation_errors": validation_errors,
                "latency_ms": elapsed_ms,
                "usage": usage,
            }
        )
    response_bytes = b"".join(_canonical_bytes(response) + b"\n" for response in responses)
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "runner": {
            "script": "scripts/role_evaluation_harness.py",
            "version": SCRIPT_VERSION,
            "network_access": False,
            "format_repair_limit": 1,
            "backend": dict(backend.metadata),
        },
        "request_bundle": {
            "path": _relative(workspace_root, request_bundle),
            "manifest_sha256": _sha256_file(request_bundle / "manifest.json"),
            "requests_sha256": _declared_output(
                request_manifest, "requests.jsonl"
            ).get("sha256"),
        },
        "record_count": len(responses),
        "status_counts": dict(sorted(Counter(v["status"] for v in responses).items())),
        "evaluation_mode": "component_projection",
        "project_end_to_end_result": False,
        "medical_release_gate_result": False,
        "usage": {
            "evaluation_only": True,
            "do_not_train": True,
            "mobile_bundle": False,
            "external_transmission_allowed": False,
        },
        "outputs": [
            _output_declaration("responses.jsonl", response_bytes, len(responses))
        ],
    }
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode(
        "utf-8"
    )
    return _write_atomic_bundle(
        output, {"responses.jsonl": response_bytes, "manifest.json": manifest_bytes}
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
