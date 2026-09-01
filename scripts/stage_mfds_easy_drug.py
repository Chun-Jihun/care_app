#!/usr/bin/env python3
"""Validate and normalize an immutable MFDS e약은요 raw snapshot.

This transformer is deterministic and offline. It preserves source text,
creates traceable evidence spans, and always emits ``staged_unreviewed`` data.
It never performs clinical approval or makes the output runtime-RAG eligible.
"""

from __future__ import annotations

import argparse
import hashlib
from html.parser import HTMLParser
import json
import os
import re
import shutil
import sys
import tempfile
import unicodedata
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Sequence

if __package__:
    from .freeze_asset_manifests import hash_directory, sha256_file
else:
    from freeze_asset_manifests import hash_directory, sha256_file


SCRIPT_VERSION = "0.1.0"
STAGED_SCHEMA_VERSION = "1.0"
DEFAULT_ASSET_LOCK = Path("experiments/agent_eval/manifests/data_sources.lock.json")
DEFAULT_ASSET_ID = "RAG-DRUG-01"
TEXT_FIELDS = {
    "effectiveness": "efcyQesitm",
    "usage": "useMethodQesitm",
    "warnings": "atpnWarnQesitm",
    "precautions": "atpnQesitm",
    "interactions": "intrcQesitm",
    "adverse_reactions": "seQesitm",
    "storage": "depositMethodQesitm",
}
IDENTITY_FIELDS = (
    "entpName",
    "itemName",
    "itemSeq",
    "openDe",
    "updateDe",
    "bizrno",
)
EXPECTED_FIELDS = set(IDENTITY_FIELDS) | set(TEXT_FIELDS.values()) | {"itemImage"}
REQUIRED_FIELDS = set(IDENTITY_FIELDS)
BLOCK_TAGS = {
    "address",
    "article",
    "aside",
    "blockquote",
    "br",
    "dd",
    "div",
    "dl",
    "dt",
    "figcaption",
    "figure",
    "footer",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "header",
    "hr",
    "li",
    "main",
    "nav",
    "ol",
    "p",
    "pre",
    "section",
    "table",
    "td",
    "th",
    "tr",
    "ul",
}


class StagingError(RuntimeError):
    """Raised when raw data cannot be staged without losing provenance."""


class _VisibleTextParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._hidden_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        del attrs
        name = tag.lower()
        if name in {"script", "style"}:
            self._hidden_depth += 1
            return
        if self._hidden_depth == 0 and name in BLOCK_TAGS:
            self.parts.append("\n")

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag: str) -> None:
        name = tag.lower()
        if name in {"script", "style"} and self._hidden_depth:
            self._hidden_depth -= 1
            return
        if self._hidden_depth == 0 and name in BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self._hidden_depth == 0:
            self.parts.append(data)


def normalize_medical_text(value: str | None) -> tuple[str, list[str]]:
    """Extract visible text and normalize only Unicode and whitespace."""

    if value is None or not str(value).strip():
        return "", []
    parser = _VisibleTextParser()
    try:
        parser.feed(str(value))
        parser.close()
    except Exception as exc:
        raise StagingError("의료 원문의 HTML/text 구조를 파싱할 수 없습니다.") from exc
    visible = "".join(parser.parts).replace("\r\n", "\n").replace("\r", "\n")
    visible = unicodedata.normalize("NFC", visible).replace("\u00a0", " ")
    blocks = []
    for line in visible.split("\n"):
        normalized_line = re.sub(r"[\t\f\v ]+", " ", line).strip()
        if normalized_line:
            blocks.append(normalized_line)
    return "\n\n".join(blocks), blocks


def _safe_relative_path(workspace_root: Path, path: Path) -> str:
    root = workspace_root.resolve()
    resolved = path.resolve()
    if not resolved.is_relative_to(root):
        raise StagingError(f"workspace 밖의 경로는 사용할 수 없습니다: {path}")
    return resolved.relative_to(root).as_posix()


def _resolve_locked_path(workspace_root: Path, local_path: Any) -> Path:
    if not isinstance(local_path, str) or not local_path:
        raise StagingError("asset lock의 local_path가 잘못되었습니다.")
    pure = PurePosixPath(local_path.replace("\\", "/"))
    if pure.is_absolute() or ".." in pure.parts:
        raise StagingError("asset lock의 local_path가 workspace 밖을 가리킵니다.")
    result = (workspace_root.resolve() / Path(*pure.parts)).resolve()
    if not result.is_relative_to(workspace_root.resolve()):
        raise StagingError("asset lock의 local_path가 workspace 밖을 가리킵니다.")
    return result


