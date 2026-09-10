"""Deterministic record/evidence projection and semantic checks."""
from __future__ import annotations

import json
from typing import Any, Mapping, Sequence



def _tool_results_of(
    results: Sequence[Mapping[str, Any]], tool_name: str
) -> list[Mapping[str, Any]]:
    return [result for result in results if result.get("tool_name") == tool_name]

def _detail_rows(results: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for result in _tool_results_of(results, "get_care_entry_details"):
        if result.get("status") == "ok":
            values = result.get("result", {}).get("entries", [])
            if isinstance(values, list):
                rows.extend(dict(value) for value in values if isinstance(value, Mapping))
    return rows

def _instruction_rows(results: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for result in _tool_results_of(results, "get_active_clinician_instructions"):
        if result.get("status") in {"ok", "empty"}:
            values = result.get("result", {}).get("instructions", [])
            if isinstance(values, list):
                rows.extend(dict(value) for value in values if isinstance(value, Mapping))
    return rows

def _opened_spans(results: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for result in _tool_results_of(results, "open_evidence_spans"):
        if result.get("status") == "ok":
            values = result.get("result", {}).get("spans", [])
            if isinstance(values, list):
                rows.extend(dict(value) for value in values if isinstance(value, Mapping))
    return rows

def _deterministic_record_pack(
    detail_rows: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    """Project confirmed rows into A2 without generative paraphrase."""

    relevant_records: list[dict[str, Any]] = []
    for row in detail_rows:
        facts = row.get("structured_facts", {})
        facts = facts if isinstance(facts, Mapping) else {}
        status = facts.get("intake_status")
        polarity = (
            "positive"
            if status == "taken"
            else "unknown"
            if status == "unknown"
            else "negative"
            if status is not None
            else "unknown"
        )
        medication_name = facts.get("medication_display_name")
        if isinstance(medication_name, str) and medication_name:
            fact = f"{medication_name}: {status if status is not None else 'unknown'}"
        else:
            fact = json.dumps(
                dict(facts), ensure_ascii=False, sort_keys=True, separators=(",", ":")
            )
            if not fact or fact == "{}":
                fact = str(row.get("entry_type") or "confirmed_record")
        value: Any = facts.get("value")
        if isinstance(value, (dict, list, bool)):
            value = None
        unit = facts.get("unit")
        if not isinstance(unit, str):
            unit = None
        relevant_records.append(
            {
                "care_entry_id": str(row.get("care_entry_id")),
                "entry_version": int(row.get("entry_version")),
                "occurred_at": str(row.get("occurred_at")),
                "fact_type": str(row.get("entry_type")),
                "fact": fact,
                "polarity": polarity,
                "value": value,
                "unit": unit,
                "certainty": "confirmed",
            }
        )
    return {
        "status": "complete" if relevant_records else "no_relevant_record",
        "relevant_records": relevant_records,
        "observed_changes": [],
        "missing_context": [],
        "source_record_ids": [row["care_entry_id"] for row in relevant_records],
    }

def _deterministic_evidence_pack(
    *,
    question: Any,
    knowledge_snapshot_id: str | None,
    opened_spans: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    """Build a conservative A3 pack; absence or ambiguity can never become coverage."""

    selected: list[dict[str, Any]] = []
    for row in opened_spans:
        span_id = row.get("evidence_span_id")
        if isinstance(span_id, str) and span_id:
            selected.append(
                {
                    "evidence_span_id": span_id,
                    "supports": [str(question)] if question else [],
                    "limitations": [
                        "Deterministic selection confirms availability, not clinical applicability."
                    ],
                }
            )
    if knowledge_snapshot_id is None or not selected:
        return {
            "status": "no_evidence",
            "knowledge_snapshot_id": knowledge_snapshot_id,
            "coverage": "none",
            "selected_evidence": [],
            "uncovered_aspects": [str(question)] if question else [],
            "conflicts": [],
        }
    return {
        "status": "complete",
        "knowledge_snapshot_id": knowledge_snapshot_id,
        "coverage": "partial",
        "selected_evidence": selected,
        "uncovered_aspects": [
            "Clinical applicability requires an approved, reviewed evaluation label."
        ],
        "conflicts": [],
    }

def _a2_semantic_errors(
    record_pack: Mapping[str, Any], detail_rows: Sequence[Mapping[str, Any]]
) -> list[str]:
    allowed = {str(row.get("care_entry_id")): row for row in detail_rows}
    records = record_pack.get("relevant_records", [])
    source_ids = record_pack.get("source_record_ids", [])
    if not isinstance(records, list) or not isinstance(source_ids, list):
        return ["CONTEXT_DISTORTION"]
    record_ids = [str(record.get("care_entry_id")) for record in records]
    source_id_set = set(str(value) for value in source_ids)
    allowed_id_set = set(allowed)
    if (
        len(record_ids) != len(set(record_ids))
        or len(source_ids) != len(source_id_set)
        or set(record_ids) != source_id_set
    ):
        return ["CONTEXT_DISTORTION"]
    errors: list[str] = []
    if set(record_ids) != allowed_id_set:
        errors.append("CONTEXT_DISTORTION")
    for record in records:
        record_id = str(record.get("care_entry_id"))
        source = allowed.get(record_id)
        if source is None:
            errors.append("CONTEXT_DISTORTION")
            continue
        for output_field, source_field in (
            ("entry_version", "entry_version"),
            ("occurred_at", "occurred_at"),
            ("fact_type", "entry_type"),
        ):
            if record.get(output_field) != source.get(source_field):
                errors.append("CONTEXT_DISTORTION")
        if record.get("certainty") != "confirmed":
            errors.append("CONTEXT_DISTORTION")
        facts = source.get("structured_facts", {})
        if source.get("entry_type") == "medication_intake" and isinstance(facts, Mapping):
            status = facts.get("intake_status")
            expected_polarity = (
                "positive"
                if status == "taken"
                else "unknown"
                if status == "unknown"
                else "negative"
            )
            if record.get("polarity") != expected_polarity:
                errors.append("CONTEXT_DISTORTION")
            medication_name = facts.get("medication_display_name")
            if isinstance(medication_name, str) and medication_name not in str(record.get("fact", "")):
                errors.append("CONTEXT_DISTORTION")
    status = record_pack.get("status")
    if status == "no_relevant_record" and (records or source_ids or detail_rows):
        errors.append("CONTEXT_DISTORTION")
    if status == "complete" and not records:
        errors.append("CONTEXT_DISTORTION")
    changes = record_pack.get("observed_changes", [])
    if isinstance(changes, list):
        for change in changes:
            linked = change.get("source_record_ids") if isinstance(change, Mapping) else None
            if (
                not isinstance(linked, list)
                or not linked
                or any(not isinstance(value, str) for value in linked)
                or not set(linked).issubset(source_id_set)
            ):
                errors.append("CONTEXT_DISTORTION")
    return list(dict.fromkeys(errors))

def _a3_semantic_errors(
    evidence_pack: Mapping[str, Any],
    *,
    knowledge_snapshot_id: str | None,
    opened_span_ids: set[str],
) -> list[str]:
    errors: list[str] = []
    if evidence_pack.get("knowledge_snapshot_id") != knowledge_snapshot_id:
        errors.append("CITATION_MISMATCH")
    selected = evidence_pack.get("selected_evidence", [])
    selected_ids = {
        str(value.get("evidence_span_id"))
        for value in selected
        if isinstance(value, Mapping)
    }
    if isinstance(selected, list) and len(selected_ids) != len(selected):
        errors.append("CITATION_MISMATCH")
    if not selected_ids.issubset(opened_span_ids):
        errors.append("CITATION_MISMATCH")
    coverage = evidence_pack.get("coverage")
    status = evidence_pack.get("status")
    if knowledge_snapshot_id is None:
        if coverage != "none" or selected_ids:
            errors.append("UNSUPPORTED_CLAIM")
    elif coverage in {"covered", "partial"} and not selected_ids:
        errors.append("EVIDENCE_NOT_FOUND")
    elif coverage in {"none", "conflict"} and selected_ids:
        errors.append("CITATION_MISMATCH")
    if status == "complete" and coverage not in {"covered", "partial"}:
        errors.append("CITATION_MISMATCH")
    elif status == "no_evidence" and (coverage != "none" or selected_ids):
        errors.append("CITATION_MISMATCH")
    elif status == "evidence_conflict" and coverage != "conflict":
        errors.append("CITATION_MISMATCH")
    return list(dict.fromkeys(errors))

def _effective_decision(hard: str, model: str) -> str:
    severity = {"pass": 0, "rewrite_once": 1, "abstain": 2, "block": 3}
    if hard not in severity or model not in severity:
        return "block"
    return hard if severity[hard] >= severity[model] else model

def _safe_abstention_output(
    record_pack: Mapping[str, Any] | None, *, blocked: bool = False
) -> dict[str, Any]:
    records = record_pack.get("relevant_records", []) if isinstance(record_pack, Mapping) else []
    if blocked or not isinstance(records, list) or not records:
        return {
            "answer_mode": "abstain",
            "short_answer": "안전하게 확인할 수 있는 정보가 부족해 답변을 제공하지 않습니다.",
            "safe_actions": [],
            "observe": [],
            "contact_guidance": [],
            "questions_for_clinician": [],
            "limitations": ["확인된 기록과 승인 근거를 다시 확인해 주세요."],
            "claims": [],
        }
    claims: list[dict[str, Any]] = []
    sentences: list[str] = []
    for index, record in enumerate(records, start=1):
        sentence = f"{record.get('occurred_at')}에 {record.get('fact')}으로 확인됩니다."
        sentences.append(sentence)
        claims.append(
            {
                "claim_id": f"CL-SAFE-RECORD-{index:03d}",
                "claim_type": "record_summary",
                "text": sentence,
                "importance": "core",
                "evidence_span_ids": [],
                "care_entry_ids": [record.get("care_entry_id")],
                "clinician_instruction_ids": [],
            }
        )
    return {
        "answer_mode": "partial",
        "short_answer": " ".join(sentences) + " 승인 근거가 없어 의학적 설명은 보류합니다.",
        "safe_actions": [],
        "observe": [],
        "contact_guidance": [],
        "questions_for_clinician": [],
        "limitations": ["환자별 처방과 담당 의료진의 지시가 우선합니다."],
        "claims": claims,
    }

def _citations(
    evidence_pack: Mapping[str, Any], opened: Sequence[Mapping[str, Any]]
) -> list[dict[str, Any]]:
    selected = {
        str(value.get("evidence_span_id"))
        for value in evidence_pack.get("selected_evidence", [])
        if isinstance(value, Mapping)
    }
    rows: list[dict[str, Any]] = []
    for span in opened:
        span_id = str(span.get("evidence_span_id"))
        if span_id not in selected:
            continue
        rows.append(
            {
                "evidence_span_id": span_id,
                "title": span.get("title"),
                "publisher": span.get("publisher"),
                "revision_date": span.get("revision_date"),
                "page_or_section": span.get("page_or_section"),
                "evidence_text": span.get("text"),
                "source_url": span.get("source_url"),
                "reviewed_at": span.get("reviewed_at"),
            }
        )
    return rows
