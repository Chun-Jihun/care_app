#!/usr/bin/env python3
"""Deterministic, read-only tool host for the DS-AGENT pilot.

This module deliberately contains no model runtime and performs no network access.
It validates the A1--A5 tool contract, fixes patient scope in the host, and records
every request/result in a tamper-evident trace chain.
"""

from __future__ import annotations

from collections import Counter
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
import re
from typing import Any, Iterable, Mapping, Sequence


SCRIPT_VERSION = "0.1.0"
CONTRACT_VERSION = "0.1.0"
TRACE_SCHEMA_VERSION = "0.1.0"
TRACE_EVENT_TYPES = frozenset(
    {
        "trace_started",
        "safety_gate",
        "role_input",
        "role_output",
        "tool_request",
        "tool_result",
        "verifier_decision",
        "trace_completed",
    }
)
TRACE_ROLES = frozenset({"HOST", "SAFETY", "A1", "A2", "A3", "A4", "A5"})
TRACE_EVENT_FIELDS = frozenset(
    {
        "schema_version",
        "trace_schema_version",
        "contract_version",
        "trace_id",
        "run_id",
        "item_id",
        "split",
        "event_id",
        "sequence",
        "event_type",
        "role_id",
        "payload",
        "previous_event_sha256",
        "event_sha256",
    }
)

ROLE_TOOLS: dict[str, frozenset[str]] = {
    "A1": frozenset(
        {
            "search_care_entries",
            "get_active_clinician_instructions",
            "lookup_approved_drug_info",
            "search_approved_evidence",
        }
    ),
    "A2": frozenset(
        {"get_care_entry_details", "get_active_clinician_instructions"}
    ),
    "A3": frozenset(
        {
            "lookup_approved_drug_info",
            "search_approved_evidence",
            "open_evidence_spans",
        }
    ),
    "A4": frozenset(),
    "A5": frozenset(),
}

TOOL_BUDGETS = {
    "search_care_entries": 2,
    "get_care_entry_details": 2,
    "get_active_clinician_instructions": 1,
    "lookup_approved_drug_info": 2,
    "search_approved_evidence": 2,
    "open_evidence_spans": 2,
}

REASON_CODES = frozenset(
    {
        "NEED_RELEVANT_RECORDS",
        "NEED_RECORD_DETAIL",
        "NEED_CLINICIAN_INSTRUCTION",
        "NEED_DRUG_FACTS",
        "NEED_APPROVED_EVIDENCE",
        "NEED_EXACT_SPAN",
    }
)

ENTRY_TYPES = frozenset(
    {
        "meal",
        "symptom",
        "medication_intake",
        "activity",
        "measurement",
        "daily_living",
        "incident",
        "medical_contact",
        "handoff",
        "general_note",
    }
)
DETAIL_FIELDS = frozenset(
    {"structured_facts", "original_excerpt", "source_links", "revision"}
)
INSTRUCTION_TOPICS = frozenset(
    {"medication", "meal", "hydration", "activity", "symptom", "measurement", "general"}
)
DRUG_SECTIONS = frozenset(
    {
        "efficacy",
        "usage",
        "warnings",
        "precautions",
        "interactions",
        "adverse_reactions",
        "storage",
    }
)
TOOL_TO_APPROVED_SECTION = {
    "efficacy": "effectiveness",
    "usage": "usage",
    "warnings": "warnings",
    "precautions": "precautions",
    "interactions": "interactions",
    "adverse_reactions": "adverse_reactions",
    "storage": "storage",
}
EVIDENCE_TOPICS = frozenset(
    {"drug", "meal", "hydration", "activity", "symptom", "daily_care"}
)

_FORBIDDEN_SCOPE_KEYS = frozenset(
    {
        "patient_id",
        "selected_patient_id",
        "scope_handle",
        "user_name",
        "caregiver_name",
        "contact",
        "phone",
        "phone_number",
        "email",
        "hospital_registration_number",
        "hospital_registration_id",
    }
)
_URL_PATTERN = re.compile(r"(?i)\b(?:https?|ftp)://")
_PROHIBITED_ACTION_PATTERNS = (
    re.compile(r"(?:두\s*배|2\s*배).{0,12}(?:복용|투여)"),
    re.compile(r"(?:복용량|용량).{0,12}(?:늘리|줄이|변경|조절)"),
    re.compile(r"(?:약|복용|투여).{0,12}(?:중단|끊으|추가)"),
    re.compile(r"(?:진단은|진단됩니다|확실히 치료|완치됩니다)"),
)


class HostContractError(ValueError):
    """Raised when a deterministic contract or trace invariant is violated."""

    def __init__(self, message: str, *, error_code: str = "INVALID_ARGUMENT") -> None:
        super().__init__(message)
        self.error_code = error_code


def _canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def _sha256(value: Any) -> str:
    return hashlib.sha256(_canonical_bytes(value)).hexdigest()


def _stable_id(prefix: str, *parts: str, length: int = 20) -> str:
    digest = hashlib.sha256("\x1f".join(parts).encode("utf-8")).hexdigest()
    return f"{prefix}-{digest[:length]}"


