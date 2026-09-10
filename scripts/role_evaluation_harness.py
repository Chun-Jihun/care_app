"""Compatibility entry point. Implementations live in focused evaluation modules.

No prompt, model, data approval or grading policy changes are made here.
"""

try:
    from scripts.role_evaluation_artifacts import (
        _canonical_bytes,
        _canonical_hash,
        _declared_output,
        _load_json,
        _load_jsonl,
        _load_verified_bundle,
        _nonempty_string,
        _output_declaration,
        _relative,
        _safe_path,
        _sha256_file,
        _stable_id,
        _write_atomic_bundle,
    )
    from scripts.role_evaluation_backends import (
        MirageCachedRetrievalBackend,
        ReplayBackend,
        TransformersLocalBackend,
    )
    from scripts.role_evaluation_contracts import (
        BackendResult,
        CONTRACT_VERSION,
        DEFAULT_CONTRACT_PATH,
        DEFAULT_DATA_LOCK,
        HarnessError,
        LocalBackend,
        PROMPT_VERSION,
        ROLES,
        SCHEMA_VERSION,
        SCRIPT_VERSION,
        UnsupportedProjection,
    )
    from scripts.role_evaluation_execution import (
        _generate_with_format_repair,
        run_request_bundle,
    )
    from scripts.role_evaluation_grading import (
        _call_keys,
        _candidate_calls,
        _expected_bfcl_calls,
        _failure_score,
        _load_judgments,
        _normalize_label,
        _normalized_text,
        _pubmed_normalize,
        _score,
        _span_characters,
        grade_response,
        grade_response_bundle,
    )
    from scripts.role_evaluation_rendering import (
        SYSTEM_PROMPTS,
        _json_schema,
        _longhealth_documents,
        _projection_support,
        _request,
        _source_roots_from_lock,
        render_component_case,
        render_request_bundle,
    )
    from scripts.role_evaluation_validation import (
        _first_balanced_object,
        _schema_errors,
        parse_json_response,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from role_evaluation_artifacts import (
        _canonical_bytes,
        _canonical_hash,
        _declared_output,
        _load_json,
        _load_jsonl,
        _load_verified_bundle,
        _nonempty_string,
        _output_declaration,
        _relative,
        _safe_path,
        _sha256_file,
        _stable_id,
        _write_atomic_bundle,
    )
    from role_evaluation_backends import (
        MirageCachedRetrievalBackend,
        ReplayBackend,
        TransformersLocalBackend,
    )
    from role_evaluation_contracts import (
        BackendResult,
        CONTRACT_VERSION,
        DEFAULT_CONTRACT_PATH,
        DEFAULT_DATA_LOCK,
        HarnessError,
        LocalBackend,
        PROMPT_VERSION,
        ROLES,
        SCHEMA_VERSION,
        SCRIPT_VERSION,
        UnsupportedProjection,
    )
    from role_evaluation_execution import (
        _generate_with_format_repair,
        run_request_bundle,
    )
    from role_evaluation_grading import (
        _call_keys,
        _candidate_calls,
        _expected_bfcl_calls,
        _failure_score,
        _load_judgments,
        _normalize_label,
        _normalized_text,
        _pubmed_normalize,
        _score,
        _span_characters,
        grade_response,
        grade_response_bundle,
    )
    from role_evaluation_rendering import (
        SYSTEM_PROMPTS,
        _json_schema,
        _longhealth_documents,
        _projection_support,
        _request,
        _source_roots_from_lock,
        render_component_case,
        render_request_bundle,
    )
    from role_evaluation_validation import (
        _first_balanced_object,
        _schema_errors,
        parse_json_response,
    )
