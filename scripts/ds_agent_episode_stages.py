"""Typed evaluation stages: planning, records, evidence, candidate, verification and output."""
from __future__ import annotations

from collections import Counter
from typing import Any, Mapping, Generic, TypeVar
from dataclasses import dataclass, field

try:
    from scripts.ds_agent_model_contracts import EXECUTION_MODE, SECURITY_BLOCK_CODES, TOPOLOGY_VERSION
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
    from scripts.ds_agent_results import _early_result
    from scripts.ds_agent_role_invocation import _RoleInvoker, _tool_descriptions
    from scripts.ds_agent_tool_host import (
        CONTRACT_VERSION,
        DeterministicToolHost,
        ROLE_TOOLS,
        TraceRecorder,
        deterministic_verify_answer,
        redact_trace_payload,
        verify_trace_chain,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from ds_agent_model_contracts import EXECUTION_MODE, SECURITY_BLOCK_CODES, TOPOLOGY_VERSION
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
    from ds_agent_results import _early_result
    from ds_agent_role_invocation import _RoleInvoker, _tool_descriptions
    from ds_agent_tool_host import (
        CONTRACT_VERSION,
        DeterministicToolHost,
        ROLE_TOOLS,
        TraceRecorder,
        deterministic_verify_answer,
        redact_trace_payload,
        verify_trace_chain,
    )


EpisodeResult = tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any], list[dict[str, Any]]]
T = TypeVar("T")

@dataclass(frozen=True)
class StageOutcome(Generic[T]):
    value: T | None = None
    stopped: EpisodeResult | None = None

@dataclass(frozen=True)
class EpisodeRun:
    run_id: str
    item_id: str
    split: str
    episode: Mapping[str, Any]
    state: Mapping[str, Any]
    topology_id: str
    model_roles: set[str]
    trace: TraceRecorder
    invoker: _RoleInvoker
    host: DeterministicToolHost
    available_tools: list[str]
    tool_results: list[dict[str, Any]] = field(default_factory=list)
    actual_tool_sequence: list[str] = field(default_factory=list)

@dataclass(frozen=True)
class EvidenceContext:
    pack: dict[str, Any]
    opened: list[dict[str, Any]]

@dataclass(frozen=True)
class CandidateContext:
    answer: dict[str, Any]
    prompt_context: dict[str, Any]
    instructions: list[dict[str, Any]]

@dataclass(frozen=True)
class VerifiedAnswer:
    answer: dict[str, Any]
    hard_verifier: dict[str, Any] | None
    model_verifier: dict[str, Any] | None
    effective: str
    encountered: list[str]
    rewrite_count: int
    allowed_records: set[str]
    medical_required: bool

def plan_tools(run: EpisodeRun) -> StageOutcome[None]:
    episode = run.episode
    state = run.state
    topology_id = run.topology_id
    trace = run.trace
    invoker = run.invoker
    host = run.host
    available_tools = run.available_tools
    tool_results = run.tool_results
    actual_tool_sequence = run.actual_tool_sequence
    a1_tools = sorted(set(available_tools).intersection(ROLE_TOOLS["A1"]))
    a1_context = {
        "question": episode.get("question"),
        "safety_gate_result": "continue",
        "reference_time": state.get("reference_time"),
        "knowledge_snapshot_id": state.get("knowledge_snapshot_id"),
        "allowed_tools": _tool_descriptions(a1_tools),
        "remaining_tool_budget": 8,
    }
    a1, errors = invoker.invoke("A1", a1_context)
    if a1 is None:
        return StageOutcome(stopped=_early_result(
            trace=trace,
            invoker=invoker,
            status='abstain',
            failure_codes=['SCHEMA_INVALID', *errors],
            actual_tool_sequence=[],
            topology_id=topology_id,
        ))
    if a1["status"] != "plan_ready":
        status = "out_of_scope" if a1["status"] == "out_of_scope" else "abstain"
        return StageOutcome(stopped=_early_result(
            trace=trace,
            invoker=invoker,
            status=status,
            failure_codes=['A1_EARLY_TERMINATION'],
            actual_tool_sequence=[],
            topology_id=topology_id,
        ))

    for request in a1["tool_requests"]:
        tool_name = str(request.get("tool_name"))
        actual_tool_sequence.append(tool_name)
        result = host.execute("A1", request)
        tool_results.append(result)
        if result["status"] == "rejected":
            code = str(result.get("error_code") or "TOOL_REJECTED")
            return StageOutcome(stopped=_early_result(
                trace=trace,
                invoker=invoker,
                status='block' if code in SECURITY_BLOCK_CODES else 'abstain',
                failure_codes=[code],
                actual_tool_sequence=actual_tool_sequence,
                topology_id=topology_id,
            ))
    return StageOutcome()