def _parse_timestamp(value: Any, field: str) -> datetime:
    if not isinstance(value, str) or not value.strip():
        raise HostContractError(f"{field} must be a non-empty RFC 3339 string")
    normalized = value.strip()
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise HostContractError(f"{field} is not RFC 3339: {value}") from exc
    if parsed.tzinfo is None:
        raise HostContractError(f"{field} must include a timezone offset")
    return parsed


def _require_exact_keys(
    value: Mapping[str, Any], *, allowed: set[str], required: set[str], label: str
) -> None:
    missing = required - set(value)
    extra = set(value) - allowed
    if missing:
        raise HostContractError(f"{label} missing fields: {sorted(missing)}")
    if extra:
        raise HostContractError(f"{label} contains extra fields: {sorted(extra)}")


def _require_string_list(
    value: Any,
    field: str,
    *,
    minimum: int,
    maximum: int,
    choices: frozenset[str] | None = None,
    max_item_length: int | None = None,
) -> list[str]:
    if not isinstance(value, list) or not minimum <= len(value) <= maximum:
        raise HostContractError(f"{field} must contain {minimum}..{maximum} strings")
    if any(not isinstance(item, str) or not item for item in value):
        raise HostContractError(f"{field} must contain only non-empty strings")
    result = list(value)
    if len(set(result)) != len(result):
        raise HostContractError(f"{field} must not contain duplicates")
    if choices is not None and any(item not in choices for item in result):
        raise HostContractError(f"{field} contains an unsupported value")
    if max_item_length is not None and any(len(item) > max_item_length for item in result):
        raise HostContractError(f"{field} contains an overlong value")
    return result


def _contains_scope_override(value: Any, *, key: str | None = None) -> bool:
    if key is not None and key.casefold() in _FORBIDDEN_SCOPE_KEYS:
        return True
    if isinstance(value, Mapping):
        return any(_contains_scope_override(item, key=str(name)) for name, item in value.items())
    if isinstance(value, list):
        return any(_contains_scope_override(item) for item in value)
    return isinstance(value, str) and bool(_URL_PATTERN.search(value))


def _redact_trace_value(value: Any, *, key: str | None = None) -> Any:
    """Remove forbidden scope values before an attempted request reaches the trace."""

    if key is not None and key.casefold() in _FORBIDDEN_SCOPE_KEYS:
        return "[REDACTED_SCOPE_FIELD]"
    if isinstance(value, Mapping):
        return {
            str(name): _redact_trace_value(item, key=str(name))
            for name, item in value.items()
        }
    if isinstance(value, list):
        return [_redact_trace_value(item) for item in value]
    if isinstance(value, str) and _URL_PATTERN.search(value):
        return "[REDACTED_URL]"
    return deepcopy(value)


def redact_trace_payload(value: Any) -> Any:
    """Return a trace-safe copy with host-controlled scope values removed."""

    return _redact_trace_value(value)


class TraceRecorder:
    """Append-only in-memory trace with a SHA-256 event chain."""

    def __init__(
        self,
        *,
        run_id: str,
        item_id: str,
        split: str,
        contract_version: str = CONTRACT_VERSION,
    ) -> None:
        if not all(isinstance(value, str) and value for value in (run_id, item_id, split)):
            raise HostContractError("run_id, item_id and split are required")
        self.run_id = run_id
        self.item_id = item_id
        self.split = split
        self.contract_version = contract_version
        self.trace_id = _stable_id("TRACE", run_id, split, item_id)
        self._events: list[dict[str, Any]] = []

    @property
    def events(self) -> list[dict[str, Any]]:
        return deepcopy(self._events)

    def append(self, event_type: str, role_id: str, payload: Mapping[str, Any]) -> dict[str, Any]:
        if not isinstance(event_type, str) or not event_type:
            raise HostContractError("event_type is required")
        if event_type not in TRACE_EVENT_TYPES:
            raise HostContractError(f"unsupported trace event type: {event_type}")
        if role_id not in TRACE_ROLES:
            raise HostContractError(f"unsupported trace role: {role_id}")
        sequence = len(self._events) + 1
        previous_hash = self._events[-1]["event_sha256"] if self._events else None
        event: dict[str, Any] = {
            "schema_version": "1.0",
            "trace_schema_version": TRACE_SCHEMA_VERSION,
            "contract_version": self.contract_version,
            "trace_id": self.trace_id,
            "run_id": self.run_id,
            "item_id": self.item_id,
            "split": self.split,
            "event_id": f"{self.trace_id}-E{sequence:04d}",
            "sequence": sequence,
            "event_type": event_type,
            "role_id": role_id,
            "payload": deepcopy(dict(payload)),
            "previous_event_sha256": previous_hash,
        }
        event["event_sha256"] = _sha256(event)
        self._events.append(event)
        return deepcopy(event)


