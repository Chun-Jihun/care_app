"""Lossless, bounded groups with deduplicated values and compressed item indexes."""
from __future__ import annotations

import hashlib
import json
from collections import OrderedDict, defaultdict

from scripts.knowledge_pack import MAX_BLOCK, PackError, canonical, sha, unpack_blob

VALUES_PER_GROUP = 128
RECORDS_PER_GROUP = 512

def encode_ids(identifiers):
    result, previous = bytearray(), 0
    for identifier in identifiers:
        value = identifier - previous
        if value <= 0 or identifier > 0x7fffffff:
            raise PackError("Invalid index ordering")
        previous = identifier
        while value >= 128:
            result.append((value & 127) | 128)
            value >>= 7
        result.append(value)
    return bytes(result)


def decode_ids(raw):
    if len(raw) > MAX_BLOCK:
        raise PackError("Index too large")
    previous = value = shift = 0
    for byte in raw:
        value |= (byte & 127) << shift
        if byte & 128:
            shift += 7
            if shift > 28:
                raise PackError("Invalid delta encoding")
        else:
            if value <= 0 or previous + value > 0x7fffffff:
                raise PackError("Invalid delta index")
            previous += value
            yield previous
            value = shift = 0
    if shift:
        raise PackError("Truncated delta index")


class PackedDrugWriter:
    def __init__(self, writer):
        if not writer.packed or writer.kind != "drugs":
            raise PackError("Packed drug schema required")
        self.writer = writer
        writer.db.executescript("""
          CREATE TABLE value_groups(id INTEGER PRIMARY KEY, blob_id INTEGER NOT NULL);
          CREATE TABLE record_groups(id INTEGER PRIMARY KEY, source_id TEXT NOT NULL,
            first_record INTEGER UNIQUE NOT NULL, record_count INTEGER NOT NULL, blob_id INTEGER NOT NULL);
          CREATE TABLE drug_lookup(item_seq TEXT PRIMARY KEY, record_ids BLOB NOT NULL);
        """)
        self.interned = {}
        self.values = []
        self.value_count = 0
        self.groups = []
        self.source = None
        self.index = defaultdict(list)
        self.input_hash = hashlib.sha256()

    def _value(self, value):
        raw = canonical(value)
        key = sha(raw)
        if key in self.interned:
            return self.interned[key]
        self.value_count += 1
        self.interned[key] = self.value_count
        self.values.append(value)
        if len(self.values) == VALUES_PER_GROUP:
            self._flush_values()
        return self.value_count

    def _flush_values(self):
        if self.values:
            identifier = (self.value_count - 1) // VALUES_PER_GROUP + 1
            blob = self.writer.add_blob(canonical(self.values))
            self.writer.db.execute("INSERT INTO value_groups VALUES (?,?)", (identifier, blob))
            self.values.clear()

    def _flush_records(self):
        if self.groups:
            count = len(self.groups)
            first = self.writer.stats["records"] - count + 1
            blob = self.writer.add_blob(canonical(self.groups))
            self.writer.db.execute("INSERT INTO record_groups(source_id,first_record,record_count,blob_id) VALUES (?,?,?,?)",
                                   (self.source, first, count, blob))
            self.groups.clear()

    def add(self, source, record, page, row):
        raw = canonical([source, page, row, record])
        if len(raw) > MAX_BLOCK:
            raise PackError("Original record too large")
        if source != self.source:
            self._flush_records()
            self.source = source
        keys = sorted(record)
        refs = [self._value(record[key]) for key in keys]
        self.groups.append([page, row, self._value(keys), refs])
        self.input_hash.update(raw + b"\n")
        self.writer.stats["input_bytes"] += len(raw)
        self.writer.stats["records"] += 1
        identifier = self.writer.stats["records"]
        for item in {record.get("ITEM_SEQ") or record.get("itemSeq"), record.get("MIXTURE_ITEM_SEQ")}:
            if item is not None and str(item):
                self.index[str(item)].append(identifier)
        if len(self.groups) == RECORDS_PER_GROUP:
            self._flush_records()

    def finish(self):
        self._flush_values()
        self._flush_records()
        for item, identifiers in self.index.items():
            self.writer.db.execute("INSERT INTO drug_lookup VALUES (?,?)",
                                   (item, encode_ids(identifiers)))
        self.writer.db.commit()
        self.index.clear()
        self.interned.clear()
        self.writer.cache.clear()

        def read_blob(identifier):
            row = self.writer.db.execute("SELECT payload,raw_size,sha256 FROM blobs WHERE id=?", (identifier,)).fetchone()
            return unpack_blob(*row)

        reader = PackedDrugReader(self.writer.db, read_blob)
        output_hash = hashlib.sha256()
        count = 0
        for group in self.writer.db.execute("SELECT first_record,record_count FROM record_groups ORDER BY first_record"):
            for identifier in range(group[0], group[0] + group[1]):
                restored = reader.record(identifier)
                output_hash.update(canonical([restored["source_id"], restored["page_no"], restored["row_no"], restored["record"]]) + b"\n")
                count += 1
        if count != self.writer.stats["records"] or output_hash.digest() != self.input_hash.digest():
            raise PackError("Full packed record roundtrip mismatch")
        self.writer.stats["roundtrip_verified_records"] = count
        self.writer.stats["deduplicated_fragments"] = self.value_count
        self.writer.stats["record_stream_sha256"] = output_hash.hexdigest()


