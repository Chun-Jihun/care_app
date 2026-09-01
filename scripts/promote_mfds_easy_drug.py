#!/usr/bin/env python3
"""Prepare and validate MFDS e약은요 staged -> approved promotion.

This offline tool deliberately separates three operations:

1. create a compact catalog from a technically validated staged snapshot;
2. prepare an immutable packet for a human clinical and rights review;
3. promote only explicitly approved evidence spans into an inactive approved
   snapshot.

The tool cannot verify that a reviewer is a real clinician. It only enforces a
complete, auditable decision record. Promotion never activates a runtime RAG
index and never creates a mobile bundle.
"""

from __future__ import annotations

import argparse
from datetime import date, datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
from typing import Any, Iterable, Mapping, Sequence


SCRIPT_VERSION = "0.1.0"
SCHEMA_VERSION = "1.0"
CLINICAL_ATTESTATION = (
    "I_REVIEWED_EACH_APPROVED_SPAN_AGAINST_THE_SOURCE_AND_CONFIRMED_ITS_ALLOWED_USE"
)
AUTHORIZED_CLINICAL_ROLES = {"pharmacist", "physician"}
ALLOWED_USES_BY_SECTION = {
    "effectiveness": {"general_drug_purpose_explanation"},
    "usage": {"label_usage_reference"},
    "warnings": {"warning_explanation"},
    "precautions": {"precaution_explanation"},
    "interactions": {"interaction_reference"},
    "adverse_reactions": {"adverse_reaction_explanation"},
    "storage": {"storage_explanation"},
}
HIGH_RISK_SECTIONS = {
    "usage",
    "warnings",
    "precautions",
    "interactions",
    "adverse_reactions",
}
SAFE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")


class ApprovalError(RuntimeError):
    """Raised when review preparation or approval promotion is unsafe."""


