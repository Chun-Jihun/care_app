"""Host-controlled evaluation episode orchestration."""
from __future__ import annotations

from typing import Any, Mapping

try:
    from scripts.ds_agent_model_contracts import (
        EXECUTION_MODE,
        ModelRunnerError,
        RoleModelBackend,
        SINGLE_POLICY_INSTRUCTION,
        TOPOLOGY_DEFINITIONS,
        TOPOLOGY_VERSION,
    )
    from scripts.ds_agent_results import _early_result
    from scripts.ds_agent_role_invocation import _RoleInvoker
    from scripts.ds_agent_tool_host import (
        CONTRACT_VERSION,
        DeterministicToolHost,
        InMemoryPilotRepository,
        TraceRecorder,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from ds_agent_model_contracts import (
        EXECUTION_MODE,
        ModelRunnerError,
        RoleModelBackend,
        SINGLE_POLICY_INSTRUCTION,
        TOPOLOGY_DEFINITIONS,
        TOPOLOGY_VERSION,
    )
    from ds_agent_results import _early_result
    from ds_agent_role_invocation import _RoleInvoker
    from ds_agent_tool_host import (
        CONTRACT_VERSION,
        DeterministicToolHost,
        InMemoryPilotRepository,
        TraceRecorder,
    )


try:
    from scripts.ds_agent_episode_stages import (
        EpisodeRun,
        plan_tools,
        collect_records,
        collect_evidence,
        draft_answer,
        verify_candidate,
        finish_episode,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from ds_agent_episode_stages import (
        EpisodeRun,
        plan_tools,
        collect_records,
        collect_evidence,
        draft_answer,
        verify_candidate,
        finish_episode,
    )

def run_model_episode(
    *,
    run_id: str,
    split: str,
    episode: Mapping[str, Any],
    state: Mapping[str, Any],
    repository: InMemoryPilotRepository,
    backend: RoleModelBackend,
    topology_id: str = "T3",
) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any], list[dict[str, Any]]]:
    """Run one compiled evaluation episode through a registered T1--T3 topology."""

    item_id = str(episode.get("item_id", ""))
    if not item_id or not run_id or not split:
        raise ModelRunnerError("run_id, split and episode item_id are required")
    if episode.get("contract_version") != CONTRACT_VERSION:
        raise ModelRunnerError("unsupported episode contract version")
    if state.get("initial_state_id") != episode.get("initial_state_id"):
        raise ModelRunnerError("episode and state do not match")
    if state.get("selected_patient_id") != episode.get("selected_patient_id"):
        raise ModelRunnerError("episode and state patient scope do not match")
    if topology_id not in TOPOLOGY_DEFINITIONS:
        raise ModelRunnerError(f"unsupported topology: {topology_id}")
    topology = TOPOLOGY_DEFINITIONS[topology_id]
    model_roles = set(str(value) for value in topology["model_roles"])
    instruction_overrides = (
        {"A1": SINGLE_POLICY_INSTRUCTION, "A4": SINGLE_POLICY_INSTRUCTION}
        if topology_id == "T1"
        else {}
    )
    trace = TraceRecorder(
        run_id=run_id,
        item_id=item_id,
        split=split,
        contract_version=CONTRACT_VERSION,
    )
    invoker = _RoleInvoker(
        backend=backend,
        trace=trace,
        item_id=item_id,
        instruction_overrides=instruction_overrides,
    )
    trace.append(
        "trace_started",
        "HOST",
        {
            "execution_mode": EXECUTION_MODE,
            "topology_id": topology_id,
            "topology_version": TOPOLOGY_VERSION,
            "runtime": dict(backend.metadata),
            "knowledge_snapshot_id": state.get("knowledge_snapshot_id"),
        },
    )
    safety_result = state.get("safety_gate_result")
    trace.append(
        "safety_gate",
        "SAFETY",
        {"result": safety_result, "rule_version": "compiled-evaluation-state-v0.1.0"},
    )
    if safety_result != "continue":
        return _early_result(
            trace=trace,
            invoker=invoker,
            status="safety_routed",
            failure_codes=["SAFETY_GATE_STOP"],
            actual_tool_sequence=[],
            topology_id=topology_id,
        )
    available_tools = [
        str(value)
        for value in episode.get("available_tools", [])
        if isinstance(value, str)
    ]
    host = DeterministicToolHost(
        repository,
        selected_patient_id=str(state["selected_patient_id"]),
        visible_record_ids=list(state.get("visible_record_ids", [])),
        reference_time=str(state["reference_time"]),
        knowledge_snapshot_id=(
            str(state["knowledge_snapshot_id"])
            if state.get("knowledge_snapshot_id") is not None
            else None
        ),
        trace=trace,
        allowed_tools=available_tools,
    )
    run = EpisodeRun(run_id, item_id, split, episode, state, topology_id,
                     model_roles, trace, invoker, host, available_tools)
    plan = plan_tools(run)
    if plan.stopped is not None:
        return plan.stopped
    records = collect_records(run)
    if records.stopped is not None:
        return records.stopped
    assert records.value is not None
    evidence = collect_evidence(run, records.value)
    if evidence.stopped is not None:
        return evidence.stopped
    assert evidence.value is not None
    candidate = draft_answer(run, records.value, evidence.value)
    if candidate.stopped is not None:
        return candidate.stopped
    assert candidate.value is not None
    verified = verify_candidate(run, records.value, evidence.value, candidate.value)
    return finish_episode(run, records.value, evidence.value, verified)
