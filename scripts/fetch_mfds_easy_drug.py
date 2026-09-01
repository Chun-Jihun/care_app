#!/usr/bin/env python3
"""Download immutable raw snapshots from the MFDS e약은요 OpenAPI.

The default command fetches only page 1 with 10 records. Use ``--all-pages``
explicitly for a paginated snapshot. API responses remain unmodified in the
raw directory and are marked ``raw_unreviewed`` in the generated manifest.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import unquote, urlencode, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from xml.etree import ElementTree


SCRIPT_VERSION = "0.1.0"
DATASET_ID = "15075057"
DATASET_PAGE_URL = "https://www.data.go.kr/data/15075057/openapi.do"
ALLOWED_HOST = "apis.data.go.kr"
SERVICE_BASE_PATH = "/1471000/DrbEasyDrugInfoService"
LIST_ENDPOINT_PATH = f"{SERVICE_BASE_PATH}/getDrbEasyDrugList"
DEFAULT_ENDPOINT = f"https://{ALLOWED_HOST}{LIST_ENDPOINT_PATH}"
DEFAULT_OUTPUT_ROOT = Path("./data/easy-drug/raw")
RETRYABLE_API_CODES = {"01", "04", "05", "22", "23"}
FILTER_PARAMETER_NAMES = {
    "entp_name": "entpName",
    "item_name": "itemName",
    "item_seq": "itemSeq",
    "open_date": "openDe",
    "update_date": "updateDe",
}


class DownloaderError(RuntimeError):
    """Base error for safe, user-facing downloader failures."""


class ConfigurationError(DownloaderError):
    """Raised when local configuration is missing or unsafe."""


class ApiResponseError(DownloaderError):
    """Raised when the gateway or provider reports a failed response."""

    def __init__(self, result_code: str, result_message: str) -> None:
        self.result_code = result_code
        self.result_message = result_message
        super().__init__(f"API resultCode={result_code}: {result_message}")


@dataclass(frozen=True)
class PageResult:
    """Validated metadata plus the exact bytes returned by the API."""

    raw_bytes: bytes
    result_code: str
    result_message: str
    page_no: int
    num_rows: int
    total_count: int
    item_count: int
    http_status: int
    content_type: str


OpenUrl = Callable[..., Any]


class NoRedirectHandler(HTTPRedirectHandler):
    """Prevent redirects from forwarding the service key to another URL."""

    def redirect_request(
        self,
        req: Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> None:
        return None


def utc_now() -> datetime:
    return datetime.now(UTC)


def isoformat_utc(value: datetime) -> str:
    return value.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def load_dotenv(path: Path) -> dict[str, str]:
    """Read a small dotenv file without importing or executing its contents."""

    if not path.exists():
        raise ConfigurationError(f"환경변수 파일을 찾을 수 없습니다: {path}")

    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8-sig").splitlines(), start=1
    ):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise ConfigurationError(
                f"{path}:{line_number} 형식이 KEY=VALUE가 아닙니다."
            )
        name, value = line.split("=", 1)
        name = name.strip()
        value = value.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            raise ConfigurationError(f"{path}:{line_number} 환경변수 이름이 잘못되었습니다.")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        values[name] = value
    return values


def normalize_endpoint(endpoint: str) -> str:
    """Validate the allowlisted MFDS endpoint and expand its service base URL."""

    candidate = endpoint.strip().rstrip("/")
    if not candidate:
        raise ConfigurationError("MFDS_EASY_DRUG_API_ENDPOINT가 비어 있습니다.")

    parsed = urlsplit(candidate)
    if parsed.scheme != "https":
        raise ConfigurationError("e약은요 API는 HTTPS 엔드포인트만 허용합니다.")
    if parsed.hostname != ALLOWED_HOST:
        raise ConfigurationError(
            f"인증키 보호를 위해 공식 호스트 {ALLOWED_HOST}만 허용합니다."
        )
    if parsed.username or parsed.password or parsed.port is not None:
        raise ConfigurationError("엔드포인트의 사용자정보 또는 명시적 포트는 허용하지 않습니다.")
    if parsed.query or parsed.fragment:
        raise ConfigurationError("엔드포인트에는 query string이나 fragment를 넣지 마세요.")

    path = parsed.path.rstrip("/")
    if path == SERVICE_BASE_PATH:
        path = LIST_ENDPOINT_PATH
    if path != LIST_ENDPOINT_PATH:
        raise ConfigurationError(
            "e약은요 목록 엔드포인트 경로가 아닙니다. "
            f"예상 경로: {LIST_ENDPOINT_PATH}"
        )

    return urlunsplit(("https", ALLOWED_HOST, path, "", ""))


def build_request_url(
    endpoint: str,
    service_key: str,
    *,
    page_no: int,
    num_rows: int,
    filters: Mapping[str, str],
) -> str:
    """Build a request URL while decoding and encoding the service key once."""

    if not service_key.strip():
        raise ConfigurationError("MFDS_EASY_DRUG_SERVICE_KEY가 비어 있습니다.")
    if page_no < 1:
        raise ConfigurationError("pageNo는 1 이상이어야 합니다.")
    if not 1 <= num_rows <= 999:
        raise ConfigurationError("numOfRows는 1~999 범위여야 합니다.")

    # data.go.kr exposes encoded and decoded keys. Decode percent escapes once,
    # then let urlencode produce one canonical encoding for either form.
    decoded_key = unquote(service_key.strip())
    parameters: dict[str, str | int] = {
        "ServiceKey": decoded_key,
        "pageNo": page_no,
        "numOfRows": num_rows,
        "type": "json",
    }
    for name, value in filters.items():
        if name not in FILTER_PARAMETER_NAMES.values():
            raise ConfigurationError(f"허용되지 않은 API 필터입니다: {name}")
        if value:
            parameters[name] = value
    return f"{endpoint}?{urlencode(parameters)}"


def _as_int(value: Any, fallback: int, field_name: str) -> int:
    if value is None or value == "":
        return fallback
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise ApiResponseError("INVALID_RESPONSE", f"{field_name}가 정수가 아닙니다.") from exc


def _count_items(items: Any) -> int:
    if items is None or items == "":
        return 0
    if isinstance(items, list):
        if not all(isinstance(item, dict) for item in items):
            raise ApiResponseError("INVALID_RESPONSE", "items 배열 형식이 잘못되었습니다.")
        return len(items)
    if isinstance(items, dict):
        if "item" in items:
            item = items["item"]
            if item is None or item == "":
                return 0
            if isinstance(item, list):
                if not all(isinstance(entry, dict) for entry in item):
                    raise ApiResponseError(
                        "INVALID_RESPONSE", "items.item 배열 형식이 잘못되었습니다."
                    )
                return len(item)
            if isinstance(item, dict):
                return 1
            raise ApiResponseError("INVALID_RESPONSE", "items.item 형식이 잘못되었습니다.")
        # Some JSON variants return one item object directly.
        if "itemSeq" in items or "itemName" in items:
            return 1
    raise ApiResponseError("INVALID_RESPONSE", "items 형식을 인식할 수 없습니다.")


def _extract_xml_error(payload: bytes) -> tuple[str, str] | None:
    try:
        root = ElementTree.fromstring(payload)
    except ElementTree.ParseError:
        return None

    def first_text(names: Sequence[str]) -> str | None:
        for name in names:
            node = root.find(f".//{name}")
            if node is not None and node.text:
                return node.text.strip()
        return None

    code = first_text(("resultCode", "returnReasonCode", "errCd"))
    message = first_text(("resultMsg", "returnAuthMsg", "errMsg"))
    if code or message:
        return code or "NON_JSON_RESPONSE", message or "API가 XML 오류를 반환했습니다."
    return None


def parse_page_payload(
    payload: bytes,
    *,
    requested_page_no: int,
    requested_num_rows: int,
    http_status: int,
    content_type: str,
) -> PageResult:
    """Parse and validate one JSON page without modifying its raw bytes."""

    try:
        document = json.loads(payload.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        xml_error = _extract_xml_error(payload)
        if xml_error:
            raise ApiResponseError(*xml_error) from None
        raise ApiResponseError(
            "INVALID_RESPONSE", "JSON으로 해석할 수 없는 응답을 받았습니다."
        ) from exc

    if not isinstance(document, dict):
        raise ApiResponseError("INVALID_RESPONSE", "최상위 JSON 객체가 아닙니다.")
    response = document.get("response", document)
    if not isinstance(response, dict):
        raise ApiResponseError("INVALID_RESPONSE", "response 객체 형식이 잘못되었습니다.")

    header = response.get("header", document.get("header"))
    body = response.get("body", document.get("body"))
    if not isinstance(header, dict):
        raise ApiResponseError("INVALID_RESPONSE", "header 객체가 없습니다.")

    result_code = str(header.get("resultCode", "")).strip()
    result_message = str(header.get("resultMsg", "")).strip() or "메시지 없음"
    if result_code not in {"00", "0"}:
        raise ApiResponseError(result_code or "UNKNOWN", result_message)
    if not isinstance(body, dict):
        raise ApiResponseError("INVALID_RESPONSE", "body 객체가 없습니다.")

    page_no = _as_int(body.get("pageNo"), requested_page_no, "pageNo")
    num_rows = _as_int(body.get("numOfRows"), requested_num_rows, "numOfRows")
    total_count = _as_int(body.get("totalCount"), 0, "totalCount")
    if page_no != requested_page_no:
        raise ApiResponseError(
            "INVALID_RESPONSE",
            f"요청 pageNo={requested_page_no}와 응답 pageNo={page_no}가 다릅니다.",
        )
    if total_count < 0:
        raise ApiResponseError("INVALID_RESPONSE", "totalCount가 음수입니다.")

    item_count = _count_items(body.get("items"))
    return PageResult(
        raw_bytes=payload,
        result_code="00",
        result_message=result_message,
        page_no=page_no,
        num_rows=num_rows,
        total_count=total_count,
        item_count=item_count,
        http_status=http_status,
        content_type=content_type,
    )


def _sanitize_error_text(text: str, service_key: str) -> str:
    redacted = text
    candidates = {
        service_key,
        unquote(service_key),
    }
    for candidate in candidates:
        if candidate:
            redacted = redacted.replace(candidate, "[REDACTED]")
    return re.sub(
        r"(?i)(ServiceKey=)[^&\s]+",
        r"\1[REDACTED]",
        redacted,
    )


def _http_error_details(payload: bytes) -> tuple[str, str] | None:
    try:
        document = json.loads(payload.decode("utf-8-sig"))
        response = document.get("response", document) if isinstance(document, dict) else {}
        header = response.get("header", {}) if isinstance(response, dict) else {}
        if isinstance(header, dict) and (header.get("resultCode") or header.get("resultMsg")):
            return (
                str(header.get("resultCode", "HTTP_ERROR")),
                str(header.get("resultMsg", "HTTP 요청 실패")),
            )
    except (UnicodeDecodeError, json.JSONDecodeError):
        pass
    return _extract_xml_error(payload)


def _default_open(request: Request, *, timeout: float) -> Any:
    opener = build_opener(NoRedirectHandler())
    return opener.open(request, timeout=timeout)


def fetch_page(
    endpoint: str,
    service_key: str,
    *,
    page_no: int,
    num_rows: int,
    filters: Mapping[str, str],
    timeout_seconds: float,
    retries: int,
    opener: OpenUrl = _default_open,
) -> PageResult:
    """Fetch one page with bounded retries and sanitized failures."""

    request_url = build_request_url(
        endpoint,
        service_key,
        page_no=page_no,
        num_rows=num_rows,
        filters=filters,
    )
    request = Request(
        request_url,
        headers={
            "Accept": "application/json",
            "User-Agent": f"care-app-mfds-snapshot/{SCRIPT_VERSION}",
        },
        method="GET",
    )

    for attempt in range(retries + 1):
        try:
            with opener(request, timeout=timeout_seconds) as response:
                payload = response.read()
                status = int(getattr(response, "status", 200))
                headers = getattr(response, "headers", {})
                content_type = headers.get("Content-Type", "") if headers else ""
            try:
                return parse_page_payload(
                    payload,
                    requested_page_no=page_no,
                    requested_num_rows=num_rows,
                    http_status=status,
                    content_type=content_type,
                )
            except ApiResponseError as exc:
                if exc.result_code in RETRYABLE_API_CODES and attempt < retries:
                    time.sleep(min(2**attempt, 8))
                    continue
                raise
        except HTTPError as exc:
            try:
                payload = exc.read()
            except OSError:
                payload = b""
            details = _http_error_details(payload)
            retryable = exc.code == 429 or 500 <= exc.code <= 599
            if retryable and attempt < retries:
                time.sleep(min(2**attempt, 8))
                continue
            if details:
                raise ApiResponseError(*details) from None
            raise DownloaderError(f"HTTP {exc.code}: API 요청에 실패했습니다.") from None
        except (TimeoutError, URLError, OSError) as exc:
            if attempt < retries:
                time.sleep(min(2**attempt, 8))
                continue
            detail = _sanitize_error_text(str(exc), service_key)
            raise DownloaderError(f"API 연결에 실패했습니다: {detail}") from None

    raise DownloaderError("재시도 횟수를 모두 사용했습니다.")


def write_bytes_atomic(path: Path, content: bytes) -> None:
    """Write a new file atomically and never replace an existing raw file."""

    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(f"기존 파일을 덮어쓸 수 없습니다: {path}")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with temporary.open("xb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        if path.exists():
            raise FileExistsError(f"기존 파일을 덮어쓸 수 없습니다: {path}")
        temporary.replace(path)
    finally:
        if temporary.exists():
            temporary.unlink()


def build_manifest(
    *,
    snapshot_id: str,
    endpoint: str,
    request_parameters: Mapping[str, Any],
    pages: Sequence[tuple[str, PageResult]],
    started_at: str,
    completed_at: str,
    mode: str,
    complete: bool,
) -> dict[str, Any]:
    """Build provenance metadata without including credentials or keyed URLs."""

    safe_parameters = {
        key: value
        for key, value in request_parameters.items()
        if key.lower() != "servicekey"
    }
    page_entries = []
    for filename, page in pages:
        page_entries.append(
            {
                "file": filename,
                "sha256": hashlib.sha256(page.raw_bytes).hexdigest(),
                "bytes": len(page.raw_bytes),
                "http_status": page.http_status,
                "content_type": page.content_type,
                "result_code": page.result_code,
                "page_no": page.page_no,
                "num_rows": page.num_rows,
                "item_count": page.item_count,
                "total_count": page.total_count,
            }
        )

    return {
        "schema_version": "1.0",
        "snapshot_id": snapshot_id,
        "approval_state": "raw_unreviewed",
        "source": {
            "title": "식품의약품안전처_의약품개요정보(e약은요)",
            "provider": "식품의약품안전처",
            "data_go_kr_dataset_id": DATASET_ID,
            "catalog_url": DATASET_PAGE_URL,
            "endpoint": endpoint,
        },
        "collector": {
            "script": "scripts/fetch_mfds_easy_drug.py",
            "version": SCRIPT_VERSION,
        },
        "download": {
            "mode": mode,
            "complete": complete,
            "started_at": started_at,
            "completed_at": completed_at,
            "request_parameters_without_credentials": safe_parameters,
            "page_count": len(page_entries),
            "downloaded_item_count": sum(page.item_count for _, page in pages),
            "reported_total_count": pages[-1][1].total_count if pages else None,
            "pages": page_entries,
        },
        "handling": {
            "raw_response_modified": False,
            "patient_context_in_request": False,
            "credential_persisted": False,
            "runtime_rag_eligible": False,
        },
    }


def _manifest_bytes(manifest: Mapping[str, Any]) -> bytes:
    return (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def _snapshot_id(value: str | None) -> str:
    snapshot_id = value or utc_now().strftime("%Y%m%dT%H%M%SZ")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", snapshot_id):
        raise ConfigurationError(
            "snapshot-id는 영문자·숫자로 시작하고 영문자·숫자·점·밑줄·하이픈만 "
            "사용해야 합니다."
        )
    return snapshot_id


def _validate_cli_args(args: argparse.Namespace) -> None:
    if args.page_no < 1:
        raise ConfigurationError("--page-no는 1 이상이어야 합니다.")
    if not 1 <= args.num_rows <= 999:
        raise ConfigurationError("--num-rows는 1~999 범위여야 합니다.")
    if not 0 <= args.retries <= 10:
        raise ConfigurationError("--retries는 0~10 범위여야 합니다.")
    if not 1 <= args.max_pages <= 1000:
        raise ConfigurationError("--max-pages는 1~1000 범위여야 합니다.")
    if args.timeout_seconds <= 0:
        raise ConfigurationError("--timeout-seconds는 0보다 커야 합니다.")
    if args.delay_seconds < 0:
        raise ConfigurationError("--delay-seconds는 0 이상이어야 합니다.")


def _resolve_configuration(args: argparse.Namespace) -> tuple[str, str]:
    dotenv = load_dotenv(args.env_file)
    service_key = os.environ.get(
        "MFDS_EASY_DRUG_SERVICE_KEY", dotenv.get("MFDS_EASY_DRUG_SERVICE_KEY", "")
    ).strip()
    endpoint_value = os.environ.get(
        "MFDS_EASY_DRUG_API_ENDPOINT",
        dotenv.get("MFDS_EASY_DRUG_API_ENDPOINT", DEFAULT_ENDPOINT),
    ).strip()
    if not service_key:
        raise ConfigurationError("MFDS_EASY_DRUG_SERVICE_KEY가 설정되지 않았습니다.")
    return service_key, normalize_endpoint(endpoint_value)


def _filters_from_args(args: argparse.Namespace) -> dict[str, str]:
    filters: dict[str, str] = {}
    for argument_name, api_name in FILTER_PARAMETER_NAMES.items():
        value = getattr(args, argument_name)
        if value:
            filters[api_name] = value
    return filters


def download(args: argparse.Namespace) -> Path:
    _validate_cli_args(args)
    service_key, endpoint = _resolve_configuration(args)
    filters = _filters_from_args(args)
    snapshot_id = _snapshot_id(args.snapshot_id)
    snapshot_dir = args.output_root / snapshot_id
    mode = "all_pages" if args.all_pages else "single_page"

    if args.dry_run:
        print("설정 검증 성공")
        print(f"endpoint: {endpoint}")
        print(f"mode: {mode}")
        print(f"pageNo: {args.page_no}")
        print(f"numOfRows: {args.num_rows}")
        print(f"filter fields: {', '.join(sorted(filters)) if filters else 'none'}")
        print(f"output: {snapshot_dir}")
        print("service key: configured (value hidden)")
        return snapshot_dir

    if snapshot_dir.exists():
        raise ConfigurationError(f"스냅샷 경로가 이미 존재합니다: {snapshot_dir}")

    started = isoformat_utc(utc_now())
    pages: list[tuple[str, PageResult]] = []
    current_page = args.page_no
    complete = False

    try:
        for page_index in range(args.max_pages):
            result = fetch_page(
                endpoint,
                service_key,
                page_no=current_page,
                num_rows=args.num_rows,
                filters=filters,
                timeout_seconds=args.timeout_seconds,
                retries=args.retries,
            )
            if not snapshot_dir.exists():
                snapshot_dir.mkdir(parents=True, exist_ok=False)

            filename = f"page-{current_page:05d}.json"
            write_bytes_atomic(snapshot_dir / filename, result.raw_bytes)
            pages.append((filename, result))
            print(
                f"page {current_page}: {result.item_count} items "
                f"(reported total {result.total_count})"
            )

            consumed_through = (current_page - 1) * result.num_rows + result.item_count
            reached_end = result.item_count == 0 or consumed_through >= result.total_count
            if not args.all_pages:
                complete = reached_end
                break
            if reached_end:
                complete = True
                break

            current_page += 1
            if args.delay_seconds:
                time.sleep(args.delay_seconds)
        else:
            raise DownloaderError(
                "--max-pages에 도달했지만 totalCount 기준으로 다운로드가 끝나지 않았습니다."
            )
    except Exception:
        if pages and snapshot_dir.exists():
            partial_manifest = build_manifest(
                snapshot_id=snapshot_id,
                endpoint=endpoint,
                request_parameters={
                    "pageNo": args.page_no,
                    "numOfRows": args.num_rows,
                    "type": "json",
                    **filters,
                },
                pages=pages,
                started_at=started,
                completed_at=isoformat_utc(utc_now()),
                mode=f"{mode}_partial",
                complete=False,
            )
            write_bytes_atomic(
                snapshot_dir / "manifest.partial.json",
                _manifest_bytes(partial_manifest),
            )
        raise

    completed = isoformat_utc(utc_now())
    manifest = build_manifest(
        snapshot_id=snapshot_id,
        endpoint=endpoint,
        request_parameters={
            "pageNo": args.page_no,
            "numOfRows": args.num_rows,
            "type": "json",
            **filters,
        },
        pages=pages,
        started_at=started,
        completed_at=completed,
        mode=mode,
        complete=complete,
    )
    write_bytes_atomic(snapshot_dir / "manifest.json", _manifest_bytes(manifest))
    return snapshot_dir


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "식약처 e약은요 OpenAPI 응답을 변경 없이 raw snapshot으로 저장합니다. "
            "기본값은 page 1의 10건만 받습니다."
        )
    )
    parser.add_argument("--env-file", type=Path, default=Path(".env"))
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument("--snapshot-id")
    parser.add_argument("--page-no", type=int, default=1)
    parser.add_argument("--num-rows", type=int, default=10)
    parser.add_argument("--all-pages", action="store_true")
    parser.add_argument("--max-pages", type=int, default=200)
    parser.add_argument("--timeout-seconds", type=float, default=30.0)
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument("--delay-seconds", type=float, default=0.25)
    parser.add_argument("--entp-name", help="공개 업체명 필터")
    parser.add_argument("--item-name", help="공개 제품명 필터")
    parser.add_argument("--item-seq", help="공개 품목기준코드 필터")
    parser.add_argument("--open-date", help="공개일자 필터")
    parser.add_argument("--update-date", help="수정일자 필터")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="인증키 값을 출력하지 않고 설정만 검증합니다. 네트워크와 파일 쓰기를 하지 않습니다.",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        snapshot_dir = download(args)
    except (DownloaderError, FileExistsError) as exc:
        print(f"오류: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("오류: 사용자 요청으로 다운로드를 중단했습니다.", file=sys.stderr)
        return 130

    if not args.dry_run:
        print(f"snapshot saved: {snapshot_dir}")
        print("approval state: raw_unreviewed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
