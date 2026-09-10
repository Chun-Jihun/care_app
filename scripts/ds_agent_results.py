"""Safe early termination and trace finalization for evaluation episodes."""
from __future__ import annotations

from collections import Counter
from typing import Any, Mapping, Sequence

try:
    from scripts.ds_agent_model_contracts import (
        EXECUTION_MODE,
        TOPOLOGY_VERSION,
    )
    from scripts.ds_agent_projections import (
        _safe_abstention_output,
    )
    from scripts.ds_agent_role_invocation import (
        _RoleInvoker,
    )
    from scripts.ds_agent_tool_host import (
        TraceRecorder,
        verify_trace_chain,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from ds_agent_model_contracts import (
        EXECUTION_MODE,
        TOPOLOGY_VERSION,
    )
    from ds_agent_projections import (
        _safe_abstention_output,
    )
    from ds_agent_role_invocation import (
        _RoleInvoker,
    )
    from ds_agent_tool_host import (
        TraceRecorder,
        verify_trace_chain,
    )


def _early_result(
    *,
    trace: TraceRecorder,
    invoker: _RoleInvoker,
    status: str,
    failure_codes: Sequence[str],
    actual_tool_sequence: Sequence[str],
    record_pack: Mapping[str, Any] | None = None,
    topology_id: str = "T3",
) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any], list[dict[str, Any]]]:
    blocked = status == "block"
    trace.append(
        "trace_completed",
        "HOST",
        {
            "actual_final_status": status,
            "effective_verifier_decision": status,
            "failure_codes": list(failure_codes),
        },
    )
    events = trace.events
    verify_trace_chain(events)
    summary = {
        "schema_version": "1.0",
        "trace_id": trace.trace_id,
        "run_id": trace.run_id,
        "item_id": trace.item_id,
        "split": trace.split,
        "contract_version": trace.contract_version,
        "execution_mode": EXECUTION_MODE,
        "topology_id": topology_id,
        "topology_version": TOPOLOGY_VERSION,
        "actual_final_status": status,
        "actual_tool_sequence": list(actual_tool_sequence),
        "effective_verifier_decision": status,
        "failure_codes": list(dict.fromkeys(failure_codes)),
        "encountered_failure_codes": list(dict.fromkeys(failure_codes)),
        "rewrite_count": 0,
        "model_role_call_counts": dict(Counter(call["role_id"] for call in invoker.calls)),
        "event_count": len(events),
        "first_event_sha256": events[0]["event_sha256"],
        "last_event_sha256": events[-1]["event_sha256"],
    }
    final_output = {
        "schema_version": "1.0",
        "trace_id": trace.trace_id,
        "item_id": trace.item_id,
        "split": trace.split,
        "actual_final_status": status,
        "candidate_answer": None,
        "deterministic_verifier": None,
        "model_verifier": None,
        "effective_verifier_decision": status,
        "user_visible_output": _safe_abstention_output(record_pack, blocked=blocked),
        "referenced_records": sorted(
            str(value)
            for value in (record_pack or {}).get("source_record_ids", [])
        ),
        "citations": [],
    }
    return events, summary, final_output, list(invoker.calls)