def _json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def _jsonl_bytes(values: Iterable[Mapping[str, Any]]) -> bytes:
    return b"".join(
        (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode(
            "utf-8"
        )
        for value in values
    )


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except FileNotFoundError as exc:
        raise ApprovalError(f"필수 파일을 찾을 수 없습니다: {path}") from exc
    return digest.hexdigest()


def _load_json(path: Path, description: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError as exc:
        raise ApprovalError(f"{description}을 찾을 수 없습니다: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ApprovalError(f"{description} JSON이 잘못되었습니다: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ApprovalError(f"{description} 최상위 값은 JSON object여야 합니다.")
    return value


def _load_jsonl(path: Path, description: str) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as stream:
            for line_number, line in enumerate(stream, 1):
                if not line.strip():
                    raise ApprovalError(
                        f"{description}에 빈 행이 있습니다: {path}:{line_number}"
                    )
                try:
                    value = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise ApprovalError(
                        f"{description} JSONL이 잘못되었습니다: {path}:{line_number}: {exc}"
                    ) from exc
                if not isinstance(value, dict):
                    raise ApprovalError(
                        f"{description} 행은 JSON object여야 합니다: {path}:{line_number}"
                    )
                values.append(value)
    except FileNotFoundError as exc:
        raise ApprovalError(f"{description}을 찾을 수 없습니다: {path}") from exc
    return values


def _safe_path(workspace_root: Path, path: Path) -> Path:
    root = workspace_root.resolve()
    resolved = path.resolve()
    if not resolved.is_relative_to(root):
        raise ApprovalError(f"workspace 밖의 경로는 사용할 수 없습니다: {path}")
    return resolved


def _relative_path(workspace_root: Path, path: Path) -> str:
    return _safe_path(workspace_root, path).relative_to(workspace_root.resolve()).as_posix()


def _safe_identifier(value: str, name: str) -> str:
    if not isinstance(value, str) or not SAFE_ID.fullmatch(value):
        raise ApprovalError(
            f"{name}은 영문자·숫자로 시작하고 영문자·숫자·점·밑줄·하이픈만 "
            "사용해야 합니다."
        )
    return value


def _nonempty_string(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ApprovalError(f"{name}이 비어 있습니다.")
    return value.strip()


def _iso_date(value: Any, name: str) -> str:
    text = _nonempty_string(value, name)
    try:
        if "T" in text:
            datetime.fromisoformat(text.replace("Z", "+00:00"))
        else:
            date.fromisoformat(text)
    except ValueError as exc:
        raise ApprovalError(f"{name}은 ISO 8601 날짜 또는 시각이어야 합니다: {text}") from exc
    return text


def _output_metadata(
    filename: str, content: bytes, record_count: int | None = None
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "file": filename,
        "bytes": len(content),
        "sha256": _sha256_bytes(content),
    }
    if record_count is not None:
        result["record_count"] = record_count
    return result


def _declared_output(manifest: Mapping[str, Any], filename: str) -> dict[str, Any]:
    outputs = manifest.get("outputs")
    if not isinstance(outputs, list):
        raise ApprovalError("manifest outputs 형식이 잘못되었습니다.")
    matches = [entry for entry in outputs if isinstance(entry, dict) and entry.get("file") == filename]
    if len(matches) != 1:
        raise ApprovalError(f"manifest에서 {filename} 출력 선언을 정확히 하나 찾을 수 없습니다.")
    return matches[0]


def _verify_declared_file(
    base_dir: Path, manifest: Mapping[str, Any], filename: str
) -> Path:
    declaration = _declared_output(manifest, filename)
    path = base_dir / filename
    try:
        size = path.stat().st_size
    except FileNotFoundError as exc:
        raise ApprovalError(f"선언된 파일을 찾을 수 없습니다: {path}") from exc
    if size != declaration.get("bytes"):
        raise ApprovalError(f"{filename} 바이트 크기가 manifest와 다릅니다.")
    actual_hash = _sha256_file(path)
    if actual_hash != declaration.get("sha256"):
        raise ApprovalError(f"{filename} SHA-256 해시가 manifest와 다릅니다.")
    return path


def _validate_record_count(
    values: Sequence[Mapping[str, Any]], declaration: Mapping[str, Any], filename: str
) -> None:
    if declaration.get("record_count") != len(values):
        raise ApprovalError(f"{filename} 레코드 수가 manifest와 다릅니다.")


def _validate_product_and_spans(
    products: Sequence[Mapping[str, Any]], spans: Sequence[Mapping[str, Any]]
) -> None:
    product_ids: set[str] = set()
    item_seqs: set[str] = set()
    declared_span_ids: list[str] = []
    product_sections: dict[str, Mapping[str, Any]] = {}
    for product in products:
        product_id = _nonempty_string(product.get("product_id"), "product_id")
        item_seq = _nonempty_string(product.get("item_seq"), "item_seq")
        if product_id in product_ids or item_seq in item_seqs:
            raise ApprovalError("staged product_id 또는 item_seq가 중복됩니다.")
        if product.get("review_status") != "unreviewed" or product.get(
            "runtime_rag_eligible"
        ) is not False:
            raise ApprovalError("staged product가 unreviewed/비활성 상태가 아닙니다.")
        sections = product.get("sections")
        if not isinstance(sections, dict):
            raise ApprovalError(f"product sections 형식이 잘못되었습니다: {product_id}")
        for section_name, section in sections.items():
            if section_name not in ALLOWED_USES_BY_SECTION or not isinstance(section, dict):
                raise ApprovalError(f"알 수 없는 staged section입니다: {section_name}")
            section_span_ids = section.get("span_ids")
            if not isinstance(section_span_ids, list) or not all(
                isinstance(value, str) and value for value in section_span_ids
            ):
                raise ApprovalError(f"section span_ids 형식이 잘못되었습니다: {product_id}")
            declared_span_ids.extend(section_span_ids)
        product_ids.add(product_id)
        item_seqs.add(item_seq)
        product_sections[product_id] = sections

    if len(declared_span_ids) != len(set(declared_span_ids)):
        raise ApprovalError("product section에서 같은 span ID를 두 번 참조합니다.")
    actual_span_ids: set[str] = set()
    for span in spans:
        span_id = _nonempty_string(span.get("span_id"), "span_id")
        product_id = _nonempty_string(span.get("product_id"), "span product_id")
        if span_id in actual_span_ids:
            raise ApprovalError("evidence span_id가 중복됩니다.")
        if product_id not in product_ids:
            raise ApprovalError(f"근거 span의 product가 없습니다: {span_id}")
        if span.get("review_status") != "unreviewed" or span.get(
            "runtime_rag_eligible"
        ) is not False:
            raise ApprovalError("staged span이 unreviewed/비활성 상태가 아닙니다.")
        section_name = span.get("section")
        section = product_sections[product_id].get(section_name)
        if not isinstance(section, dict) or span_id not in section.get("span_ids", []):
            raise ApprovalError(f"근거 span과 product section 연결이 잘못되었습니다: {span_id}")
        text = span.get("text")
        if not isinstance(text, str) or not text:
            raise ApprovalError(f"근거 span 원문이 비어 있습니다: {span_id}")
        if hashlib.sha256(text.encode("utf-8")).hexdigest() != span.get("text_sha256"):
            raise ApprovalError(f"근거 span 원문 SHA-256이 다릅니다: {span_id}")
        normalized = section.get("normalized_text")
        start = span.get("normalized_start")
        end = span.get("normalized_end")
        if (
            not isinstance(normalized, str)
            or not isinstance(start, int)
            or not isinstance(end, int)
            or start < 0
            or end < start
            or normalized[start:end] != text
        ):
            raise ApprovalError(f"근거 span offset이 정규화 원문과 다릅니다: {span_id}")
        if not isinstance(span.get("source_refs"), list) or not span["source_refs"]:
            raise ApprovalError(f"근거 span의 raw source reference가 없습니다: {span_id}")
        actual_span_ids.add(span_id)
    if set(declared_span_ids) != actual_span_ids:
        raise ApprovalError("product section과 evidence span의 ID 집합이 다릅니다.")


def _verify_staged_snapshot(staged_dir: Path) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]], str]:
    manifest_path = staged_dir / "manifest.json"
    manifest = _load_json(manifest_path, "staged manifest")
    if manifest.get("approval_state") != "staged_unreviewed":
        raise ApprovalError("입력은 staged_unreviewed 상태여야 합니다.")
    if manifest.get("runtime_rag_eligible") is not False:
        raise ApprovalError("staged 입력은 runtime RAG 비활성 상태여야 합니다.")
    technical = manifest.get("technical_validation")
    if not isinstance(technical, dict) or technical.get("completed") is not True or technical.get("passed") is not True:
        raise ApprovalError("staged 입력의 기술 검증이 완료·통과 상태가 아닙니다.")
    clinical = manifest.get("clinical_review")
    if not isinstance(clinical, dict) or clinical.get("completed") is not False:
        raise ApprovalError("staged 입력에 임상 승인 상태가 섞여 있습니다.")
    usage = manifest.get("usage")
    if not isinstance(usage, dict) or usage.get("runtime_rag_eligible") is not False:
        raise ApprovalError("staged usage의 runtime RAG 상태가 잘못되었습니다.")

    products_path = _verify_declared_file(staged_dir, manifest, "products.jsonl")
    spans_path = _verify_declared_file(staged_dir, manifest, "evidence_spans.jsonl")
    _verify_declared_file(staged_dir, manifest, "quality_report.json")
    products = _load_jsonl(products_path, "staged products")
    spans = _load_jsonl(spans_path, "staged evidence spans")
    _validate_record_count(products, _declared_output(manifest, "products.jsonl"), "products.jsonl")
    _validate_record_count(spans, _declared_output(manifest, "evidence_spans.jsonl"), "evidence_spans.jsonl")
    _validate_product_and_spans(products, spans)
    return manifest, products, spans, _sha256_file(manifest_path)


def _write_atomic_directory(output_dir: Path, files: Mapping[str, bytes]) -> None:
    if output_dir.exists():
        raise ApprovalError(f"기존 출력을 덮어쓸 수 없습니다: {output_dir}")
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output_dir.name}.", dir=output_dir.parent))
    try:
        for filename, content in files.items():
            if Path(filename).name != filename:
                raise ApprovalError(f"안전하지 않은 출력 파일명입니다: {filename}")
            with (temporary / filename).open("xb") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
        if output_dir.exists():
            raise ApprovalError(f"기존 출력을 덮어쓸 수 없습니다: {output_dir}")
        temporary.rename(output_dir)
    except Exception:
        if temporary.exists():
            shutil.rmtree(temporary)
        raise


