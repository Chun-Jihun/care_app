"""Resumable immutable source pages and strict completion checks (PC only)."""
from __future__ import annotations

import hashlib
import json
import math
import os
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable

from scripts.fetch_mfds_easy_drug import (
    DownloaderError, PageResult, _sanitize_error_text, fetch_page,
    isoformat_utc, parse_page_payload, utc_now, write_bytes_atomic,
)
from scripts.mfds_catalog import SERVICES, UNREVIEWED, build_url


def now() -> str:
    return isoformat_utc(utc_now())


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def save_json(path: Path, value: dict) -> None:
    """Atomically replace checkpoint metadata, never the raw source pages."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with tmp.open("w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        tmp.replace(path)
    finally:
        tmp.unlink(missing_ok=True)


def items_from(page: PageResult) -> list[dict]:
    doc = json.loads(page.raw_bytes)
    body = doc.get("response", doc)["body"]
    for field in ("pageNo", "numOfRows", "totalCount"):
        if field not in body or body[field] in (None, ""):
            raise DownloaderError(f"필수 페이지 메타데이터 없음: {field}")
    items = body.get("items") or []
    if isinstance(items, dict):
        items = items.get("item", items) or []
        if isinstance(items, dict):
            items = [items]
    if not isinstance(items, list) or not all(isinstance(i, dict) for i in items):
        raise DownloaderError("품목 목록 형식 오류")
    if any(not str(i.get("ITEM_SEQ") or "").strip() for i in items):
        raise DownloaderError("품목기준코드가 없는 원문입니다.")
    return items


def validate_page(page: PageResult, rows: int, total: int | None) -> str:
    if page.num_rows != rows or (total is not None and page.total_count != total):
        raise DownloaderError("수집 중 총 건수 또는 페이지 크기가 변경되었습니다. 새 스냅샷이 필요합니다.")
    expected = min(rows, max(0, page.total_count - (page.page_no - 1) * rows))
    items = items_from(page)
    if len(items) != expected or page.item_count != expected:
        raise DownloaderError("중간 빈 페이지 또는 응답 건수 누락을 발견했습니다.")
    canonical = json.dumps(items, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return digest(canonical.encode("utf-8"))


def load_page(path: Path, entry: dict, rows: int) -> PageResult:
    payload = path.read_bytes()
    if len(payload) != entry["bytes"] or digest(payload) != entry["sha256"]:
        raise DownloaderError("저장된 API 원문의 해시 또는 크기가 다릅니다.")
    return parse_page_payload(payload, requested_page_no=entry["page_no"],
                              requested_num_rows=rows, http_status=200,
                              content_type="application/json")


def read_manifest(snapshot: Path, *, require_complete: bool = True) -> dict:
    m = json.loads((snapshot / "manifest.json").read_text(encoding="utf-8"))
    service = SERVICES.get(m.get("service"))
    if (m.get("schema_version") != 1 or service is None
            or set(m.get("operations", {})) != set(service.operations)
            or any(m.get(k) != v for k, v in UNREVIEWED.items())
            or type(m.get("num_rows")) is not int or not 1 <= m["num_rows"] <= 500):
        raise DownloaderError("지원하지 않거나 안전 상태가 변경된 스냅샷입니다.")
    if require_complete and m.get("download_complete") is not True:
        raise DownloaderError("전체 수집을 완료하지 않은 스냅샷입니다.")
    return m


def verified_pages(snapshot: Path, m: dict):
    """Stream and verify every referenced page, including on resume/indexing."""
    rows = m["num_rows"]
    for op in SERVICES[m["service"]].operations:
        state = m["operations"][op]
        if (type(state.get("complete")) is not bool
                or (state.get("total_count") is not None
                    and (type(state["total_count"]) is not int or state["total_count"] < 0))):
            raise DownloaderError("작업별 완료 상태 또는 총 건수 형식이 잘못되었습니다.")
        seen: set[str] = set()
        count = 0
        for number, entry in enumerate(state["pages"], 1):
            relative = f"raw/{op}/page-{number:05d}.json"
            if entry.get("file") != relative or entry.get("page_no") != number:
                raise DownloaderError("페이지 순서 또는 경로가 잘못되었습니다.")
            page = load_page(snapshot / relative, entry, rows)
            if entry.get("item_count") != page.item_count:
                raise DownloaderError("기록된 페이지 건수와 실제 원문이 다릅니다.")
            fingerprint = validate_page(page, rows, state["total_count"])
            if fingerprint in seen or fingerprint != entry["items_sha256"]:
                raise DownloaderError("반복 또는 변조된 페이지를 발견했습니다.")
            seen.add(fingerprint)
            count += page.item_count
            yield op, entry, page
        if state["complete"] or m["download_complete"]:
            expected_pages = max(1, math.ceil((state["total_count"] or 0) / rows))
            if (state["total_count"] is None or count != state["total_count"]
                    or len(state["pages"]) != expected_pages or not state["complete"]):
                raise DownloaderError("수집 완료 표시와 실제 페이지 수가 다릅니다.")


def collect(snapshot: Path, service_name: str, base: str, key: str, *,
            rows: int = 500, workers: int = 4, delay: float = 0.25,
            max_requests: int = 9500, resume: bool = False,
            page_fetcher: Callable = fetch_page) -> dict:
    service = SERVICES[service_name]
    if not 1 <= rows <= 500 or not 1 <= workers <= 8 or delay < 0 or max_requests < 1:
        raise DownloaderError("페이지 크기·작업 수·대기시간·요청 한도를 확인하세요.")
    # Validate even when there are no pending pages; never trust a resume URL.
    build_url(f"{base}/{service.operations[0]}", key, page_no=1, num_rows=rows, filters={})
    if resume:
        m = read_manifest(snapshot, require_complete=False)
        if m["service"] != service_name or m["num_rows"] != rows:
            raise DownloaderError("재개 대상 서비스와 페이지 크기가 다릅니다.")
        for _ in verified_pages(snapshot, m):
            pass
        if m["download_complete"]:
            return m
    else:
        snapshot.mkdir(parents=True, exist_ok=False)
        m = {"schema_version": 1, "snapshot_id": snapshot.name,
             "service": service_name, "source_title": service.title,
             "publisher": "식품의약품안전처", "catalog_url": service.catalog_url,
             "endpoint": base, "started_at": now(), "num_rows": rows,
             **UNREVIEWED, "download_complete": False,
             "patient_context_in_request": False, "credential_persisted": False,
             "consistency": "paginated_live_api_not_transactional",
             "operations": {op: {"total_count": None, "complete": False, "pages": []}
                            for op in service.operations}}
        save_json(snapshot / "manifest.json", m)
    requested = 0

    def retrieve(op: str, number: int) -> PageResult:
        if delay:
            time.sleep(delay)
        page = page_fetcher(f"{base}/{op}", key, page_no=number, num_rows=rows,
                            filters={}, timeout_seconds=60, retries=3, url_builder=build_url)
        text = page.raw_bytes.decode("utf-8-sig")
        decoded = json.dumps(json.loads(text), ensure_ascii=False)
        if _sanitize_error_text(text, key) != text or _sanitize_error_text(decoded, key) != decoded:
            raise DownloaderError("응답에 인증정보가 포함되어 저장을 차단했습니다.")
        return page

    try:
        with ThreadPoolExecutor(max_workers=workers) as pool:
            for op in service.operations:
                state = m["operations"][op]
                seen = {p["items_sha256"] for p in state["pages"]}
                while not state["complete"]:
                    first = len(state["pages"]) + 1
                    last = (max(1, math.ceil(state["total_count"] / rows))
                            if state["total_count"] is not None else 1)
                    numbers = range(first, min(first + workers - 1, last) + 1)
                    if requested + len(numbers) > max_requests:
                        raise DownloaderError("이번 실행의 요청 한도에 도달했습니다. --resume으로 재개하세요.")
                    requested += len(numbers)
                    futures = [pool.submit(retrieve, op, number) for number in numbers]
                    for future in futures:
                        page = future.result()
                        fingerprint = validate_page(page, rows, state["total_count"])
                        if fingerprint in seen:
                            raise DownloaderError("서버가 이전과 같은 페이지를 반복했습니다.")
                        relative = f"raw/{op}/page-{page.page_no:05d}.json"
                        path = snapshot / relative
                        if path.exists():
                            if path.read_bytes() != page.raw_bytes:
                                raise DownloaderError("중단 전 원문과 재요청 결과가 달라 새 스냅샷이 필요합니다.")
                        else:
                            write_bytes_atomic(path, page.raw_bytes)
                        state["total_count"] = page.total_count
                        state["pages"].append({"file": relative, "page_no": page.page_no,
                                               "bytes": len(page.raw_bytes),
                                               "sha256": digest(page.raw_bytes),
                                               "items_sha256": fingerprint,
                                               "item_count": page.item_count,
                                               "fetched_at": now()})
                        seen.add(fingerprint)
                        state["complete"] = page.page_no == max(1, math.ceil(page.total_count / rows))
                    m["updated_at"] = now()
                    save_json(snapshot / "manifest.json", m)
                    if first == 1 or state["complete"] or first // 50 != len(state["pages"]) // 50:
                        total_pages = max(1, math.ceil(state['total_count'] / rows))
                        print(f"{service_name}/{op}: {len(state['pages'])}/{total_pages} pages; "
                              f"total={state['total_count']}", flush=True)
        m["download_complete"] = True
        m["completed_at"] = now()
        m.pop("last_error", None)
        save_json(snapshot / "manifest.json", m)
        return m
    except (Exception, KeyboardInterrupt):
        # Store a fixed message, not response bodies, keyed URLs or tracebacks.
        m["last_error"] = "collection_interrupted; verify and resume"
        save_json(snapshot / "manifest.json", m)
        raise
