"""Compatibility entry point. Implementations live in focused evaluation modules.

No prompt, model, data approval or grading policy changes are made here.
"""

try:
    from scripts.ds_agent_episode import (
        run_model_episode,
    )
    from scripts.ds_agent_model_backends import (
        LockedTransformersNf4Backend,
        Qwen35Nf4Backend,
        ReplayRoleBackend,
        _file_sha256,
        _load_runtime_profile,
        _verify_locked_model,
    )
    from scripts.ds_agent_model_contracts import (
        EXECUTION_MODE,
        FORMAT_REPAIR_LIMIT,
        ModelGeneration,
        ModelRunnerError,
        PROMPT_VERSION,
        ROLE_INSTRUCTIONS,
        ROLE_SCHEMAS,
        RoleModelBackend,
        SCRIPT_VERSION,
        SECURITY_BLOCK_CODES,
        SINGLE_POLICY_INSTRUCTION,
        TOOL_ARGUMENT_SCHEMAS,
        TOOL_OWNER,
        TOPOLOGY_DEFINITIONS,
        TOPOLOGY_IDS,
        TOPOLOGY_VERSION,
        _CLAIM_SCHEMA,
        _EVIDENCE_SELECTION_SCHEMA,
        _ID_ARRAY,
        _RECORD_SCHEMA,
        _STRING_ARRAY,
        _TOOL_REQUEST_SCHEMA,
        _json_object,
        _object_schema,
        _schema_errors,
        _sha256,
        _type_matches,
    )
    from scripts.ds_agent_projections import (
        _a2_semantic_errors,
        _a3_semantic_errors,
        _citations,
        _detail_rows,
        _deterministic_evidence_pack,
        _deterministic_record_pack,
        _effective_decision,
        _instruction_rows,
        _opened_spans,
        _safe_abstention_output,
        _tool_results_of,
    )
    from scripts.ds_agent_results import (
        _early_result,
    )
    from scripts.ds_agent_role_invocation import (
        _RoleInvoker,
        _tool_descriptions,
    )
    from scripts.evaluation_serialization import (
        canonical_bytes as _canonical_bytes,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from ds_agent_episode import (
        run_model_episode,
    )
    from ds_agent_model_backends import (
        LockedTransformersNf4Backend,
        Qwen35Nf4Backend,
        ReplayRoleBackend,
        _file_sha256,
        _load_runtime_profile,
        _verify_locked_model,
    )
    from ds_agent_model_contracts import (
        EXECUTION_MODE,
        FORMAT_REPAIR_LIMIT,
        ModelGeneration,
        ModelRunnerError,
        PROMPT_VERSION,
        ROLE_INSTRUCTIONS,
        ROLE_SCHEMAS,
        RoleModelBackend,
        SCRIPT_VERSION,
        SECURITY_BLOCK_CODES,
        SINGLE_POLICY_INSTRUCTION,
        TOOL_ARGUMENT_SCHEMAS,
        TOOL_OWNER,
        TOPOLOGY_DEFINITIONS,
        TOPOLOGY_IDS,
        TOPOLOGY_VERSION,
        _CLAIM_SCHEMA,
        _EVIDENCE_SELECTION_SCHEMA,
        _ID_ARRAY,
        _RECORD_SCHEMA,
        _STRING_ARRAY,
        _TOOL_REQUEST_SCHEMA,
        _json_object,
        _object_schema,
        _schema_errors,
        _sha256,
        _type_matches,
    )
    from ds_agent_projections import (
        _a2_semantic_errors,
        _a3_semantic_errors,
        _citations,
        _detail_rows,
        _deterministic_evidence_pack,
        _deterministic_record_pack,
        _effective_decision,
        _instruction_rows,
        _opened_spans,
        _safe_abstention_output,
        _tool_results_of,
    )
    from ds_agent_results import (
        _early_result,
    )
    from ds_agent_role_invocation import (
        _RoleInvoker,
        _tool_descriptions,
    )
    from evaluation_serialization import (
        canonical_bytes as _canonical_bytes,
    )

__all__ = [
    "EXECUTION_MODE",
    "ModelGeneration",
    "ModelRunnerError",
    "LockedTransformersNf4Backend",
    "PROMPT_VERSION",
    "Qwen35Nf4Backend",
    "ROLE_SCHEMAS",
    "TOOL_ARGUMENT_SCHEMAS",
    "TOPOLOGY_DEFINITIONS",
    "TOPOLOGY_IDS",
    "TOPOLOGY_VERSION",
    "ReplayRoleBackend",
    "RoleModelBackend",
    "run_model_episode",
]