def _catalog_row(product: Mapping[str, Any]) -> dict[str, Any]:
    sections = product["sections"]
    section_counts = {
        name: len(section["span_ids"]) for name, section in sections.items()
    }
    return {
        "schema_version": SCHEMA_VERSION,
        "product_id": product["product_id"],
        "item_seq": product["item_seq"],
        "product_name": product.get("product_name"),
        "manufacturer_name": product.get("manufacturer_name"),
        "disclosed_at": product.get("disclosed_at"),
        "updated_at": product.get("updated_at"),
        "section_span_counts": section_counts,
        "missing_sections": [name for name, count in section_counts.items() if count == 0],
        "span_count": sum(section_counts.values()),
        "raw_source_reference_count": len(product.get("source_refs") or []),
        "review_status": "unreviewed",
        "runtime_rag_eligible": False,
    }


def create_review_catalog(
    workspace_root: Path, staged_dir: Path, output_dir: Path
) -> Path:
    """Create an unapproved, compact product-selection catalog."""

    root = workspace_root.resolve()
    staged = _safe_path(root, staged_dir)
    output = _safe_path(root, output_dir)
    if output.exists():
        raise ApprovalError(f"기존 출력을 덮어쓸 수 없습니다: {output}")
    manifest, products, spans, stage_manifest_hash = _verify_staged_snapshot(staged)
    rows = [_catalog_row(product) for product in products]
    catalog_bytes = _jsonl_bytes(rows)
    selection_template = {
        "schema_version": SCHEMA_VERSION,
        "source_stage_id": manifest.get("stage_id"),
        "source_stage_manifest_sha256": stage_manifest_hash,
        "selection_purpose": None,
        "selected_by": None,
        "selected_at": None,
        "item_seqs": [],
        "warning": "선정은 승인이 아니며, 별도의 권리 및 임상 검수가 필요합니다.",
    }
    selection_bytes = _json_bytes(selection_template)
    catalog_manifest = {
        "schema_version": SCHEMA_VERSION,
        "catalog_id": f"{manifest.get('stage_id')}-review-catalog-v1",
        "approval_state": "awaiting_selection",
        "runtime_rag_eligible": False,
        "input": {
            "stage_id": manifest.get("stage_id"),
            "staged_local_path": _relative_path(root, staged),
            "staged_manifest_sha256": stage_manifest_hash,
        },
        "summary": {
            "product_count": len(products),
            "evidence_span_count": len(spans),
        },
        "usage": {
            "do_not_train": True,
            "mobile_bundle": False,
            "runtime_rag_eligible": False,
            "allowed": ["clinical_review_selection"],
        },
        "outputs": [
            _output_metadata("review_catalog.jsonl", catalog_bytes, len(rows)),
            _output_metadata("selection.template.json", selection_bytes),
        ],
    }
    _write_atomic_directory(
        output,
        {
            "review_catalog.jsonl": catalog_bytes,
            "selection.template.json": selection_bytes,
            "manifest.json": _json_bytes(catalog_manifest),
        },
    )
    return output