def verify_trace_chain(events: Sequence[Mapping[str, Any]]) -> None:
    if not events:
        raise HostContractError("trace must contain at least one event")
    trace_id = events[0].get("trace_id")
    identity = tuple(
        events[0].get(field)
        for field in ("trace_id", "run_id", "item_id", "split", "contract_version")
    )
    previous_hash: str | None = None
    for expected_sequence, raw_event in enumerate(events, start=1):
        event = dict(raw_event)
        if set(event) != TRACE_EVENT_FIELDS:
            raise HostContractError("trace event does not match the trace schema fields")
        if event.get("schema_version") != "1.0":
            raise HostContractError("unsupported trace event schema_version")
        if event.get("trace_schema_version") != TRACE_SCHEMA_VERSION:
            raise HostContractError("unsupported trace_schema_version")
        if tuple(
            event.get(field)
            for field in ("trace_id", "run_id", "item_id", "split", "contract_version")
        ) != identity:
            raise HostContractError("trace identity changed inside a trace")
        if event.get("sequence") != expected_sequence:
            raise HostContractError("trace sequence is not contiguous")
        if event.get("event_id") != f"{trace_id}-E{expected_sequence:04d}":
            raise HostContractError("trace event_id does not match its sequence")
        if event.get("event_type") not in TRACE_EVENT_TYPES:
            raise HostContractError("unsupported trace event type")
        if event.get("role_id") not in TRACE_ROLES:
            raise HostContractError("unsupported trace role")
        if not isinstance(event.get("payload"), dict):
            raise HostContractError("trace payload must be an object")
        if event.get("previous_event_sha256") != previous_hash:
            raise HostContractError("trace previous hash mismatch")
        stored_hash = event.pop("event_sha256", None)
        if not isinstance(stored_hash, str) or stored_hash != _sha256(event):
            raise HostContractError("trace event hash mismatch")
        previous_hash = stored_hash


class InMemoryPilotRepository:
    """Read-only repository used by the deterministic pilot host."""

    def __init__(
        self,
        *,
        care_entries: Sequence[Mapping[str, Any]],
        clinician_instructions: Sequence[Mapping[str, Any]],
        approved_products: Sequence[Mapping[str, Any]],
        evidence_spans: Sequence[Mapping[str, Any]],
    ) -> None:
        self.care_entries = self._index(care_entries, "care_entry_id")
        self.clinician_instructions = self._index(
            clinician_instructions, "clinician_instruction_id", allow_empty=True
        )
        self.approved_products = self._index_products(approved_products)
        self.evidence_spans = self._index(evidence_spans, "span_id", allow_empty=True)

    @staticmethod
    def _index(
        rows: Sequence[Mapping[str, Any]], key: str, *, allow_empty: bool = False
    ) -> dict[str, dict[str, Any]]:
        indexed: dict[str, dict[str, Any]] = {}
        for row in rows:
            identifier = row.get(key)
            if not isinstance(identifier, str) or not identifier:
                if allow_empty:
                    raise HostContractError(f"repository row missing {key}")
                raise HostContractError(f"repository row missing {key}")
            if identifier in indexed:
                raise HostContractError(f"duplicate repository identifier: {identifier}")
            indexed[identifier] = deepcopy(dict(row))
        return indexed

    @staticmethod
    def _index_products(rows: Sequence[Mapping[str, Any]]) -> dict[str, dict[str, Any]]:
        indexed: dict[str, dict[str, Any]] = {}
        for row in rows:
            item_seq = row.get("item_seq")
            if not isinstance(item_seq, str) or not item_seq:
                raise HostContractError("approved product missing item_seq")
            if item_seq in indexed:
                raise HostContractError(f"duplicate approved product: {item_seq}")
            indexed[item_seq] = deepcopy(dict(row))
        return indexed