def collect_records(run: EpisodeRun) -> StageOutcome[dict[str, Any]]:
    episode = run.episode
    topology_id = run.topology_id
    model_roles = run.model_roles
    trace = run.trace
    invoker = run.invoker
    host = run.host
    available_tools = run.available_tools
    tool_results = run.tool_results
    actual_tool_sequence = run.actual_tool_sequence
    candidate_record_ids: list[str] = []
    for result in _tool_results_of(tool_results, "search_care_entries"):
        if result.get("status") in {"ok", "empty"}:
            entries = result.get("result", {}).get("entries", [])
            if isinstance(entries, list):
                candidate_record_ids.extend(
                    str(row["care_entry_id"])
                    for row in entries
                    if isinstance(row, Mapping) and isinstance(row.get("care_entry_id"), str)
                )
    candidate_record_ids = list(dict.fromkeys(candidate_record_ids))[:10]
    if candidate_record_ids and "get_care_entry_details" in available_tools:
        request = {
            "local_call_id": "host_a2_details_1",
            "tool_name": "get_care_entry_details",
            "arguments": {
                "care_entry_ids": candidate_record_ids,
                "required_fields": [
                    "structured_facts",
                    "original_excerpt",
                    "source_links",
                    "revision",
                ],
            },
            "reason_code": "NEED_RECORD_DETAIL",
        }
        actual_tool_sequence.append("get_care_entry_details")
        result = host.execute("A2", request)
        tool_results.append(result)
        if result["status"] == "rejected":
            return StageOutcome(stopped=_early_result(
                trace=trace,
                invoker=invoker,
                status='abstain',
                failure_codes=[str(result.get('error_code') or 'TOOL_REJECTED')],
                actual_tool_sequence=actual_tool_sequence,
                topology_id=topology_id,
            ))

    details = _detail_rows(tool_results)
    a2_context = {
        "question": episode.get("question"),
        "record_candidates_and_details": details,
        "active_clinician_instructions": _instruction_rows(tool_results),
        "required_field_mapping": {
            "care_entry_id": "copy care_entry_id exactly",
            "entry_version": "copy entry_version exactly",
            "occurred_at": "copy occurred_at exactly",
            "fact_type": "copy top-level entry_type exactly; never use a structured_facts key",
            "fact": (
                "literal summary of supplied record fields; for medication_intake include "
                "medication_display_name and intake_status without identifying the real-world drug"
            ),
            "polarity": (
                "for medication_intake: taken=positive, unknown=unknown, all other "
                "intake_status=negative; otherwise use positive or negative only when explicit"
            ),
            "certainty": "confirmed",
        },
        "rule": (
            "Use only these confirmed records and preserve exact source fields. Keep every "
            "direct match as a record fact even when drug identity is unconfirmed; do not "
            "convert its display label into a verified drug identity."
        ),
    }
    if "A2" in model_roles:
        a2, errors = invoker.invoke("A2", a2_context)
    else:
        trace.append("role_input", "A2", {"execution": "deterministic_projection"})
        a2 = _deterministic_record_pack(details)
        errors = []
        trace.append("role_output", "A2", redact_trace_payload(a2))
    if a2 is None:
        return StageOutcome(stopped=_early_result(
            trace=trace,
            invoker=invoker,
            status='abstain',
            failure_codes=['SCHEMA_INVALID', *errors],
            actual_tool_sequence=actual_tool_sequence,
            topology_id=topology_id,
        ))
    semantic_errors = _a2_semantic_errors(a2, details)
    if semantic_errors:
        return StageOutcome(stopped=_early_result(
            trace=trace,
            invoker=invoker,
            status='block',
            failure_codes=semantic_errors,
            actual_tool_sequence=actual_tool_sequence,
            record_pack=None,
            topology_id=topology_id,
        ))
    return StageOutcome(value=a2)