def _load_selection(
    path: Path, stage_id: str, stage_manifest_hash: str
) -> list[str]:
    selection = _load_json(path, "review selection")
    selected_stage_id = selection.get("source_stage_id")
    if selected_stage_id is not None and selected_stage_id != stage_id:
        raise ApprovalError("selection의 source_stage_id가 staged 입력과 다릅니다.")
    selected_hash = selection.get("source_stage_manifest_sha256")
    if selected_hash is not None and selected_hash != stage_manifest_hash:
        raise ApprovalError("selection의 staged manifest SHA-256이 입력과 다릅니다.")
    item_seqs = selection.get("item_seqs")
    if not isinstance(item_seqs, list) or not item_seqs:
        raise ApprovalError("검수할 item_seqs를 하나 이상 선택해야 합니다.")
    if not all(isinstance(item, str) and item for item in item_seqs):
        raise ApprovalError("selection item_seqs 형식이 잘못되었습니다.")
    if len(item_seqs) != len(set(item_seqs)):
        raise ApprovalError("selection에 중복 item_seq가 있습니다.")
    return item_seqs


def prepare_review_packet(
    workspace_root: Path,
    staged_dir: Path,
    selection_file: Path,
    output_dir: Path,
    review_id: str,
) -> Path:
    """Seal selected staged rows into a packet and emit pending decisions."""

    root = workspace_root.resolve()
    staged = _safe_path(root, staged_dir)
    selection_path = _safe_path(root, selection_file)
    output = _safe_path(root, output_dir)
    review_id = _safe_identifier(review_id, "review-id")
    if output.exists():
        raise ApprovalError(f"기존 출력을 덮어쓸 수 없습니다: {output}")
    manifest, products, spans, stage_manifest_hash = _verify_staged_snapshot(staged)
    item_seqs = _load_selection(
        selection_path, _nonempty_string(manifest.get("stage_id"), "stage_id"), stage_manifest_hash
    )
    product_by_item = {str(product["item_seq"]): product for product in products}
    missing = [item_seq for item_seq in item_seqs if item_seq not in product_by_item]
    if missing:
        raise ApprovalError("staged 입력에 없는 item_seq가 선택되었습니다: " + ", ".join(missing))
    selected_products = [product_by_item[item_seq] for item_seq in item_seqs]
    selected_product_ids = {str(product["product_id"]) for product in selected_products}
    selected_spans = [span for span in spans if str(span["product_id"]) in selected_product_ids]
    _validate_product_and_spans(selected_products, selected_spans)

    products_bytes = _jsonl_bytes(selected_products)
    spans_bytes = _jsonl_bytes(selected_spans)
    packet_manifest = {
        "schema_version": SCHEMA_VERSION,
        "review_packet_id": review_id,
        "approval_state": "awaiting_clinical_review",
        "runtime_rag_eligible": False,
        "source": manifest.get("source"),
        "input": {
            "stage_id": manifest.get("stage_id"),
            "staged_local_path": _relative_path(root, staged),
            "staged_manifest_sha256": stage_manifest_hash,
            "selection_file_sha256": _sha256_file(selection_path),
        },
        "summary": {
            "selected_product_count": len(selected_products),
            "selected_span_count": len(selected_spans),
        },
        "usage": {
            "do_not_train": True,
            "mobile_bundle": False,
            "runtime_rag_eligible": False,
            "allowed": ["rights_review", "clinical_review"],
        },
        "outputs": [
            _output_metadata("products.jsonl", products_bytes, len(selected_products)),
            _output_metadata("evidence_spans.jsonl", spans_bytes, len(selected_spans)),
        ],
    }
    packet_manifest_bytes = _json_bytes(packet_manifest)
    spans_by_product: dict[str, list[Mapping[str, Any]]] = {}
    for span in selected_spans:
        spans_by_product.setdefault(str(span["product_id"]), []).append(span)
    decisions_template = {
        "schema_version": SCHEMA_VERSION,
        "review_packet_id": review_id,
        "review_packet_manifest_sha256": _sha256_bytes(packet_manifest_bytes),
        "reviewer": {
            "reviewer_id": None,
            "roles": [],
            "organization": None,
            "credential_verification": {
                "verified": False,
                "verified_by": None,
                "verified_at": None,
            },
        },
        "reviewed_at": None,
        "next_review_due": None,
        "attestation": None,
        "required_attestation": CLINICAL_ATTESTATION,
        "rights_review": {
            "completed": False,
            "decision": "pending",
            "reviewer_id": None,
            "reviewed_at": None,
            "license_basis": None,
            "evidence_url": None,
        },
        "product_reviews": [
            {
                "product_id": product["product_id"],
                "item_seq": product["item_seq"],
                "product_name": product.get("product_name"),
                "identity_confirmed": None,
                "span_reviews": [
                    {
                        "span_id": span["span_id"],
                        "section": span["section"],
                        "location": span["location"],
                        "decision": "pending",
                        "allowed_uses": [],
                        "allowed_use_options": sorted(
                            ALLOWED_USES_BY_SECTION[str(span["section"])]
                        ),
                        "note": None,
                    }
                    for span in spans_by_product.get(str(product["product_id"]), [])
                ],
            }
            for product in selected_products
        ],
    }
    _write_atomic_directory(
        output,
        {
            "products.jsonl": products_bytes,
            "evidence_spans.jsonl": spans_bytes,
            "manifest.json": packet_manifest_bytes,
            "review_decisions.template.json": _json_bytes(decisions_template),
        },
    )
    return output