def _load_json(path: Path, description: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError as exc:
        raise StagingError(f"{description}을 찾을 수 없습니다: {path}") from exc
    except json.JSONDecodeError as exc:
        raise StagingError(f"{description} JSON이 잘못되었습니다: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise StagingError(f"{description} 최상위 값은 JSON object여야 합니다.")
    return value


def _asset_entry(asset_lock_path: Path, asset_id: str) -> dict[str, Any]:
    lock = _load_json(asset_lock_path, "data sources lock")
    entries = lock.get("data_sources")
    if not isinstance(entries, list):
        raise StagingError("data sources lock에 data_sources 배열이 없습니다.")
    matches = [entry for entry in entries if isinstance(entry, dict) and entry.get("id") == asset_id]
    if len(matches) != 1:
        raise StagingError(f"data sources lock에서 {asset_id}를 하나만 찾을 수 있어야 합니다.")
    return matches[0]


def locked_raw_directory(
    workspace_root: Path, asset_lock_path: Path, asset_id: str = DEFAULT_ASSET_ID
) -> Path:
    entry = _asset_entry(asset_lock_path, asset_id)
    return _resolve_locked_path(workspace_root, entry.get("local_path"))


def _validate_asset_lock(
    workspace_root: Path,
    raw_dir: Path,
    asset_lock_path: Path,
    asset_id: str,
) -> tuple[dict[str, Any], str]:
    entry = _asset_entry(asset_lock_path, asset_id)
    if entry.get("availability") != "present":
        raise StagingError(f"{asset_id}가 asset lock에서 present 상태가 아닙니다.")
    locked_path = _resolve_locked_path(workspace_root, entry.get("local_path"))
    if locked_path != raw_dir.resolve():
        raise StagingError("요청한 raw 경로가 asset lock의 경로와 다릅니다.")
    approval = entry.get("approval") or {}
    if approval.get("state") != "raw_unreviewed" or approval.get(
        "runtime_rag_eligible"
    ) is not False:
        raise StagingError("asset lock의 raw 승인 경계가 잘못되었습니다.")
    expected_tree = (entry.get("integrity") or {}).get("tree_sha256")
    if not isinstance(expected_tree, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_tree):
        raise StagingError("asset lock에 유효한 raw tree SHA-256이 없습니다.")
    actual_tree = hash_directory(raw_dir, workers=2).tree_sha256
    if actual_tree != expected_tree:
        raise StagingError("raw 디렉터리가 data_sources.lock 이후 변경되었습니다.")
    return entry, actual_tree


def _page_items(value: Any) -> list[dict[str, Any]]:
    if value is None or value == "":
        return []
    if isinstance(value, list):
        items = value
    elif isinstance(value, dict) and "item" in value:
        nested = value["item"]
        items = nested if isinstance(nested, list) else ([] if nested is None else [nested])
    elif isinstance(value, dict):
        items = [value]
    else:
        raise StagingError("raw page의 items 형식이 잘못되었습니다.")
    if not all(isinstance(item, dict) for item in items):
        raise StagingError("raw page의 item은 JSON object여야 합니다.")
    return items


def _as_int(value: Any, field: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise StagingError(f"raw page의 {field}가 정수가 아닙니다.") from exc


def _load_verified_rows(
    raw_dir: Path, raw_manifest: Mapping[str, Any]
) -> tuple[list[dict[str, Any]], dict[str, str]]:
    download = raw_manifest.get("download")
    handling = raw_manifest.get("handling")
    if raw_manifest.get("approval_state") != "raw_unreviewed":
        raise StagingError("raw manifest는 raw_unreviewed 상태여야 합니다.")
    if not isinstance(handling, dict) or handling.get("runtime_rag_eligible") is not False:
        raise StagingError("raw manifest는 runtime RAG 비활성 상태여야 합니다.")
    if not isinstance(download, dict) or download.get("complete") is not True:
        raise StagingError("불완전한 raw 다운로드는 staged로 변환할 수 없습니다.")
    page_entries = download.get("pages")
    if not isinstance(page_entries, list) or not page_entries:
        raise StagingError("raw manifest에 page 목록이 없습니다.")
    if _as_int(download.get("page_count"), "page_count") != len(page_entries):
        raise StagingError("raw manifest의 page_count가 page 목록과 다릅니다.")

    rows: list[dict[str, Any]] = []
    page_hashes: dict[str, str] = {}
    page_numbers: list[int] = []
    manifest_files: set[str] = set()
    for page_entry in page_entries:
        if not isinstance(page_entry, dict):
            raise StagingError("raw manifest의 page 항목이 object가 아닙니다.")
        filename = page_entry.get("file")
        if not isinstance(filename, str) or Path(filename).name != filename:
            raise StagingError("raw manifest의 page 파일명이 안전하지 않습니다.")
        if filename in manifest_files:
            raise StagingError(f"raw manifest에 중복 page 파일이 있습니다: {filename}")
        manifest_files.add(filename)
        page_path = raw_dir / filename
        try:
            raw_bytes = page_path.read_bytes()
        except FileNotFoundError as exc:
            raise StagingError(f"raw page 파일이 없습니다: {filename}") from exc
        actual_hash = hashlib.sha256(raw_bytes).hexdigest()
        if actual_hash != page_entry.get("sha256"):
            raise StagingError(f"raw page SHA-256이 manifest와 다릅니다: {filename}")
        if len(raw_bytes) != _as_int(page_entry.get("bytes"), "page bytes"):
            raise StagingError(f"raw page byte 길이가 manifest와 다릅니다: {filename}")
        try:
            page = json.loads(raw_bytes)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise StagingError(f"raw page JSON이 잘못되었습니다: {filename}") from exc
        header = page.get("header") if isinstance(page, dict) else None
        body = page.get("body") if isinstance(page, dict) else None
        if not isinstance(header, dict) or str(header.get("resultCode")) != "00":
            raise StagingError(f"raw page API 결과가 성공이 아닙니다: {filename}")
        if not isinstance(body, dict):
            raise StagingError(f"raw page body가 없습니다: {filename}")
        page_number = _as_int(body.get("pageNo"), "pageNo")
        if page_number != _as_int(page_entry.get("page_no"), "manifest page_no"):
            raise StagingError(f"raw page 번호가 manifest와 다릅니다: {filename}")
        page_numbers.append(page_number)
        items = _page_items(body.get("items"))
        if len(items) != _as_int(page_entry.get("item_count"), "item_count"):
            raise StagingError(f"raw page item 수가 manifest와 다릅니다: {filename}")
        page_hashes[filename] = actual_hash
        for item_index, item in enumerate(items):
            rows.append(
                {
                    "item": item,
                    "source_ref": {
                        "page_file": filename,
                        "page_sha256": actual_hash,
                        "item_index": item_index,
                        "json_pointer": f"/body/items/{item_index}",
                    },
                }
            )

    page_numbers_sorted = sorted(page_numbers)
    if page_numbers_sorted != list(range(page_numbers_sorted[0], page_numbers_sorted[-1] + 1)):
        raise StagingError("raw page 번호가 연속적이지 않습니다.")
    disk_pages = {path.name for path in raw_dir.glob("page-*.json") if path.is_file()}
    if disk_pages != manifest_files:
        raise StagingError("raw 디렉터리의 page 파일 집합이 manifest와 다릅니다.")
    expected_items = _as_int(download.get("downloaded_item_count"), "downloaded_item_count")
    reported_total = _as_int(download.get("reported_total_count"), "reported_total_count")
    if len(rows) != expected_items or expected_items != reported_total:
        raise StagingError("raw 전체 item 수가 manifest의 완료 건수와 다릅니다.")
    return rows, page_hashes


def _required_string(item: Mapping[str, Any], field: str) -> str:
    value = item.get(field)
    if not isinstance(value, str) or not value.strip():
        raise StagingError(f"필수 필드 {field}가 비어 있거나 문자열이 아닙니다.")
    return value


def _date(value: str, source_field: str) -> str:
    formats = ("%Y%m%d", "%Y-%m-%d")
    for date_format in formats:
        try:
            return datetime.strptime(value, date_format).date().isoformat()
        except ValueError:
            continue
    raise StagingError(f"필수 날짜 {source_field} 형식이 잘못되었습니다: {value}")


def _metadata_text(value: str) -> str:
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", value)).strip()


def _canonical_without_image(item: Mapping[str, Any]) -> str:
    return json.dumps(
        {field: item.get(field) for field in sorted(EXPECTED_FIELDS - {"itemImage"})},
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def _stable_span_id(item_seq: str, section: str, ordinal: int, text: str) -> str:
    short_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]
    return f"MFDS-EASY-{item_seq}-{section.upper()}-{ordinal:04d}-{short_hash}"


def _build_product(
    item_seq: str,
    group: list[dict[str, Any]],
) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, Any]]:
    canonical_values = {_canonical_without_image(row["item"]) for row in group}
    if len(canonical_values) != 1:
        differing = []
        for field in sorted(EXPECTED_FIELDS - {"itemImage"}):
            values = {
                json.dumps(row["item"].get(field), ensure_ascii=False, sort_keys=True)
                for row in group
            }
            if len(values) > 1:
                differing.append(field)
        raise StagingError(
            f"품목코드 {item_seq}의 중복 행에서 병합 불가능한 필드가 충돌합니다: "
            + ", ".join(differing)
        )
    item = group[0]["item"]
    unexpected = set(item) - EXPECTED_FIELDS
    if unexpected:
        raise StagingError(
            f"품목코드 {item_seq}에 매핑되지 않은 API 필드가 있습니다: "
            + ", ".join(sorted(unexpected))
        )
    for field in REQUIRED_FIELDS:
        _required_string(item, field)
    for field in TEXT_FIELDS.values():
        value = item.get(field)
        if value is not None and not isinstance(value, str):
            raise StagingError(f"품목코드 {item_seq}의 {field}가 문자열이 아닙니다.")

    source_refs = sorted(
        (row["source_ref"] for row in group),
        key=lambda ref: (ref["page_file"], ref["item_index"]),
    )
    image_urls = sorted(
        {
            str(row["item"].get("itemImage")).strip()
            for row in group
            if row["item"].get("itemImage") is not None
            and str(row["item"].get("itemImage")).strip()
        }
    )
    product_id = f"MFDS-EASY-{item_seq}"
    sections: dict[str, Any] = {}
    evidence_spans: list[dict[str, Any]] = []
    normalization_changed_fields: list[str] = []
    for section, source_field in TEXT_FIELDS.items():
        raw_value = item.get(source_field)
        raw_text = raw_value if isinstance(raw_value, str) else None
        normalized_text, blocks = normalize_medical_text(raw_text)
        span_ids = []
        offset = 0
        for ordinal, block in enumerate(blocks, start=1):
            start = normalized_text.find(block, offset)
            if start < 0:
                raise StagingError("정규화된 근거 span offset을 계산할 수 없습니다.")
            end = start + len(block)
            span_id = _stable_span_id(item_seq, section, ordinal, block)
            span_ids.append(span_id)
            evidence_spans.append(
                {
                    "schema_version": STAGED_SCHEMA_VERSION,
                    "span_id": span_id,
                    "document_id": product_id,
                    "product_id": product_id,
                    "item_seq": item_seq,
                    "section": section,
                    "source_field": source_field,
                    "ordinal": ordinal,
                    "location": f"{source_field}#{ordinal}",
                    "text": block,
                    "text_sha256": hashlib.sha256(block.encode("utf-8")).hexdigest(),
                    "normalized_start": start,
                    "normalized_end": end,
                    "source_refs": source_refs,
                    "review_status": "unreviewed",
                    "runtime_rag_eligible": False,
                }
            )
            offset = end
        if raw_text is not None and raw_text != normalized_text:
            normalization_changed_fields.append(source_field)
        sections[section] = {
            "source_field": source_field,
            "raw_text": raw_text,
            "raw_text_sha256": (
                hashlib.sha256(raw_text.encode("utf-8")).hexdigest()
                if raw_text is not None
                else None
            ),
            "normalized_text": normalized_text or None,
            "normalized_text_sha256": (
                hashlib.sha256(normalized_text.encode("utf-8")).hexdigest()
                if normalized_text
                else None
            ),
            "span_ids": span_ids,
        }

    source_values = {field: item.get(field) for field in IDENTITY_FIELDS}
    product = {
        "schema_version": STAGED_SCHEMA_VERSION,
        "product_id": product_id,
        "item_seq": item_seq,
        "product_name": _metadata_text(_required_string(item, "itemName")),
        "manufacturer_name": _metadata_text(_required_string(item, "entpName")),
        "business_registration_number": _metadata_text(_required_string(item, "bizrno")),
        "disclosed_at": _date(_required_string(item, "openDe"), "openDe"),
        "updated_at": _date(_required_string(item, "updateDe"), "updateDe"),
        "image_urls": image_urls,
        "sections": sections,
        "source_values": source_values,
        "source_refs": source_refs,
        "review_status": "unreviewed",
        "runtime_rag_eligible": False,
    }
    duplicate = {
        "item_seq": item_seq,
        "raw_row_count": len(group),
        "collapsed_rows": len(group) - 1,
        "differing_fields": ["itemImage"] if len(image_urls) or len(group) > 1 else [],
        "image_url_candidate_count": len(image_urls),
        "source_refs": source_refs,
    }
    stats = {
        "normalization_changed_fields": normalization_changed_fields,
        "duplicate": duplicate,
    }
    return product, evidence_spans, stats


def _json_bytes(value: Mapping[str, Any]) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def _jsonl_bytes(values: Sequence[Mapping[str, Any]]) -> bytes:
    return b"".join(
        (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode(
            "utf-8"
        )
        for value in values
    )


def _output_metadata(filename: str, content: bytes, record_count: int | None) -> dict[str, Any]:
    value = {
        "file": filename,
        "bytes": len(content),
        "sha256": hashlib.sha256(content).hexdigest(),
    }
    if record_count is not None:
        value["record_count"] = record_count
    return value


def _validate_staged_records(
    products: Sequence[Mapping[str, Any]], spans: Sequence[Mapping[str, Any]]
) -> None:
    product_by_id: dict[str, Mapping[str, Any]] = {}
    for product in products:
        product_id = product.get("product_id")
        if not isinstance(product_id, str) or product_id in product_by_id:
            raise StagingError("staged product_id가 비어 있거나 중복됩니다.")
        product_by_id[product_id] = product

    span_by_id: dict[str, Mapping[str, Any]] = {}
    for span in spans:
        span_id = span.get("span_id")
        if not isinstance(span_id, str) or span_id in span_by_id:
            raise StagingError("staged evidence span_id가 비어 있거나 중복됩니다.")
        product = product_by_id.get(str(span.get("product_id")))
        if product is None:
            raise StagingError(f"근거 span의 product가 없습니다: {span_id}")
        section_name = span.get("section")
        section = (product.get("sections") or {}).get(section_name)
        if not isinstance(section, dict):
            raise StagingError(f"근거 span의 section이 product에 없습니다: {span_id}")
        normalized = section.get("normalized_text")
        start = span.get("normalized_start")
        end = span.get("normalized_end")
        text = span.get("text")
        if (
            not isinstance(normalized, str)
            or not isinstance(start, int)
            or not isinstance(end, int)
            or not isinstance(text, str)
            or start < 0
            or end < start
            or normalized[start:end] != text
        ):
            raise StagingError(f"근거 span의 문자 offset이 원문 정규화 결과와 다릅니다: {span_id}")
        if not span.get("source_refs"):
            raise StagingError(f"근거 span에 raw source reference가 없습니다: {span_id}")
        span_by_id[span_id] = span

    declared_span_ids: list[str] = []
    for product in products:
        for section in (product.get("sections") or {}).values():
            if not isinstance(section, dict) or not isinstance(section.get("span_ids"), list):
                raise StagingError("product section의 span_ids 형식이 잘못되었습니다.")
            declared_span_ids.extend(section["span_ids"])
    if len(declared_span_ids) != len(set(declared_span_ids)):
        raise StagingError("product section에서 같은 span ID를 두 번 참조합니다.")
    if set(declared_span_ids) != set(span_by_id):
        raise StagingError("product section과 evidence span 파일의 ID 집합이 다릅니다.")


def _write_file(path: Path, content: bytes) -> None:
    with path.open("xb") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())


def stage_snapshot(
    workspace_root: Path,
    raw_dir: Path,
    output_dir: Path,
    asset_lock_path: Path,
    asset_id: str = DEFAULT_ASSET_ID,
) -> Path:
    """Validate one locked raw snapshot and atomically create staged files."""

    workspace_root = workspace_root.resolve()
    raw_dir = raw_dir.resolve()
    output_dir = output_dir.resolve()
    asset_lock_path = asset_lock_path.resolve()
    _safe_relative_path(workspace_root, raw_dir)
    _safe_relative_path(workspace_root, output_dir)
    if output_dir == raw_dir or output_dir.is_relative_to(raw_dir):
        raise StagingError("staged 출력은 raw 디렉터리 내부에 만들 수 없습니다.")
    if output_dir.exists():
        raise StagingError(f"기존 staged 출력을 덮어쓸 수 없습니다: {output_dir}")

    lock_entry, raw_tree_sha256 = _validate_asset_lock(
        workspace_root, raw_dir, asset_lock_path, asset_id
    )
    raw_manifest_path = raw_dir / "manifest.json"
    raw_manifest = _load_json(raw_manifest_path, "raw snapshot manifest")
    locked_manifest_hash = (lock_entry.get("approval") or {}).get("raw_manifest_sha256")
    actual_manifest_hash = sha256_file(raw_manifest_path)
    if locked_manifest_hash and actual_manifest_hash != locked_manifest_hash:
        raise StagingError("raw manifest SHA-256이 data sources lock과 다릅니다.")
    rows, page_hashes = _load_verified_rows(raw_dir, raw_manifest)

    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        item = row["item"]
        unexpected = set(item) - EXPECTED_FIELDS
        if unexpected:
            raise StagingError(
                "매핑되지 않은 API 필드가 있습니다: " + ", ".join(sorted(unexpected))
            )
        item_seq = _required_string(item, "itemSeq").strip()
        if not re.fullmatch(r"[A-Za-z0-9._-]+", item_seq):
            raise StagingError(f"품목코드 형식이 안전하지 않습니다: {item_seq}")
        grouped.setdefault(item_seq, []).append(row)

    products: list[dict[str, Any]] = []
    spans: list[dict[str, Any]] = []
    duplicate_groups: list[dict[str, Any]] = []
    missing_by_field = {field: 0 for field in TEXT_FIELDS.values()}
    normalized_field_count = 0
    products_without_medical_text: list[str] = []
    section_span_counts = {section: 0 for section in TEXT_FIELDS}
    for item_seq in sorted(grouped):
        product, product_spans, stats = _build_product(item_seq, grouped[item_seq])
        products.append(product)
        spans.extend(product_spans)
        for section, section_value in product["sections"].items():
            if not section_value["normalized_text"]:
                missing_by_field[section_value["source_field"]] += 1
            section_span_counts[section] += len(section_value["span_ids"])
        normalized_field_count += len(stats["normalization_changed_fields"])
        if not product_spans:
            products_without_medical_text.append(item_seq)
        if len(grouped[item_seq]) > 1:
            duplicate_groups.append(stats["duplicate"])

    _validate_staged_records(products, spans)

    quality_report = {
        "schema_version": STAGED_SCHEMA_VERSION,
        "input_snapshot_id": raw_manifest.get("snapshot_id"),
        "technical_validation": "passed",
        "summary": {
            "raw_item_count": len(rows),
            "unique_product_count": len(products),
            "duplicate_group_count": len(duplicate_groups),
            "collapsed_duplicate_rows": len(rows) - len(products),
            "evidence_span_count": len(spans),
            "normalization_changed_field_count": normalized_field_count,
        },
        "missing_text_field_counts": missing_by_field,
        "section_span_counts": section_span_counts,
        "products_without_medical_text": products_without_medical_text,
        "duplicate_groups": duplicate_groups,
        "errors": [],
        "clinical_review_completed": False,
    }
    products_bytes = _jsonl_bytes(products)
    spans_bytes = _jsonl_bytes(spans)
    quality_bytes = _json_bytes(quality_report)
    snapshot_id = str(raw_manifest.get("snapshot_id"))
    stage_id = f"mfds-easy-drug-{snapshot_id}-schema-v1"
    outputs = [
        _output_metadata("products.jsonl", products_bytes, len(products)),
        _output_metadata("evidence_spans.jsonl", spans_bytes, len(spans)),
        _output_metadata("quality_report.json", quality_bytes, None),
    ]
    staged_manifest = {
        "schema_version": STAGED_SCHEMA_VERSION,
        "stage_id": stage_id,
        "approval_state": "staged_unreviewed",
        "runtime_rag_eligible": False,
        "source": raw_manifest.get("source"),
        "input": {
            "asset_id": asset_id,
            "raw_snapshot_id": snapshot_id,
            "raw_local_path": _safe_relative_path(workspace_root, raw_dir),
            "raw_tree_sha256": raw_tree_sha256,
            "raw_manifest_sha256": actual_manifest_hash,
            "raw_page_count": len(page_hashes),
            "raw_item_count": len(rows),
            "download_completed_at": (raw_manifest.get("download") or {}).get(
                "completed_at"
            ),
        },
        "transformer": {
            "script": "scripts/stage_mfds_easy_drug.py",
            "version": SCRIPT_VERSION,
            "network_access": False,
            "medical_content_generated": False,
            "normalization": [
                "HTML visible-text extraction",
                "Unicode NFC",
                "NBSP and whitespace normalization",
                "paragraph-preserving evidence spans",
            ],
        },
        "technical_validation": {
            "completed": True,
            "passed": True,
            "checks": [
                "asset lock content-tree match",
                "raw manifest and page SHA-256 match",
                "complete pagination and item count",
                "required identifiers and dates",
                "duplicate medical-field consistency",
                "evidence span offsets",
            ],
        },
        "clinical_review": {
            "completed": False,
            "reviewed_at": None,
            "reviewer_roles": [],
        },
        "usage": {
            "do_not_train": True,
            "mobile_bundle": False,
            "runtime_rag_eligible": False,
            "allowed": ["clinical_review_input", "DS_AGENT_evidence_candidate"],
        },
        "outputs": outputs,
    }
    manifest_bytes = _json_bytes(staged_manifest)

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(
        tempfile.mkdtemp(prefix=f".{output_dir.name}.", dir=str(output_dir.parent))
    )
    try:
        _write_file(temporary / "products.jsonl", products_bytes)
        _write_file(temporary / "evidence_spans.jsonl", spans_bytes)
        _write_file(temporary / "quality_report.json", quality_bytes)
        _write_file(temporary / "manifest.json", manifest_bytes)
        if output_dir.exists():
            raise StagingError(f"기존 staged 출력을 덮어쓸 수 없습니다: {output_dir}")
        temporary.rename(output_dir)
    except Exception:
        if temporary.exists():
            shutil.rmtree(temporary)
        raise
    return output_dir


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="고정된 e약은요 raw snapshot을 검증하고 staged_unreviewed 데이터로 변환합니다."
    )
    parser.add_argument("--workspace-root", type=Path, default=Path("."))
    parser.add_argument("--asset-lock", type=Path, default=DEFAULT_ASSET_LOCK)
    parser.add_argument("--asset-id", default=DEFAULT_ASSET_ID)
    parser.add_argument("--raw-dir", type=Path)
    parser.add_argument("--output-dir", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    workspace_root = args.workspace_root.resolve()
    asset_lock_path = args.asset_lock
    if not asset_lock_path.is_absolute():
        asset_lock_path = workspace_root / asset_lock_path
    try:
        raw_dir = args.raw_dir
        if raw_dir is None:
            raw_dir = locked_raw_directory(workspace_root, asset_lock_path, args.asset_id)
        elif not raw_dir.is_absolute():
            raw_dir = workspace_root / raw_dir
        raw_manifest = _load_json(raw_dir / "manifest.json", "raw snapshot manifest")
        snapshot_id = raw_manifest.get("snapshot_id")
        if not isinstance(snapshot_id, str) or not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", snapshot_id
        ):
            raise StagingError("raw snapshot_id 형식이 잘못되었습니다.")
        output_dir = args.output_dir
        if output_dir is None:
            output_dir = Path("data/easy-drug/staged") / f"{snapshot_id}-schema-v1"
        if not output_dir.is_absolute():
            output_dir = workspace_root / output_dir
        result = stage_snapshot(
            workspace_root, raw_dir, output_dir, asset_lock_path, args.asset_id
        )
    except StagingError as exc:
        print(f"오류: {exc}", file=sys.stderr)
        return 1
    print(f"staged snapshot saved: {result}")
    print("approval state: staged_unreviewed")
    print("runtime RAG eligible: false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
