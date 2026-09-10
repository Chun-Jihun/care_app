"""Run component request bundles with a single format-only repair."""
from __future__ import annotations

from collections import Counter
import hashlib
import json
from pathlib import Path
import time
from typing import Any, Mapping

try:
    from scripts.role_evaluation_artifacts import (
        _canonical_bytes,
        _declared_output,
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
        BackendResult,
        HarnessError,
        LocalBackend,
        SCHEMA_VERSION,
        SCRIPT_VERSION,
    )
    from scripts.role_evaluation_validation import (
        _schema_errors,
        parse_json_response,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from role_evaluation_artifacts import (
        _canonical_bytes,
        _declared_output,
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
        BackendResult,
        HarnessError,
        LocalBackend,
        SCHEMA_VERSION,
        SCRIPT_VERSION,
    )
    from role_evaluation_validation import (
        _schema_errors,
        parse_json_response,
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