def _verify_review_packet(
    packet_dir: Path,
) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]], str]:
    manifest_path = packet_dir / "manifest.json"
    manifest = _load_json(manifest_path, "review packet manifest")
    if manifest.get("approval_state") != "awaiting_clinical_review":
        raise ApprovalError("입력 review packet이 임상 검수 대기 상태가 아닙니다.")
    if manifest.get("runtime_rag_eligible") is not False:
        raise ApprovalError("review packet은 runtime RAG 비활성 상태여야 합니다.")
    products_path = _verify_declared_file(packet_dir, manifest, "products.jsonl")
    spans_path = _verify_declared_file(packet_dir, manifest, "evidence_spans.jsonl")
    products = _load_jsonl(products_path, "review packet products")
    spans = _load_jsonl(spans_path, "review packet evidence spans")
    _validate_record_count(products, _declared_output(manifest, "products.jsonl"), "products.jsonl")
    _validate_record_count(spans, _declared_output(manifest, "evidence_spans.jsonl"), "evidence_spans.jsonl")
    _validate_product_and_spans(products, spans)
    return manifest, products, spans, _sha256_file(manifest_path)


def _validate_reviewer(decisions: Mapping[str, Any]) -> tuple[str, list[str], str, str, str]:
    reviewer = decisions.get("reviewer")
    if not isinstance(reviewer, dict):
        raise ApprovalError("임상 검수자 정보가 없습니다.")
    reviewer_id = _nonempty_string(reviewer.get("reviewer_id"), "reviewer_id")
    roles = reviewer.get("roles")
    if not isinstance(roles, list) or not all(isinstance(role, str) and role for role in roles):
        raise ApprovalError("검수 역할(roles) 형식이 잘못되었습니다.")
    if not AUTHORIZED_CLINICAL_ROLES.intersection(roles):
        raise ApprovalError("임상 검수 역할에는 pharmacist 또는 physician이 필요합니다.")
    organization = _nonempty_string(reviewer.get("organization"), "reviewer organization")
    verification = reviewer.get("credential_verification")
    if not isinstance(verification, dict) or verification.get("verified") is not True:
        raise ApprovalError("임상 검수자 자격 확인 기록이 완료되지 않았습니다.")
    _nonempty_string(verification.get("verified_by"), "credential verified_by")
    _iso_date(verification.get("verified_at"), "credential verified_at")
    reviewed_at = _iso_date(decisions.get("reviewed_at"), "reviewed_at")
    next_review_due = _iso_date(decisions.get("next_review_due"), "next_review_due")
    if date.fromisoformat(next_review_due[:10]) < date.fromisoformat(reviewed_at[:10]):
        raise ApprovalError("next_review_due는 reviewed_at보다 빠를 수 없습니다.")
    if decisions.get("attestation") != CLINICAL_ATTESTATION:
        raise ApprovalError("필수 임상 검수 attestation이 일치하지 않습니다.")
    return reviewer_id, list(roles), organization, reviewed_at, next_review_due


def _validate_rights_review(decisions: Mapping[str, Any]) -> dict[str, Any]:
    rights = decisions.get("rights_review")
    if not isinstance(rights, dict) or rights.get("completed") is not True:
        raise ApprovalError("이용권리 검토가 완료되지 않았습니다.")
    if rights.get("decision") != "approved":
        raise ApprovalError("이용권리 검토가 approved 상태가 아닙니다.")
    return {
        "completed": True,
        "decision": "approved",
        "reviewer_id": _nonempty_string(rights.get("reviewer_id"), "권리 검수자 ID"),
        "reviewed_at": _iso_date(rights.get("reviewed_at"), "권리 검수일"),
        "license_basis": _nonempty_string(rights.get("license_basis"), "이용권리 근거"),
        "evidence_url": _nonempty_string(rights.get("evidence_url"), "이용권리 증빙 URL"),
    }