class DeterministicToolHost:
    """Contract-enforcing host for the six read-only A1--A3 tools."""

    total_budget = 8

    def __init__(
        self,
        repository: InMemoryPilotRepository,
        *,
        selected_patient_id: str,
        visible_record_ids: Sequence[str],
        reference_time: str,
        knowledge_snapshot_id: str | None,
        trace: TraceRecorder,
        allowed_tools: Sequence[str] | None = None,
    ) -> None:
        self.repository = repository
        self._selected_patient_id = selected_patient_id
        self._visible_record_ids = frozenset(visible_record_ids)
        self.reference_time = _parse_timestamp(reference_time, "reference_time")
        self.knowledge_snapshot_id = knowledge_snapshot_id
        requested_tools = set(allowed_tools) if allowed_tools is not None else set(TOOL_BUDGETS)
        unknown_tools = requested_tools.difference(TOOL_BUDGETS)
        if unknown_tools:
            raise HostContractError(
                f"unknown tools in episode capability set: {', '.join(sorted(unknown_tools))}",
                error_code="TOOL_NOT_ALLOWED",
            )
        self._allowed_tools = frozenset(requested_tools)
        self.trace = trace
        self._total_calls = 0
        self._execution_attempts = 0
        self._tool_calls: Counter[str] = Counter()
        self._local_call_ids: set[str] = set()
        self._returned_record_ids: set[str] = set()
        self._returned_evidence_ids: set[str] = set()

    def execute(self, role_id: str, request: Mapping[str, Any]) -> dict[str, Any]:
        self._execution_attempts += 1
        execution_id = f"tool_exec_{self._execution_attempts:03d}"
        request_payload = deepcopy(dict(request)) if isinstance(request, Mapping) else {}
        self.trace.append(
            "tool_request",
            role_id if role_id in ROLE_TOOLS else "HOST",
            {"execution_id": execution_id, "request": _redact_trace_value(request_payload)},
        )
        tool_name = request_payload.get("tool_name")
        if not isinstance(tool_name, str):
            tool_name = "invalid_tool"
        try:
            result = self._execute_checked(role_id, request_payload, execution_id)
        except HostContractError as exc:
            result = self._envelope(
                execution_id,
                tool_name,
                status="rejected",
                result={},
                error_code=exc.error_code,
                versions=[],
            )
        self.trace.append("tool_result", "HOST", result)
        return result

    def _execute_checked(
        self, role_id: str, request: Mapping[str, Any], execution_id: str
    ) -> dict[str, Any]:
        if role_id not in ROLE_TOOLS:
            raise HostContractError("unknown role", error_code="TOOL_NOT_ALLOWED")
        _require_exact_keys(
            request,
            allowed={"local_call_id", "tool_name", "arguments", "reason_code"},
            required={"local_call_id", "tool_name", "arguments", "reason_code"},
            label="tool request",
        )
        local_call_id = request["local_call_id"]
        tool_name = request["tool_name"]
        arguments = request["arguments"]
        reason_code = request["reason_code"]
        if not isinstance(local_call_id, str) or not local_call_id:
            raise HostContractError("local_call_id must be a non-empty string")
        if local_call_id in self._local_call_ids:
            raise HostContractError("local_call_id must be unique")
        self._local_call_ids.add(local_call_id)
        if not isinstance(tool_name, str) or tool_name not in TOOL_BUDGETS:
            raise HostContractError("unknown tool", error_code="TOOL_NOT_ALLOWED")
        if tool_name not in self._allowed_tools:
            raise HostContractError(
                "tool is not enabled for this episode", error_code="TOOL_NOT_ALLOWED"
            )
        if not isinstance(arguments, Mapping):
            raise HostContractError("arguments must be an object")
        if _contains_scope_override(arguments):
            raise HostContractError(
                "patient scope, identity fields, and URLs are host controlled",
                error_code="SCOPE_OVERRIDE_ATTEMPT",
            )
        if tool_name not in ROLE_TOOLS[role_id]:
            raise HostContractError(
                f"{role_id} cannot request {tool_name}", error_code="TOOL_NOT_ALLOWED"
            )
        if reason_code not in REASON_CODES:
            raise HostContractError("unsupported reason_code")
        if self._total_calls >= self.total_budget:
            raise HostContractError(
                "episode tool budget exhausted", error_code="TOOL_BUDGET_EXCEEDED"
            )
        if self._tool_calls[tool_name] >= TOOL_BUDGETS[tool_name]:
            raise HostContractError(
                f"tool budget exhausted for {tool_name}",
                error_code="TOOL_BUDGET_EXCEEDED",
            )
        self._total_calls += 1
        self._tool_calls[tool_name] += 1
        handler = getattr(self, f"_tool_{tool_name}")
        result, versions = handler(dict(arguments))
        status = (
            "empty"
            if result.get("entries") == [] or result.get("instructions") == []
            else "ok"
        )
        return self._envelope(
            execution_id,
            tool_name,
            status=status,
            result=result,
            error_code=None,
            versions=versions,
        )

    @staticmethod
    def _envelope(
        execution_id: str,
        tool_name: str,
        *,
        status: str,
        result: Mapping[str, Any],
        error_code: str | None,
        versions: Sequence[Mapping[str, Any]],
    ) -> dict[str, Any]:
        return {
            "execution_id": execution_id,
            "tool_name": tool_name,
            "status": status,
            "result": deepcopy(dict(result)),
            "error_code": error_code,
            "is_complete": True,
            "snapshot_or_record_versions": deepcopy(list(versions)),
        }

    def _tool_search_care_entries(
        self, arguments: dict[str, Any]
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        _require_exact_keys(
            arguments,
            allowed={"entry_types", "from_utc", "to_utc", "query_terms", "limit"},
            required={"entry_types", "from_utc", "to_utc"},
            label="search_care_entries arguments",
        )
        entry_types = _require_string_list(
            arguments["entry_types"],
            "entry_types",
            minimum=1,
            maximum=5,
            choices=ENTRY_TYPES,
        )
        from_time = _parse_timestamp(arguments["from_utc"], "from_utc")
        to_time = _parse_timestamp(arguments["to_utc"], "to_utc")
        if from_time >= to_time:
            raise HostContractError("from_utc must precede to_utc")
        if to_time > self.reference_time:
            raise HostContractError("to_utc must not exceed reference_time")
        query_terms = _require_string_list(
            arguments.get("query_terms", []),
            "query_terms",
            minimum=0,
            maximum=5,
            max_item_length=50,
        )
        limit = arguments.get("limit", 10)
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 20:
            raise HostContractError("limit must be an integer from 1 to 20")
        candidates: list[dict[str, Any]] = []
        for entry_id in sorted(self._visible_record_ids):
            entry = self.repository.care_entries.get(entry_id)
            if entry is None:
                continue
            if entry.get("patient_id") != self._selected_patient_id:
                continue
            if entry.get("confirmation_status") != "confirmed":
                continue
            if entry.get("entry_type") not in entry_types:
                continue
            occurred_at = _parse_timestamp(entry.get("occurred_at"), "occurred_at")
            if not from_time <= occurred_at <= to_time:
                continue
            searchable = (
                str(entry.get("original_excerpt", ""))
                + " "
                + json.dumps(entry.get("structured_facts", {}), ensure_ascii=False)
            ).casefold()
            if query_terms and not all(term.casefold() in searchable for term in query_terms):
                continue
            offset = occurred_at.utcoffset()
            candidates.append(
                {
                    "care_entry_id": entry_id,
                    "entry_version": entry.get("entry_version"),
                    "entry_type": entry.get("entry_type"),
                    "occurred_at": entry.get("occurred_at"),
                    "timezone_offset_min": int(offset.total_seconds() // 60) if offset else 0,
                    "confirmation_status": "confirmed",
                    "structured_facts": deepcopy(entry.get("structured_facts", {})),
                    "original_excerpt": str(entry.get("original_excerpt", ""))[:300],
                }
            )
        candidates.sort(key=lambda row: (str(row["occurred_at"]), row["care_entry_id"]))
        candidates = candidates[:limit]
        self._returned_record_ids.update(row["care_entry_id"] for row in candidates)
        versions = [
            {"care_entry_id": row["care_entry_id"], "entry_version": row["entry_version"]}
            for row in candidates
        ]
        return {"entries": candidates}, versions

    def _tool_get_care_entry_details(
        self, arguments: dict[str, Any]
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        _require_exact_keys(
            arguments,
            allowed={"care_entry_ids", "required_fields"},
            required={"care_entry_ids", "required_fields"},
            label="get_care_entry_details arguments",
        )
        entry_ids = _require_string_list(
            arguments["care_entry_ids"], "care_entry_ids", minimum=1, maximum=10
        )
        fields = _require_string_list(
            arguments["required_fields"],
            "required_fields",
            minimum=1,
            maximum=4,
            choices=DETAIL_FIELDS,
        )
        if any(entry_id not in self._returned_record_ids for entry_id in entry_ids):
            raise HostContractError(
                "record was not returned by this trace search",
                error_code="RECORD_NOT_FOUND",
            )
        rows: list[dict[str, Any]] = []
        versions: list[dict[str, Any]] = []
        for entry_id in entry_ids:
            entry = self.repository.care_entries.get(entry_id)
            if (
                entry is None
                or entry.get("patient_id") != self._selected_patient_id
                or entry.get("confirmation_status") != "confirmed"
            ):
                raise HostContractError("record not found", error_code="RECORD_NOT_FOUND")
            row: dict[str, Any] = {
                "care_entry_id": entry_id,
                "entry_version": entry.get("entry_version"),
                "entry_type": entry.get("entry_type"),
                "occurred_at": entry.get("occurred_at"),
                "confirmation_status": entry.get("confirmation_status"),
            }
            if "structured_facts" in fields:
                row["structured_facts"] = deepcopy(entry.get("structured_facts", {}))
            if "original_excerpt" in fields:
                row["original_excerpt"] = str(entry.get("original_excerpt", ""))[:600]
            if "source_links" in fields:
                row["source_links"] = deepcopy(entry.get("source_links", []))
            if "revision" in fields:
                row["revision"] = entry.get("entry_version")
            rows.append(row)
            versions.append(
                {"care_entry_id": entry_id, "entry_version": entry.get("entry_version")}
            )
        return {"entries": rows}, versions

    def _tool_get_active_clinician_instructions(
        self, arguments: dict[str, Any]
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        _require_exact_keys(
            arguments,
            allowed={"topics", "as_of_utc"},
            required={"topics"},
            label="get_active_clinician_instructions arguments",
        )
        topics = _require_string_list(
            arguments["topics"],
            "topics",
            minimum=1,
            maximum=5,
            choices=INSTRUCTION_TOPICS,
        )
        as_of = _parse_timestamp(
            arguments.get("as_of_utc", self.reference_time.isoformat()), "as_of_utc"
        )
        if as_of > self.reference_time:
            raise HostContractError("as_of_utc must not exceed reference_time")
        rows: list[dict[str, Any]] = []
        versions: list[dict[str, Any]] = []
        for instruction_id in sorted(self.repository.clinician_instructions):
            instruction = self.repository.clinician_instructions[instruction_id]
            if instruction.get("patient_id") != self._selected_patient_id:
                continue
            if instruction.get("status") != "active":
                continue
            if instruction.get("verification_status") != "clinician_verified":
                continue
            if instruction.get("topic") not in topics:
                continue
            valid_from = instruction.get("valid_from")
            valid_until = instruction.get("valid_until")
            if valid_from and _parse_timestamp(valid_from, "valid_from") > as_of:
                continue
            if valid_until and _parse_timestamp(valid_until, "valid_until") < as_of:
                continue
            row = {
                key: deepcopy(instruction.get(key))
                for key in (
                    "clinician_instruction_id",
                    "instruction_text",
                    "topic",
                    "source_type",
                    "verification_status",
                    "valid_from",
                    "valid_until",
                    "status",
                    "supersedes_instruction_id",
                    "source_record_id",
                )
            }
            rows.append(row)
            versions.append(
                {
                    "clinician_instruction_id": instruction_id,
                    "version": instruction.get("version", 1),
                }
            )
        return {"instructions": rows}, versions

    def _require_knowledge(self) -> None:
        if not self.knowledge_snapshot_id:
            raise HostContractError(
                "no approved knowledge snapshot is fixed for this trace",
                error_code="EVIDENCE_NOT_FOUND",
            )

    def _tool_lookup_approved_drug_info(
        self, arguments: dict[str, Any]
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        self._require_knowledge()
        _require_exact_keys(
            arguments,
            allowed={"item_seq", "item_name", "requested_sections"},
            required={"requested_sections"},
            label="lookup_approved_drug_info arguments",
        )
        item_seq = arguments.get("item_seq")
        item_name = arguments.get("item_name")
        if (isinstance(item_seq, str) and bool(item_seq)) == (
            isinstance(item_name, str) and bool(item_name)
        ):
            raise HostContractError("exactly one of item_seq and item_name is required")
        sections = _require_string_list(
            arguments["requested_sections"],
            "requested_sections",
            minimum=1,
            maximum=7,
            choices=DRUG_SECTIONS,
        )
        matches: list[dict[str, Any]] = []
        if item_seq:
            product = self.repository.approved_products.get(item_seq)
            if product is not None:
                matches = [product]
        else:
            normalized = str(item_name).strip().casefold()
            matches = [
                product
                for product in self.repository.approved_products.values()
                if str(product.get("product_name") or product.get("item_name", ""))
                .strip()
                .casefold()
                == normalized
            ]
        if not matches:
            raise HostContractError("approved drug not found", error_code="EVIDENCE_NOT_FOUND")
        if len(matches) > 1:
            candidates = [
                {
                    "item_seq": item["item_seq"],
                    "item_name": item.get("product_name") or item.get("item_name"),
                }
                for item in sorted(matches, key=lambda row: str(row["item_seq"]))
            ]
            return {
                "requires_user_confirmation": True,
                "candidates": candidates,
            }, [{"knowledge_snapshot_id": self.knowledge_snapshot_id}]
        product = matches[0]
        product_snapshot_id = product.get("approval_id") or product.get(
            "knowledge_snapshot_id"
        )
        if product_snapshot_id not in (None, self.knowledge_snapshot_id):
            raise HostContractError("product belongs to another snapshot", error_code="EVIDENCE_NOT_FOUND")
        section_data: dict[str, list[str]] = {}
        approved_span_map = product.get("approved_span_ids_by_section", {})
        normalized_span_map = product.get("evidence_span_ids_by_section", {})
        span_ids_by_tool_section: dict[str, list[str]] = {}
        for section in sections:
            approved_section = TOOL_TO_APPROVED_SECTION[section]
            section_span_ids = approved_span_map.get(
                approved_section, normalized_span_map.get(section, [])
            )
            if not isinstance(section_span_ids, list):
                raise HostContractError("approved product span map is invalid")
            span_ids_by_tool_section[section] = [str(value) for value in section_span_ids]
            texts = [
                str(
                    self.repository.evidence_spans[span_id].get("supporting_span")
                    or self.repository.evidence_spans[span_id].get("text")
                )
                for span_id in span_ids_by_tool_section[section]
                if span_id in self.repository.evidence_spans
            ]
            if texts:
                section_data[section] = texts
        span_ids = sorted(
            {
                str(span_id)
                for section in sections
                for span_id in span_ids_by_tool_section[section]
            }
        )
        self._returned_evidence_ids.update(span_ids)
        result = {
            "requires_user_confirmation": False,
            "item_seq": product["item_seq"],
            "item_name": product.get("product_name") or product.get("item_name"),
            "provider": product.get("provider") or "식품의약품안전처",
            "data_as_of": product.get("updated_at")
            or product.get("disclosed_at")
            or product.get("data_as_of"),
            "sections": section_data,
            "evidence_span_ids": span_ids,
        }
        return result, [{"knowledge_snapshot_id": self.knowledge_snapshot_id}]

    def _tool_search_approved_evidence(
        self, arguments: dict[str, Any]
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        self._require_knowledge()
        _require_exact_keys(
            arguments,
            allowed={"query", "topics", "clinical_scope", "top_k"},
            required={"query", "topics"},
            label="search_approved_evidence arguments",
        )
        query = arguments["query"]
        if not isinstance(query, str) or not 1 <= len(query.strip()) <= 300:
            raise HostContractError("query must contain 1..300 characters")
        topics = _require_string_list(
            arguments["topics"],
            "topics",
            minimum=1,
            maximum=3,
            choices=EVIDENCE_TOPICS,
        )
        if "clinical_scope" in arguments:
            _require_string_list(
                arguments["clinical_scope"],
                "clinical_scope",
                minimum=1,
                maximum=10,
                max_item_length=80,
            )
        top_k = arguments.get("top_k", 5)
        if isinstance(top_k, bool) or not isinstance(top_k, int) or not 1 <= top_k <= 5:
            raise HostContractError("top_k must be an integer from 1 to 5")
        query_tokens = set(re.findall(r"[0-9A-Za-z가-힣]+", query.casefold()))
        scored: list[tuple[float, str, dict[str, Any]]] = []
        for span_id, span in self.repository.evidence_spans.items():
            span_snapshot_id = span.get("approval_id") or span.get(
                "knowledge_snapshot_id"
            )
            if span_snapshot_id not in (None, self.knowledge_snapshot_id):
                continue
            if span.get("review_status", "clinician_approved") != "clinician_approved":
                continue
            if span.get("revoked", False) is True:
                continue
            span_topics = set(span.get("topics", [])) or {"drug"}
            if span_topics and not span_topics.intersection(topics):
                continue
            text = str(span.get("supporting_span") or span.get("text", ""))
            haystack = set(re.findall(r"[0-9A-Za-z가-힣]+", text.casefold()))
            score = len(query_tokens.intersection(haystack)) / max(len(query_tokens), 1)
            if score <= 0:
                continue
            scored.append((score, span_id, span))
        scored.sort(key=lambda item: (-item[0], item[1]))
        candidates: list[dict[str, Any]] = []
        for score, span_id, span in scored[:top_k]:
            candidates.append(
                {
                    "evidence_span_id": span_id,
                    "document_id": span.get("document_id"),
                    "document_version": span.get("document_version"),
                    "chunk_id": span.get("chunk_id"),
                    "page_or_section": span.get("location")
                    or span.get("page_or_section"),
                    "publisher": span.get("publisher"),
                    "revision_date": span.get("published_or_revised_at")
                    or span.get("revision_date"),
                    "reviewed_at": span.get("reviewed_at"),
                    "source_url": span.get("source_url"),
                    "title": span.get("source_title") or span.get("title"),
                    "score": round(score, 6),
                }
            )
        self._returned_evidence_ids.update(
            candidate["evidence_span_id"] for candidate in candidates
        )
        if not candidates:
            raise HostContractError("approved evidence not found", error_code="EVIDENCE_NOT_FOUND")
        return {"candidates": candidates}, [
            {"knowledge_snapshot_id": self.knowledge_snapshot_id}
        ]

    def _tool_open_evidence_spans(
        self, arguments: dict[str, Any]
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        self._require_knowledge()
        _require_exact_keys(
            arguments,
            allowed={"evidence_span_ids", "include_adjacent_context"},
            required={"evidence_span_ids"},
            label="open_evidence_spans arguments",
        )
        span_ids = _require_string_list(
            arguments["evidence_span_ids"],
            "evidence_span_ids",
            minimum=1,
            maximum=8,
        )
        adjacent = arguments.get("include_adjacent_context", False)
        if not isinstance(adjacent, bool):
            raise HostContractError("include_adjacent_context must be boolean")
        if any(span_id not in self._returned_evidence_ids for span_id in span_ids):
            raise HostContractError(
                "evidence span was not returned by this trace",
                error_code="EVIDENCE_NOT_FOUND",
            )
        rows: list[dict[str, Any]] = []
        for span_id in span_ids:
            span = self.repository.evidence_spans.get(span_id)
            span_snapshot_id = (
                span.get("approval_id") or span.get("knowledge_snapshot_id")
                if span is not None
                else None
            )
            if span is None or span_snapshot_id not in (None, self.knowledge_snapshot_id):
                raise HostContractError("evidence not found", error_code="EVIDENCE_NOT_FOUND")
            supporting_span = span.get("supporting_span") or span.get("text")
            source_hash = span.get("source_hash")
            text_sha256 = (
                source_hash.removeprefix("sha256:")
                if isinstance(source_hash, str) and source_hash
                else span.get("text_sha256")
                or hashlib.sha256(str(supporting_span).encode("utf-8")).hexdigest()
            )
            rows.append(
                {
                    "evidence_span_id": span_id,
                    "text": supporting_span,
                    "text_sha256": text_sha256,
                    "document_id": span.get("document_id"),
                    "document_version": span.get("document_version"),
                    "chunk_id": span.get("chunk_id"),
                    "page_or_section": span.get("location")
                    or span.get("page_or_section"),
                    "title": span.get("source_title") or span.get("title"),
                    "publisher": span.get("publisher"),
                    "revision_date": span.get("published_or_revised_at")
                    or span.get("revision_date"),
                    "source_url": span.get("source_url"),
                    "reviewed_at": span.get("reviewed_at"),
                    "adjacent_context": deepcopy(span.get("adjacent_context")) if adjacent else None,
                }
            )
        return {"spans": rows}, [{"knowledge_snapshot_id": self.knowledge_snapshot_id}]


def deterministic_verify_answer(
    answer: Mapping[str, Any],
    *,
    allowed_record_ids: set[str],
    allowed_evidence_ids: set[str],
    allowed_instruction_ids: set[str],
    evidence_coverage: str,
    medical_answer_required: bool,
) -> dict[str, Any]:
    """Apply the non-LLM portion of the A5 hard gate."""

    failure_codes: list[str] = []
    failing_claim_ids: list[str] = []
    rewrite_constraints: list[str] = []
    required_fields = {
        "answer_mode",
        "short_answer",
        "safe_actions",
        "observe",
        "contact_guidance",
        "questions_for_clinician",
        "limitations",
        "claims",
    }
    if not isinstance(answer, Mapping) or not required_fields.issubset(answer):
        return {
            "decision": "block",
            "failure_codes": ["SCHEMA_INVALID"],
            "failing_claim_ids": [],
            "rewrite_constraints": [],
            "safe_output_template": "APPROVED_ABSTENTION_TEMPLATE",
        }
    if answer.get("answer_mode") not in {"grounded", "partial", "abstain"}:
        failure_codes.append("SCHEMA_INVALID")
    for field in (
        "short_answer",
        "safe_actions",
        "observe",
        "contact_guidance",
        "questions_for_clinician",
        "limitations",
    ):
        value = answer.get(field)
        if field == "short_answer":
            if not isinstance(value, str):
                failure_codes.append("SCHEMA_INVALID")
        elif not isinstance(value, list) or any(not isinstance(item, str) for item in value):
            failure_codes.append("SCHEMA_INVALID")
    claims = answer.get("claims")
    if not isinstance(claims, list):
        claims = []
        failure_codes.append("SCHEMA_INVALID")
    text_parts = [str(answer.get("short_answer", ""))]
    for field in ("safe_actions", "observe", "contact_guidance"):
        value = answer.get(field)
        if isinstance(value, list):
            text_parts.extend(str(item) for item in value)
    text_parts.extend(
        str(claim.get("text", "")) for claim in claims if isinstance(claim, Mapping)
    )
    all_text = " ".join(text_parts)
    if any(pattern.search(all_text) for pattern in _PROHIBITED_ACTION_PATTERNS):
        failure_codes.append("PROHIBITED_MEDICAL_ACTION")
    has_medical_claim = False
    seen_claim_ids: set[str] = set()
    for index, claim in enumerate(claims):
        fallback_id = f"claim_{index + 1}"
        if not isinstance(claim, Mapping):
            failure_codes.append("SCHEMA_INVALID")
            failing_claim_ids.append(fallback_id)
            continue
        claim_id = claim.get("claim_id")
        if not isinstance(claim_id, str) or not claim_id or claim_id in seen_claim_ids:
            failure_codes.append("SCHEMA_INVALID")
            failing_claim_ids.append(str(claim_id or fallback_id))
            continue
        seen_claim_ids.add(claim_id)
        claim_type = claim.get("claim_type")
        evidence_ids = set(claim.get("evidence_span_ids", [])) if isinstance(claim.get("evidence_span_ids"), list) else set()
        record_ids = set(claim.get("care_entry_ids", [])) if isinstance(claim.get("care_entry_ids"), list) else set()
        instruction_ids = set(claim.get("clinician_instruction_ids", [])) if isinstance(claim.get("clinician_instruction_ids"), list) else set()
        if claim_type == "medical":
            has_medical_claim = True
            if (
                not evidence_ids.issubset(allowed_evidence_ids)
                or not instruction_ids.issubset(allowed_instruction_ids)
                or not (evidence_ids or instruction_ids)
            ):
                failure_codes.append("UNSUPPORTED_CLAIM")
                failing_claim_ids.append(claim_id)
                rewrite_constraints.append(
                    f"{claim_id}을 제거하거나 직접 지지하는 승인 근거 ID에만 연결"
                )
        elif claim_type == "record_summary":
            if not record_ids or not record_ids.issubset(allowed_record_ids):
                failure_codes.append("CONTEXT_DISTORTION")
                failing_claim_ids.append(claim_id)
        else:
            failure_codes.append("SCHEMA_INVALID")
            failing_claim_ids.append(claim_id)
    if medical_answer_required and evidence_coverage in {"none", "conflict"}:
        if has_medical_claim:
            failure_codes.append(
                "EVIDENCE_CONFLICT" if evidence_coverage == "conflict" else "UNSUPPORTED_CLAIM"
            )
        elif evidence_coverage == "conflict":
            failure_codes.append("EVIDENCE_CONFLICT")
        else:
            failure_codes.append("EVIDENCE_NOT_FOUND")
    failure_codes = list(dict.fromkeys(failure_codes))
    failing_claim_ids = list(dict.fromkeys(failing_claim_ids))
    rewrite_constraints = list(dict.fromkeys(rewrite_constraints))
    if "PROHIBITED_MEDICAL_ACTION" in failure_codes or "SCHEMA_INVALID" in failure_codes:
        decision = "block"
    elif "CONTEXT_DISTORTION" in failure_codes:
        decision = "block"
    elif medical_answer_required and any(
        code in failure_codes for code in ("EVIDENCE_NOT_FOUND", "EVIDENCE_CONFLICT")
    ) and not has_medical_claim:
        decision = "abstain"
    elif failure_codes:
        decision = "rewrite_once"
    else:
        decision = "pass"
    return {
        "decision": decision,
        "failure_codes": failure_codes,
        "failing_claim_ids": failing_claim_ids,
        "rewrite_constraints": rewrite_constraints,
        "safe_output_template": (
            "APPROVED_ABSTENTION_TEMPLATE" if decision in {"abstain", "block"} else None
        ),
    }


__all__ = [
    "CONTRACT_VERSION",
    "DeterministicToolHost",
    "HostContractError",
    "InMemoryPilotRepository",
    "ROLE_TOOLS",
    "TRACE_SCHEMA_VERSION",
    "TraceRecorder",
    "deterministic_verify_answer",
    "redact_trace_payload",
    "verify_trace_chain",
]
