"""Small, content-addressed offline review packs. No clinical activation path."""
from __future__ import annotations

import hashlib
import json
import sqlite3
import zlib
from collections import OrderedDict
from pathlib import Path

from scripts.mfds_catalog import UNREVIEWED
from scripts.mfds_snapshot import file_digest, now, save_json

MAX_BLOCK = 16 * 1024 * 1024
STRING_CHUNK = 64 * 1024
SCHEMA = "care-knowledge-preview-v1"
PACKED_SCHEMA = "care-knowledge-preview-v2"
PACKED_LAYOUT = "field_values_delta_index_v1"
TABLES = {"metadata", "blobs", "sources", "drug_records", "document_pages", "page_assets",
          "document_search", "document_search_data", "document_search_idx",
          "document_search_docsize", "document_search_config"}
PACKED_TABLES = {"value_groups", "record_groups", "drug_lookup"}


class PackError(ValueError):
    pass


def canonical(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def unpack_blob(payload: bytes, expected: int, checksum: str) -> bytes:
    if not 0 <= expected <= MAX_BLOCK or len(payload) > MAX_BLOCK:
        raise PackError("Block size limit exceeded")
    decoder = zlib.decompressobj()
    raw = decoder.decompress(payload, expected + 1)
    if (len(raw) != expected or not decoder.eof or decoder.unused_data
            or decoder.unconsumed_tail or sha(raw) != checksum):
        raise PackError("Compressed block integrity mismatch")
    return raw


def open_readonly(path: Path) -> sqlite3.Connection:
    db = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA trusted_schema=OFF")
    db.execute("PRAGMA query_only=ON")
    return db


class PackWriter:
    def __init__(self, output: Path, kind: str, *, packed: bool = False):
        output.mkdir(parents=True, exist_ok=False)
        self.output = output
        self.kind = kind
        self.packed = packed
        self.db = sqlite3.connect(output / "knowledge.sqlite3")
        self.db.execute("PRAGMA trusted_schema=OFF")
        self.db.execute("PRAGMA cache_size=-32768")
        self.db.executescript("""
          CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
          CREATE TABLE blobs(id INTEGER PRIMARY KEY, sha256 TEXT UNIQUE NOT NULL,
            raw_size INTEGER NOT NULL, payload BLOB NOT NULL);
          CREATE TABLE sources(id TEXT PRIMARY KEY, metadata TEXT NOT NULL);
          CREATE TABLE drug_records(id INTEGER PRIMARY KEY, source_id TEXT NOT NULL,
            item_seq TEXT NOT NULL, counterpart_seq TEXT NOT NULL, item_name TEXT NOT NULL,
            page_no INTEGER NOT NULL, row_no INTEGER NOT NULL,
            left_blob INTEGER NOT NULL, right_blob INTEGER NOT NULL, rest_blob INTEGER NOT NULL,
            record_sha256 TEXT NOT NULL);
          CREATE TABLE document_pages(id INTEGER PRIMARY KEY, source_id TEXT NOT NULL,
            page_no INTEGER NOT NULL, label TEXT NOT NULL, text_blob INTEGER NOT NULL,
            image_blob INTEGER, text_sha256 TEXT NOT NULL, UNIQUE(source_id,page_no));
          CREATE VIRTUAL TABLE document_search USING fts5(text,content='');
          CREATE TABLE page_assets(page_id INTEGER NOT NULL, ordinal INTEGER NOT NULL,
            blob_id INTEGER NOT NULL, description TEXT NOT NULL, PRIMARY KEY(page_id,ordinal));
        """)
        self.cache: OrderedDict[str, int] = OrderedDict()
        self.stats = {"input_bytes": 0, "records": 0, "pages": 0, "assets": 0,
                      "roundtrip_verified_records": 0}

    def add_blob(self, raw: bytes) -> int:
        if len(raw) > MAX_BLOCK:
            raise PackError("Split content into bounded blocks before storing")
        checksum = sha(raw)
        if checksum in self.cache:
            self.cache.move_to_end(checksum)
            return self.cache[checksum]
        row = self.db.execute("SELECT id FROM blobs WHERE sha256=?", (checksum,)).fetchone()
        if row:
            identifier = row[0]
        else:
            payload = zlib.compress(raw, 6)
            if unpack_blob(payload, len(raw), checksum) != raw:
                raise PackError("Compression roundtrip failed")
            identifier = self.db.execute("INSERT INTO blobs(sha256,raw_size,payload) VALUES (?,?,?)",
                                         (checksum, len(raw), payload)).lastrowid
        self.cache[checksum] = identifier
        if len(self.cache) > 100_000:
            self.cache.popitem(last=False)
        return identifier

    def source(self, identifier: str, metadata: dict) -> None:
        self.db.execute("INSERT INTO sources VALUES (?,?)", (identifier, canonical(metadata).decode()))

    def fragment(self, fields: dict) -> int:
        encoded = []
        for key, value in sorted(fields.items()):
            if isinstance(value, str) and len(value.encode("utf-8")) >= 160:
                raw = value.encode("utf-8")
                refs = [self.add_blob(raw[i:i + STRING_CHUNK]) for i in range(0, len(raw), STRING_CHUNK)]
                encoded.append([key, 1, refs])
            else:
                encoded.append([key, 0, value])
        return self.add_blob(canonical(encoded))

    def finish(self, extra: dict | None = None) -> dict:
        protected = {"schema", "purpose", "kind", "created_at", "codec", "max_block_bytes", "packed_layout", *UNREVIEWED}
        if extra and protected.intersection(extra):
            raise PackError("Package safety metadata cannot be overridden")
        self.db.executescript("""
          CREATE INDEX drug_item ON drug_records(item_seq);
          CREATE INDEX drug_counterpart ON drug_records(counterpart_seq);
          CREATE INDEX drug_name ON drug_records(item_name);
          CREATE INDEX document_source ON document_pages(source_id,page_no);
        """)
        metadata = {"schema": PACKED_SCHEMA if self.packed else SCHEMA, "purpose": "development_preview", **UNREVIEWED,
                    "kind": self.kind, "created_at": now(), "codec": "zlib",
                    "max_block_bytes": MAX_BLOCK, **(extra or {})}
        if self.packed:
            metadata["packed_layout"] = PACKED_LAYOUT
        self.db.execute("INSERT INTO metadata VALUES ('package',?)", (canonical(metadata).decode(),))
        self.db.commit()
        if self.db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise PackError("SQLite integrity failure")
        self.stats["unique_blocks"] = self.db.execute("SELECT count(*) FROM blobs").fetchone()[0]
        self.db.close()
        self.cache.clear()
        manifest = {**metadata, "database": "knowledge.sqlite3",
                    "database_bytes": (self.output / "knowledge.sqlite3").stat().st_size,
                    "database_sha256": file_digest(self.output / "knowledge.sqlite3"),
                    "stats": self.stats}
        save_json(self.output / "manifest.json", manifest)
        return manifest

    def close(self):
        self.db.close()


class PackReader:
    def __init__(self, directory: Path, *, expected_hash: str | None = None):
        manifest_path = directory / "manifest.json"
        if manifest_path.stat().st_size > 1024 * 1024:
            raise PackError("Package manifest size limit exceeded")
        m = json.loads(manifest_path.read_text(encoding="utf-8"))
        if (m.get("schema") not in (SCHEMA, PACKED_SCHEMA) or m.get("purpose") != "development_preview"
                or m.get("database") != "knowledge.sqlite3"
                or m.get("codec") != "zlib" or m.get("max_block_bytes") != MAX_BLOCK
                or m.get("kind") not in ("documents", "drugs")
                or (m.get("schema") == PACKED_SCHEMA and m.get("packed_layout") != PACKED_LAYOUT)
                or any(m.get(k) != v for k, v in UNREVIEWED.items())):
            raise PackError("Unsupported package or clinical status")
        path = directory / "knowledge.sqlite3"
        if (path.stat().st_size != m["database_bytes"]
                or file_digest(path) != m["database_sha256"]
                or (expected_hash and expected_hash != m["database_sha256"])):
            raise PackError("Package version or checksum mismatch")
        self.db = open_readonly(path)
        self.manifest = m
        try:
            schema = self.db.execute("SELECT name,type FROM sqlite_schema WHERE type IN ('table','view','trigger')").fetchall()
            expected_tables = TABLES | (PACKED_TABLES if m["schema"] == PACKED_SCHEMA else set())
            if {row["name"] for row in schema} != expected_tables or any(row["type"] != "table" for row in schema):
                raise PackError("Unsupported SQLite schema")
            internal = json.loads(self.db.execute("SELECT value FROM metadata WHERE key='package'").fetchone()[0])
            required = {"schema", "purpose", "kind", "codec", "max_block_bytes", *UNREVIEWED}
            if not required.issubset(internal) or any(m.get(k) != v for k, v in internal.items()):
                raise PackError("Package metadata mismatch")
        except Exception:
            self.db.close()
            raise

    def blob(self, identifier: int) -> bytes:
        sizes = self.db.execute("SELECT raw_size,length(payload) FROM blobs WHERE id=?", (identifier,)).fetchone()
        if sizes is None or not 0 <= sizes[0] <= MAX_BLOCK or sizes[1] > MAX_BLOCK:
            raise PackError("Missing or oversized content block")
        row = self.db.execute("SELECT * FROM blobs WHERE id=?", (identifier,)).fetchone()
        if row is None:
            raise PackError("Missing content block")
        return unpack_blob(row["payload"], row["raw_size"], row["sha256"])

    def drug(self, identifier: int) -> dict:
        if self.manifest["schema"] == PACKED_SCHEMA:
            from scripts.packed_drugs import PackedDrugReader
            return PackedDrugReader(self.db, self.blob).record(identifier)["record"]
        row = self.db.execute("SELECT * FROM drug_records WHERE id=?", (identifier,)).fetchone()
        if row is None:
            raise PackError("Missing drug record")
        record = restore_record(row, self.blob)
        if sha(canonical(record)) != row["record_sha256"]:
            raise PackError("Drug record checksum mismatch")
        return record

    def lookup(self, item_seq: str, limit: int = 20) -> list[dict]:
        if not 1 <= limit <= 100:
            raise PackError("Invalid query limit")
        if self.manifest["schema"] == PACKED_SCHEMA:
            from scripts.packed_drugs import PackedDrugReader
            return PackedDrugReader(self.db, self.blob).lookup(item_seq, limit)
        return [dict(r) for r in self.db.execute(
            "SELECT id,source_id,item_seq,counterpart_seq,page_no,row_no FROM drug_records "
            "WHERE item_seq=? OR counterpart_seq=? ORDER BY id LIMIT ?", (item_seq, item_seq, limit))]

    def clinical_context(self, *_):
        raise PackError("Clinical use is blocked: this package is unreviewed")

    def close(self):
        self.db.close()


def restore_record(row, blob_reader) -> dict:
    record = {}
    total = 0
    for field in ("left_blob", "right_blob", "rest_blob"):
        for key, mode, value in json.loads(blob_reader(row[field])):
            if key in record or mode not in (0, 1):
                raise PackError("Ambiguous fragment")
            if mode == 1:
                if not isinstance(value, list) or len(value) > 2048:
                    raise PackError("Invalid fragment size")
                parts = []
                for identifier in value:
                    part = blob_reader(identifier)
                    total += len(part)
                    if total > MAX_BLOCK:
                        raise PackError("Record size limit exceeded")
                    parts.append(part)
                value = b"".join(parts).decode("utf-8")
            record[key] = value
    return record
