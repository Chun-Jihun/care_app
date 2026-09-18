"""Offline review index. This is not an approved medical knowledge base."""
from __future__ import annotations

import json
import sqlite3
import uuid
from pathlib import Path

from scripts.fetch_mfds_easy_drug import DownloaderError
from scripts.mfds_catalog import UNREVIEWED
from scripts.mfds_snapshot import (
    digest, file_digest, items_from, now, read_manifest, save_json, verified_pages,
)


def build_index(snapshot: Path) -> Path:
    manifest = read_manifest(snapshot)
    manifest_hash = file_digest(snapshot / "manifest.json")
    destination = snapshot / "catalog.sqlite3"
    if destination.exists():
        verify_index(snapshot)
        return destination
    temporary = snapshot / f".catalog-{uuid.uuid4().hex}.sqlite3"
    count = 0
    connection = sqlite3.connect(temporary)
    try:
        connection.execute("PRAGMA trusted_schema=OFF")
        connection.executescript("""
            CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE records (
                operation TEXT NOT NULL, page_no INTEGER NOT NULL,
                row_no INTEGER NOT NULL, item_seq TEXT NOT NULL,
                counterpart_item_seq TEXT, item_name TEXT,
                payload TEXT NOT NULL, payload_sha256 TEXT NOT NULL,
                PRIMARY KEY(operation, page_no, row_no)
            );
        """)
        for op, entry, page in verified_pages(snapshot, manifest):
            batch = []
            for row_no, item in enumerate(items_from(page), 1):
                payload = json.dumps(item, ensure_ascii=False, sort_keys=True)
                batch.append((op, entry["page_no"], row_no, str(item["ITEM_SEQ"]),
                              str(item.get("MIXTURE_ITEM_SEQ") or ""),
                              str(item.get("ITEM_NAME") or item.get("PRDUCT") or ""),
                              payload, digest(payload.encode("utf-8"))))
            connection.executemany("INSERT INTO records VALUES (?,?,?,?,?,?,?,?)", batch)
            count += len(batch)
            if entry["page_no"] % 100 == 0:
                connection.commit()
        connection.executescript("""
            CREATE INDEX records_item_seq ON records(item_seq);
            CREATE INDEX records_counterpart ON records(counterpart_item_seq);
            CREATE INDEX records_item_name ON records(item_name);
        """)
        metadata = {**UNREVIEWED, "snapshot_id": manifest["snapshot_id"],
                    "service": manifest["service"], "record_count": count,
                    "source_manifest_sha256": manifest_hash}
        connection.executemany("INSERT INTO metadata VALUES (?,?)",
                               [(k, json.dumps(v)) for k, v in metadata.items()])
        connection.commit()
        if connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise DownloaderError("로컬 DB 무결성 검사 실패")
        connection.close()
        if file_digest(snapshot / "manifest.json") != manifest_hash:
            raise DownloaderError("DB 생성 중 원문 목록이 변경되었습니다.")
        index = {**metadata, "created_at": now(), "database": "catalog.sqlite3",
                 "database_sha256": file_digest(temporary)}
        # Publish metadata first. A crash here leaves no final DB, so rebuilding
        # is safe; publishing the DB first could strand an unverifiable DB.
        save_json(snapshot / "index.json", index)
        temporary.replace(destination)
        return destination
    finally:
        connection.close()
        temporary.unlink(missing_ok=True)


def verify_index(snapshot: Path) -> dict:
    manifest = read_manifest(snapshot)
    index = json.loads((snapshot / "index.json").read_text(encoding="utf-8"))
    if (index.get("database") != "catalog.sqlite3"
            or index.get("snapshot_id") != manifest["snapshot_id"]
            or index.get("source_manifest_sha256") != file_digest(snapshot / "manifest.json")
            or index.get("database_sha256") != file_digest(snapshot / "catalog.sqlite3")
            or any(index.get(k) != v for k, v in UNREVIEWED.items())):
        raise DownloaderError("로컬 DB·원문 목록의 무결성 또는 검수 상태가 다릅니다.")
    return index


def lookup(snapshot: Path, *, item_seq: str | None = None,
           name: str | None = None, limit: int = 20) -> dict:
    if bool(item_seq) == bool(name) or not 1 <= limit <= 100:
        raise DownloaderError("품목코드 또는 이름 중 하나와 조회 건수(1~100)를 지정하세요.")
    index = verify_index(snapshot)
    manifest = read_manifest(snapshot)
    connection = sqlite3.connect((snapshot / "catalog.sqlite3").resolve().as_uri() + "?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA trusted_schema=OFF")
        connection.execute("PRAGMA query_only=ON")
        if item_seq:
            where = "item_seq = ? OR counterpart_item_seq = ?"
            values = (item_seq, item_seq)
        else:
            # Literal substring search; '%' and '_' are not user-controlled wildcards.
            where = "instr(item_name, ?) > 0"
            values = (name,)
        rows = connection.execute(
            f"SELECT * FROM records WHERE {where} ORDER BY operation, page_no, row_no LIMIT ?",
            (*values, limit + 1),
        ).fetchall()
        result = []
        checked_pages = set()
        for row in rows[:limit]:
            payload = row["payload"]
            if digest(payload.encode("utf-8")) != row["payload_sha256"]:
                raise DownloaderError("조회 레코드 무결성 검사 실패")
            source_file = f"raw/{row['operation']}/page-{row['page_no']:05d}.json"
            source_page = manifest["operations"][row["operation"]]["pages"][row["page_no"] - 1]
            if source_file not in checked_pages:
                if (source_page["file"] != source_file
                        or file_digest(snapshot / source_file) != source_page["sha256"]):
                    raise DownloaderError("조회한 레코드의 출처 원문이 변경되었습니다.")
                checked_pages.add(source_file)
            result.append({"operation": row["operation"], "page_no": row["page_no"],
                           "row_no": row["row_no"], "source_file": source_file,
                           "fetched_at": source_page["fetched_at"],
                           "record": json.loads(payload)})
        return {**UNREVIEWED, "snapshot_id": index["snapshot_id"],
                "source_manifest_sha256": index["source_manifest_sha256"],
                "source": {"title": manifest["source_title"], "publisher": manifest["publisher"],
                           "catalog_url": manifest["catalog_url"], "endpoint": manifest["endpoint"],
                           "collected_at": manifest["completed_at"], "clinical_reviewed_at": None},
                "network_used": False, "has_more": len(rows) > limit, "records": result,
                "notice": "검수 전 원문 조회입니다. 결과 없음은 병용 가능 또는 안전함을 의미하지 않습니다."}
    finally:
        connection.close()