def collect_evidence(run: EpisodeRun, a2: dict[str, Any]) -> StageOutcome[EvidenceContext]:
    episode = run.episode
    state = run.state
    topology_id = run.topology_id
    model_roles = run.model_roles
    trace = run.trace
    invoker = run.invoker
    host = run.host
    available_tools = run.available_tools
    tool_results = run.tool_results
    actual_tool_sequence = run.actual_tool_sequence
    evidence_ids: list[str] = []
    for result in tool_results:
        if result.get("status") != "ok":
            continue
        payload = result.get("result", {})
        if result.get("tool_name") == "lookup_approved_drug_info":
            values = payload.get("evidence_span_ids", [])
            if isinstance(values, list):
                evidence_ids.extend(str(value) for value in values)
        elif result.get("tool_name") == "search_approved_evidence":
            values = payload.get("candidates", [])
            if isinstance(values, list):
                evidence_ids.extend(
                    str(value["evidence_span_id"])
                    for value in values
                    if isinstance(value, Mapping)
                    and isinstance(value.get("evidence_span_id"), str)
                )
    evidence_ids = list(dict.fromkeys(evidence_ids))[:8]
    if evidence_ids and "open_evidence_spans" in available_tools:
        request = {
            "local_call_id": "host_a3_spans_1",
            "tool_name": "open_evidence_spans",
            "arguments": {
                "evidence_span_ids": evidence_ids,
                "include_adjacent_context": False,
            },
            "reason_code": "NEED_EXACT_SPAN",
        }
        actual_tool_sequence.append("open_evidence_spans")
        result = host.execute("A3", request)
        tool_results.append(result)
        if result["status"] == "rejected":
            return StageOutcome(stopped=_early_result(
                trace=trace,
                invoker=invoker,
                status='abstain',
                failure_codes=[str(result.get('error_code') or 'EVIDENCE_NOT_FOUND')],
                actual_tool_sequence=actual_tool_sequence,
                record_pack=a2,
                topology_id=topology_id,
            ))

    opened = _opened_spans(tool_results)
    a3_context = {
        "question": episode.get("question"),
        "record_context_pack": a2,
        "knowledge_snapshot_id": state.get("knowledge_snapshot_id"),
        "approved_tool_results": [
            result
            for result in tool_results
            if result.get("tool_name")
            in {"lookup_approved_drug_info", "search_approved_evidence", "open_evidence_spans"}
        ],
        "opened_evidence_spans": opened,
    }
    if "A3" in model_roles:
        a3, errors = invoker.invoke("A3", a3_context)
    else:
        trace.append("role_input", "A3", {"execution": "deterministic_projection"})
        a3 = _deterministic_evidence_pack(
            question=episode.get("question"),
            knowledge_snapshot_id=(
                str(state["knowledge_snapshot_id"])
                if state.get("knowledge_snapshot_id") is not None
                else None
            ),
            opened_spans=opened,
        )
        errors = []
        trace.append("role_output", "A3", redact_trace_payload(a3))
    if a3 is None:
        return StageOutcome(stopped=_early_result(
            trace=trace,
            invoker=invoker,
            status='abstain',
            failure_codes=['SCHEMA_INVALID', *errors],
            actual_tool_sequence=actual_tool_sequence,
            record_pack=a2,
            topology_id=topology_id,
        ))
    a3_errors = _a3_semantic_errors(
        a3,
        knowledge_snapshot_id=(
            str(state["knowledge_snapshot_id"])
            if state.get("knowledge_snapshot_id") is not None
            else None
        ),
        opened_span_ids={str(row.get("evidence_span_id")) for row in opened},
    )
    if a3_errors:
        return StageOutcome(stopped=_early_result(
            trace=trace,
            invoker=invoker,
            status='abstain',
            failure_codes=a3_errors,
            actual_tool_sequence=actual_tool_sequence,
            record_pack=a2,
            topology_id=topology_id,
        ))
    return StageOutcome(value=EvidenceContext(a3, opened))