def _validated_span_decisions(
    decisions: Mapping[str, Any],
    products: Sequence[Mapping[str, Any]],
    spans: Sequence[Mapping[str, Any]],
) -> dict[str, dict[str, Any]]:
    product_reviews = decisions.get("product_reviews")
    if not isinstance(product_reviews, list):
        raise ApprovalError("product_reviews 형식이 잘못되었습니다.")
    product_by_id = {str(product["product_id"]): product for product in products}
    span_by_id = {str(span["span_id"]): span for span in spans}
    reviewed_product_ids: set[str] = set()
    reviewed_span_ids: set[str] = set()
    result: dict[str, dict[str, Any]] = {}
    for product_review in product_reviews:
        if not isinstance(product_review, dict):
            raise ApprovalError("product review는 JSON object여야 합니다.")
        product_id = _nonempty_string(product_review.get("product_id"), "review product_id")
        if product_id not in product_by_id or product_id in reviewed_product_ids:
            raise ApprovalError(f"알 수 없거나 중복된 review product_id입니다: {product_id}")
        identity_confirmed = product_review.get("identity_confirmed")
        if not isinstance(identity_confirmed, bool):
            raise ApprovalError(f"제품 식별 확인이 미결정입니다: {product_id}")
        span_reviews = product_review.get("span_reviews")
        if not isinstance(span_reviews, list):
            raise ApprovalError(f"span_reviews 형식이 잘못되었습니다: {product_id}")
        for span_review in span_reviews:
            if not isinstance(span_review, dict):
                raise ApprovalError("span review는 JSON object여야 합니다.")
            span_id = _nonempty_string(span_review.get("span_id"), "review span_id")
            span = span_by_id.get(span_id)
            if span is None or span_id in reviewed_span_ids or span.get("product_id") != product_id:
                raise ApprovalError(f"알 수 없거나 중복·오연결된 review span_id입니다: {span_id}")
            decision = span_review.get("decision")
            if decision not in {"approved", "rejected"}:
                raise ApprovalError(f"미결정(pending) 또는 잘못된 span decision입니다: {span_id}")
            allowed_uses = span_review.get("allowed_uses")
            if not isinstance(allowed_uses, list) or not all(
                isinstance(value, str) and value for value in allowed_uses
            ):
                raise ApprovalError(f"allowed_uses 형식이 잘못되었습니다: {span_id}")
            section = str(span["section"])
            if decision == "approved":
                if identity_confirmed is not True:
                    raise ApprovalError(f"식별 확인되지 않은 제품의 span을 승인할 수 없습니다: {span_id}")
                if not allowed_uses or not set(allowed_uses).issubset(ALLOWED_USES_BY_SECTION[section]):
                    raise ApprovalError(f"승인 span의 allowed_uses가 비었거나 허용 범위를 벗어났습니다: {span_id}")
            else:
                if allowed_uses:
                    raise ApprovalError(f"거절 span에는 allowed_uses를 둘 수 없습니다: {span_id}")
                _nonempty_string(span_review.get("note"), f"거절 사유 note ({span_id})")
            result[span_id] = {
                "decision": decision,
                "allowed_uses": list(allowed_uses),
                "note": span_review.get("note"),
            }
            reviewed_span_ids.add(span_id)
        reviewed_product_ids.add(product_id)
    if reviewed_product_ids != set(product_by_id):
        raise ApprovalError("review packet의 모든 제품 결정이 포함되지 않았습니다.")
    if reviewed_span_ids != set(span_by_id):
        raise ApprovalError("review packet의 모든 span 결정이 포함되지 않았습니다.")
    return result


def _approved_evidence(
    span: Mapping[str, Any],
    product: Mapping[str, Any],
    span_decision: Mapping[str, Any],
    source: Mapping[str, Any],
    transformer: Mapping[str, Any],
    stage_input: Mapping[str, Any],
    rights: Mapping[str, Any],
    reviewer_id: str,
    reviewer_roles: Sequence[str],
    reviewed_at: str,
    next_review_due: str,
    approval_id: str,
) -> dict[str, Any]:
    section = str(span["section"])
    product_name = _nonempty_string(product.get("product_name"), "product_name")
    published = product.get("updated_at") or product.get("disclosed_at")
    return {
        "schema_version": SCHEMA_VERSION,
        "approval_id": approval_id,
        "span_id": span["span_id"],
        "document_id": span["document_id"],
        "product_id": span["product_id"],
        "item_seq": span["item_seq"],
        "product_name": product_name,
        "manufacturer_name": product.get("manufacturer_name"),
        "section": section,
        "source_field": span["source_field"],
        "source_title": f"식품의약품안전처 의약품개요정보(e약은요): {product_name}",
        "publisher": source.get("provider") or "식품의약품안전처",
        "published_or_revised_at": _nonempty_string(published, "발행일 또는 개정일"),
        "retrieved_at": stage_input.get("download_completed_at"),
        "source_url": _nonempty_string(source.get("catalog_url"), "원문 링크"),
        "location": span["location"],
        "supporting_span": span["text"],
        "source_hash": f"sha256:{span['text_sha256']}",
        "raw_source_refs": span["source_refs"],
        "parser_version": transformer.get("version"),
        "license": rights["license_basis"],
        "license_evidence_url": rights["evidence_url"],
        "clinical_scope": span_decision["allowed_uses"],
        "risk_level": "high" if section in HIGH_RISK_SECTIONS else "standard",
        "review_status": "clinician_approved",
        "reviewed_at": reviewed_at,
        "reviewer_id": reviewer_id,
        "reviewer_roles": list(reviewer_roles),
        "next_review_due": next_review_due,
        "status": "approved_inactive",
        "runtime_rag_eligible": False,
        "revoked": False,
    }