class PackedDrugReader:
    def __init__(self, db, blob):
        self.db, self.blob = db, blob
        self.cache = OrderedDict()
        self.cache_bytes = 0
        self.group = None

    def _value(self, identifier):
        if not isinstance(identifier, int) or identifier < 1:
            raise PackError("Invalid value reference")
        group, offset = divmod(identifier - 1, VALUES_PER_GROUP)
        group += 1
        if group not in self.cache:
            row = self.db.execute("SELECT blob_id FROM value_groups WHERE id=?", (group,)).fetchone()
            if row is None:
                raise PackError("Missing value group")
            raw = self.blob(row[0])
            values = json.loads(raw)
            if not isinstance(values, list) or not 1 <= len(values) <= VALUES_PER_GROUP:
                raise PackError("Invalid value group")
            self.cache[group] = (values, len(raw))
            self.cache_bytes += len(raw)
            while self.cache_bytes > 64 * 1024 * 1024 and len(self.cache) > 1:
                _, (_, size) = self.cache.popitem(last=False)
                self.cache_bytes -= size
        self.cache.move_to_end(group)
        values = self.cache[group][0]
        if offset >= len(values):
            raise PackError("Missing value")
        return values[offset]

    def record(self, identifier):
        if not isinstance(identifier, int) or identifier < 1:
            raise PackError("Invalid record reference")
        if self.group is None or not self.group[0] <= identifier < self.group[0] + len(self.group[2]):
            row = self.db.execute("SELECT first_record,source_id,record_count,blob_id FROM record_groups "
                                  "WHERE first_record<=? ORDER BY first_record DESC LIMIT 1", (identifier,)).fetchone()
            if row is None or not 1 <= row[2] <= RECORDS_PER_GROUP:
                raise PackError("Missing record group")
            rows = json.loads(self.blob(row[3]))
            if len(rows) != row[2] or identifier >= row[0] + len(rows):
                raise PackError("Invalid record group")
            self.group = (row[0], row[1], rows)
        row = self.group[2][identifier - self.group[0]]
        if not isinstance(row, list) or len(row) != 4:
            raise PackError("Invalid packed record")
        keys = self._value(row[2])
        if (not isinstance(keys, list) or any(not isinstance(key, str) for key in keys)
                or len(keys) != len(set(keys)) or len(keys) != len(row[3])):
            raise PackError("Ambiguous record keys")
        record = {key: self._value(ref) for key, ref in zip(keys, row[3])}
        if len(canonical(record)) > MAX_BLOCK:
            raise PackError("Restored record too large")
        return {"id": identifier, "source_id": self.group[1], "page_no": row[0], "row_no": row[1],
                "item_seq": str(record.get("ITEM_SEQ") or record.get("itemSeq") or ""),
                "counterpart_seq": str(record.get("MIXTURE_ITEM_SEQ") or ""), "record": record}

    def lookup(self, item, limit):
        sizes = self.db.execute("SELECT length(record_ids) FROM drug_lookup WHERE item_seq=?", (item,)).fetchone()
        if sizes is None:
            return []
        if sizes[0] > MAX_BLOCK:
            raise PackError("Item index too large")
        row = self.db.execute("SELECT record_ids FROM drug_lookup WHERE item_seq=?", (item,)).fetchone()
        if row is None:
            return []
        identifiers = []
        for identifier in decode_ids(row[0]):
            if len(identifiers) < limit:
                identifiers.append(identifier)
        result = []
        for identifier in identifiers:
            record = self.record(identifier)
            if item not in (record["item_seq"], record["counterpart_seq"]):
                raise PackError("Item index does not match original record")
            result.append({k: v for k, v in record.items() if k != "record"})
        return result