def draft_answer(run: EpisodeRun, a2: dict[str, Any], evidence: EvidenceContext) -> StageOutcome[CandidateContext]:
    episode = run.episode
    state = run.state
    topology_id = run.topology_id
    trace = run.trace
    invoker = run.invoker
    tool_results = run.tool_results
    actual_tool_sequence = run.actual_tool_sequence
    a3, opened = evidence.pack, evidence.opened
    instructions = _instruction_rows(tool_results)
    a4_context: dict[str, Any] = {
        "question": episode.get("question"),
        "record_context_pack": a2,
        "evidence_pack": a3,
        "opened_evidence_spans": opened,
        "active_clinician_instructions": instructions,
        "knowledge_snapshot_id": state.get("knowledge_snapshot_id"),
        "policy": {
            "no_diagnosis_or_prescription_change": True,
            "medical_claim_requires_allowed_source_id": True,
            "abstain_on_none_or_conflict": True,
        },
    }
    a4, errors = invoker.invoke("A4", a4_context)
    if a4 is None:
        return StageOutcome(stopped=_early_result(
            trace=trace,
            invoker=invoker,
            status='abstain',
            failure_codes=['SCHEMA_INVALID', *errors],
            actual_tool_sequence=actual_tool_sequence,
            record_pack=a2,
            topology_id=topology_id,
        ))
    return StageOutcome(value=CandidateContext(a4, a4_context, instructions))


def verify_candidate(run: EpisodeRun, a2: dict[str, Any], evidence: EvidenceContext, candidate: CandidateContext) -> VerifiedAnswer:
    episode = run.episode
    model_roles = run.model_roles
    trace = run.trace
    invoker = run.invoker
    a3, opened = evidence.pack, evidence.opened
    a4, a4_context, instructions = candidate.answer, candidate.prompt_context, candidate.instructions
    allowed_records = set(str(value) for value in a2.get("source_record_ids", []))
    allowed_evidence = {
        str(value.get("evidence_span_id"))
        for value in a3.get("selected_evidence", [])
        if isinstance(value, Mapping)
    }
    allowed_instructions = {
        str(value.get("clinician_instruction_id"))
        for value in instructions
        if value.get("clinician_instruction_id") is not None
    }
    medical_required = episode.get("scenario_kind") == "record_and_drug_info"
    encountered: list[str] = []
    rewrite_count = 0
    model_verifier: dict[str, Any] | None = None
    hard_verifier: dict[str, Any] | None = None
    effective = "block"
    for answer_round in range(2):
        hard_verifier = deterministic_verify_answer(
            a4,
            allowed_record_ids=allowed_records,
            allowed_evidence_ids=allowed_evidence,
            allowed_instruction_ids=allowed_instructions,
            evidence_coverage=str(a3.get("coverage")),
            medical_answer_required=medical_required,
        )
        encountered.extend(str(value) for value in hard_verifier["failure_codes"])
        a5_context = {
            "candidate_answer": a4,
            "record_context_pack": a2,
            "evidence_pack": a3,
            "opened_evidence_spans": opened,
            "active_clinician_instructions": instructions,
            "allowed_record_ids": sorted(allowed_records),
            "allowed_evidence_ids": sorted(allowed_evidence),
            "allowed_instruction_ids": sorted(allowed_instructions),
            "deterministic_gate": hard_verifier,
            "rule": "Never change a deterministic failure to pass.",
        }
        if "A5" in model_roles:
            model_verifier, errors = invoker.invoke(
                "A5",
                a5_context,
                purpose="verification" if answer_round == 0 else "rewrite_verification",
            )
        else:
            model_verifier = None
            errors = []
        if "A5" not in model_roles:
            effective = str(hard_verifier["decision"])
        elif model_verifier is None:
            encountered.extend(["SCHEMA_INVALID", *errors])
            effective = _effective_decision(str(hard_verifier["decision"]), "abstain")
        else:
            encountered.extend(str(value) for value in model_verifier["failure_codes"])
            effective = _effective_decision(
                str(hard_verifier["decision"]), str(model_verifier["decision"])
            )
        trace.append(
            "verifier_decision",
            "A5",
            {
                "round": answer_round + 1,
                "deterministic": hard_verifier,
                "model": model_verifier,
                "model_verifier_enabled": "A5" in model_roles,
                "effective_decision": effective,
            },
        )
        if effective != "rewrite_once":
            break
        if answer_round == 1:
            effective = "abstain"
            encountered.append("REWRITE_LIMIT_EXCEEDED")
            break
        rewrite_count = 1
        constraints = list(hard_verifier.get("rewrite_constraints", []))
        if model_verifier is not None:
            constraints.extend(model_verifier.get("rewrite_constraints", []))
        rewrite_context = dict(a4_context)
        rewrite_context.update(
            {
                "previous_candidate": a4,
                "rewrite_constraints": list(dict.fromkeys(str(value) for value in constraints)),
                "rewrite_rule": "Remove unsupported content. Do not add a new medical fact or source ID.",
            }
        )
        rewritten, errors = invoker.invoke("A4", rewrite_context, purpose="rewrite_once")
        if rewritten is None:
            encountered.extend(["SCHEMA_INVALID", *errors])
            effective = "abstain"
            break
        a4 = rewritten
    return VerifiedAnswer(a4, hard_verifier, model_verifier, effective, encountered, rewrite_count, allowed_records, medical_required)