def promote_approved_snapshot(
    workspace_root: Path,
    staged_dir: Path,
    packet_dir: Path,
    decisions_file: Path,
    output_dir: Path,
    approval_id: str,
) -> Path:
    """Promote completed human decisions into an inactive approved snapshot."""

    root = workspace_root.resolve()
    staged = _safe_path(root, staged_dir)
    packet = _safe_path(root, packet_dir)
    decisions_path = _safe_path(root, decisions_file)
    output = _safe_path(root, output_dir)
    approval_id = _safe_identifier(approval_id, "approval-id")
    if output.exists():
        raise ApprovalError(f"기존 출력을 덮어쓸 수 없습니다: {output}")

    stage_manifest, _, _, stage_manifest_hash = _verify_staged_snapshot(staged)
    packet_manifest, products, spans, packet_manifest_hash = _verify_review_packet(packet)
    packet_input = packet_manifest.get("input")
    if not isinstance(packet_input, dict):
        raise ApprovalError("review packet input 형식이 잘못되었습니다.")
    if packet_input.get("stage_id") != stage_manifest.get("stage_id"):
        raise ApprovalError("review packet과 staged 입력의 stage_id가 다릅니다.")
    if packet_input.get("staged_manifest_sha256") != stage_manifest_hash:
        raise ApprovalError("review packet과 staged manifest SHA-256 해시가 다릅니다.")

    decisions = _load_json(decisions_path, "completed review decisions")
    if decisions.get("review_packet_id") != packet_manifest.get("review_packet_id"):
        raise ApprovalError("decision의 review_packet_id가 packet과 다릅니다.")
    if decisions.get("review_packet_manifest_sha256") != packet_manifest_hash:
        raise ApprovalError("decision의 review packet manifest SHA-256 해시가 다릅니다.")
    reviewer_id, reviewer_roles, organization, reviewed_at, next_review_due = _validate_reviewer(decisions)
    rights = _validate_rights_review(decisions)
    span_decisions = _validated_span_decisions(decisions, products, spans)

    product_by_id = {str(product["product_id"]): product for product in products}
    approved_spans: list[dict[str, Any]] = []
    approved_span_ids_by_product: dict[str, dict[str, list[str]]] = {}
    source = stage_manifest.get("source")
    transformer = stage_manifest.get("transformer")
    stage_input = stage_manifest.get("input")
    if not isinstance(source, dict) or not isinstance(transformer, dict) or not isinstance(stage_input, dict):
        raise ApprovalError("staged 출처·변환기·입력 메타데이터가 불완전합니다.")
    for span in spans:
        decision = span_decisions[str(span["span_id"])]
        if decision["decision"] != "approved":
            continue
        product = product_by_id[str(span["product_id"])]
        evidence = _approved_evidence(
            span,
            product,
            decision,
            source,
            transformer,
            stage_input,
            rights,
            reviewer_id,
            reviewer_roles,
            reviewed_at,
            next_review_due,
            approval_id,
        )
        approved_spans.append(evidence)
        approved_span_ids_by_product.setdefault(str(span["product_id"]), {}).setdefault(
            str(span["section"]), []
        ).append(str(span["span_id"]))
    if not approved_spans:
        raise ApprovalError("승인된 span이 0건이므로 approved snapshot을 만들 수 없습니다.")

    approved_products = []
    for product in products:
        product_id = str(product["product_id"])
        if product_id not in approved_span_ids_by_product:
            continue
        approved_products.append(
            {
                "schema_version": SCHEMA_VERSION,
                "approval_id": approval_id,
                "document_id": product_id,
                "product_id": product_id,
                "item_seq": product["item_seq"],
                "product_name": product.get("product_name"),
                "manufacturer_name": product.get("manufacturer_name"),
                "disclosed_at": product.get("disclosed_at"),
                "updated_at": product.get("updated_at"),
                "approved_span_ids_by_section": approved_span_ids_by_product[product_id],
                "raw_source_refs": product.get("source_refs"),
                "review_status": "clinician_approved",
                "reviewed_at": reviewed_at,
                "next_review_due": next_review_due,
                "status": "approved_inactive",
                "runtime_rag_eligible": False,
            }
        )

    products_bytes = _jsonl_bytes(approved_products)
    spans_bytes = _jsonl_bytes(approved_spans)
    decisions_bytes = _json_bytes(decisions)
    approved_manifest = {
        "schema_version": SCHEMA_VERSION,
        "approval_id": approval_id,
        "approval_state": "approved_snapshot",
        "activation_state": "pending_index_and_regression",
        "runtime_rag_eligible": False,
        "source": source,
        "input": {
            "stage_id": stage_manifest.get("stage_id"),
            "staged_local_path": _relative_path(root, staged),
            "staged_manifest_sha256": stage_manifest_hash,
            "review_packet_id": packet_manifest.get("review_packet_id"),
            "review_packet_local_path": _relative_path(root, packet),
            "review_packet_manifest_sha256": packet_manifest_hash,
            "review_decisions_sha256": _sha256_file(decisions_path),
        },
        "rights_review": rights,
        "clinical_review": {
            "completed": True,
            "reviewer_id": reviewer_id,
            "reviewer_roles": reviewer_roles,
            "reviewer_organization": organization,
            "reviewed_at": reviewed_at,
            "next_review_due": next_review_due,
            "attestation": CLINICAL_ATTESTATION,
            "credential_verification_recorded": True,
        },
        "summary": {
            "reviewed_product_count": len(products),
            "reviewed_span_count": len(spans),
            "approved_product_count": len(approved_products),
            "approved_span_count": len(approved_spans),
            "rejected_span_count": len(spans) - len(approved_spans),
        },
        "promotion": {
            "script": "scripts/promote_mfds_easy_drug.py",
            "version": SCRIPT_VERSION,
            "network_access": False,
            "medical_content_generated": False,
            "human_credentials_cryptographically_verified": False,
        },
        "usage": {
            "do_not_train": True,
            "mobile_bundle": False,
            "runtime_rag_eligible": False,
            "allowed": [
                "approved_index_build_input",
                "medical_regression_candidate",
                "DS_AGENT_evidence_source",
            ],
            "activation_requires": [
                "approved-only index build",
                "citation integrity validation",
                "medical regression hard-gate pass",
                "explicit release activation",
            ],
        },
        "outputs": [
            _output_metadata("approved_products.jsonl", products_bytes, len(approved_products)),
            _output_metadata("approved_evidence_spans.jsonl", spans_bytes, len(approved_spans)),
            _output_metadata("review_decisions.json", decisions_bytes),
        ],
    }
    _write_atomic_directory(
        output,
        {
            "approved_products.jsonl": products_bytes,
            "approved_evidence_spans.jsonl": spans_bytes,
            "review_decisions.json": decisions_bytes,
            "manifest.json": _json_bytes(approved_manifest),
        },
    )
    return output


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="e약은요 staged 자료의 사람 검수 패킷을 만들고 승인 결과를 안전하게 승격합니다."
    )
    parser.add_argument("--workspace-root", type=Path, default=Path("."))
    subparsers = parser.add_subparsers(dest="command", required=True)

    catalog = subparsers.add_parser("catalog", help="검수 대상 선택용 compact catalog 생성")
    catalog.add_argument("--staged-dir", type=Path, required=True)
    catalog.add_argument("--output-dir", type=Path)

    prepare = subparsers.add_parser("prepare", help="선택 품목의 임상 검수 packet 생성")
    prepare.add_argument("--staged-dir", type=Path, required=True)
    prepare.add_argument("--selection-file", type=Path, required=True)
    prepare.add_argument("--review-id", required=True)
    prepare.add_argument("--output-dir", type=Path)

    promote = subparsers.add_parser("promote", help="완료된 사람 검수를 approved snapshot으로 승격")
    promote.add_argument("--staged-dir", type=Path, required=True)
    promote.add_argument("--packet-dir", type=Path, required=True)
    promote.add_argument("--decisions-file", type=Path, required=True)
    promote.add_argument("--approval-id", required=True)
    promote.add_argument("--output-dir", type=Path)
    return parser