def finish_episode(run: EpisodeRun, a2: dict[str, Any], evidence: EvidenceContext, verified: VerifiedAnswer) -> EpisodeResult:
    run_id = run.run_id
    item_id = run.item_id
    split = run.split
    topology_id = run.topology_id
    trace = run.trace
    invoker = run.invoker
    actual_tool_sequence = run.actual_tool_sequence
    a3, opened = evidence.pack, evidence.opened
    a4 = verified.answer
    hard_verifier = verified.hard_verifier
    model_verifier = verified.model_verifier
    effective = verified.effective
    encountered = verified.encountered
    rewrite_count = verified.rewrite_count
    allowed_records = verified.allowed_records
    medical_required = verified.medical_required
    assert hard_verifier is not None
    final_failure_codes = list(hard_verifier.get("failure_codes", []))
    if model_verifier is not None:
        final_failure_codes.extend(model_verifier.get("failure_codes", []))
    final_failure_codes = list(dict.fromkeys(str(value) for value in final_failure_codes))
    if effective == "pass":
        actual_status = "grounded_answer" if medical_required else "record_answer"
        visible = a4
        citations = _citations(a3, opened)
    elif effective == "abstain" and allowed_records and medical_required:
        actual_status = "partial_record_answer_then_abstain"
        visible = _safe_abstention_output(a2)
        citations = []
    elif effective == "block":
        actual_status = "block"
        visible = _safe_abstention_output(None, blocked=True)
        citations = []
    else:
        actual_status = "abstain"
        visible = _safe_abstention_output(a2)
        citations = []
    trace.append(
        "trace_completed",
        "HOST",
        {
            "actual_final_status": actual_status,
            "effective_verifier_decision": effective,
            "failure_codes": final_failure_codes,
            "rewrite_count": rewrite_count,
        },
    )
    events = trace.events
    verify_trace_chain(events)
    summary = {
        "schema_version": "1.0",
        "trace_id": trace.trace_id,
        "run_id": run_id,
        "item_id": item_id,
        "split": split,
        "contract_version": CONTRACT_VERSION,
        "execution_mode": EXECUTION_MODE,
        "topology_id": topology_id,
        "topology_version": TOPOLOGY_VERSION,
        "actual_final_status": actual_status,
        "actual_tool_sequence": actual_tool_sequence,
        "effective_verifier_decision": effective,
        "failure_codes": final_failure_codes,
        "encountered_failure_codes": list(dict.fromkeys(encountered)),
        "rewrite_count": rewrite_count,
        "model_role_call_counts": dict(Counter(call["role_id"] for call in invoker.calls)),
        "event_count": len(events),
        "first_event_sha256": events[0]["event_sha256"],
        "last_event_sha256": events[-1]["event_sha256"],
    }
    final_output = {
        "schema_version": "1.0",
        "trace_id": trace.trace_id,
        "item_id": item_id,
        "split": split,
        "actual_final_status": actual_status,
        "candidate_answer": a4,
        "deterministic_verifier": hard_verifier,
        "model_verifier": model_verifier,
        "effective_verifier_decision": effective,
        "user_visible_output": visible,
        "referenced_records": sorted(allowed_records),
        "citations": citations,
    }
    return events, summary, final_output, list(invoker.calls)