def _under_root(root: Path, path: Path) -> Path:
    return path if path.is_absolute() else root / path


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root = args.workspace_root.resolve()
    try:
        staged = _under_root(root, args.staged_dir)
        if args.command == "catalog":
            output = args.output_dir or (
                Path("data/easy-drug/review") / f"{staged.name}-review-v1"
            )
            result = create_review_catalog(root, staged, _under_root(root, output))
            print(f"review catalog saved: {result}")
            print("approval state: awaiting_selection")
            return 0
        if args.command == "prepare":
            output = args.output_dir or (
                Path("data/easy-drug/review-packets") / args.review_id
            )
            result = prepare_review_packet(
                root,
                staged,
                _under_root(root, args.selection_file),
                _under_root(root, output),
                args.review_id,
            )
            print(f"review packet saved: {result}")
            print("approval state: awaiting_clinical_review")
            return 0
        output = args.output_dir or Path("data/easy-drug/approved") / args.approval_id
        result = promote_approved_snapshot(
            root,
            staged,
            _under_root(root, args.packet_dir),
            _under_root(root, args.decisions_file),
            _under_root(root, output),
            args.approval_id,
        )
        print(f"approved snapshot saved: {result}")
        print("runtime RAG: disabled (index/regression/activation required)")
        return 0
    except ApprovalError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
