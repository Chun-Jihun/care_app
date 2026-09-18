"""Normalize and compress MFDS data without losing any original field or relationship."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.knowledge_pack import PackError, PackWriter, canonical, open_readonly, restore_record, sha, unpack_blob
from scripts.mfds_local_store import verify_index
from scripts.mfds_snapshot import read_manifest

PRODUCT_FIELDS = frozenset({"ITEM_SEQ", "ITEM_NAME", "ENTP_NAME", "CHART", "FORM_CODE",
                           "ETC_OTC_CODE", "CLASS_CODE", "FORM_NAME", "ETC_OTC_NAME",
                           "CLASS_NAME", "MAIN_INGR", "ITEM_PERMIT_DATE", "CHANGE_DATE"})


def add_record(writer: PackWriter, source: str, record: dict, page_no: int, row_no: int) -> None:
    left = {k: v for k, v in record.items() if k in PRODUCT_FIELDS}
    right = {k: v for k, v in record.items() if k.startswith("MIXTURE_")}
    rest = {k: v for k, v in record.items() if k not in left and k not in right}
    refs = dict(zip(("left_blob", "right_blob", "rest_blob"), map(writer.fragment, (left, right, rest))))
    # Verify the persisted representation, not just the in-memory encoder.
    def read_blob(i):
        b = writer.db.execute("SELECT payload,raw_size,sha256 FROM blobs WHERE id=?", (i,)).fetchone()
        return unpack_blob(*b)
    restored = restore_record(refs, read_blob)
    if restored != record:
        raise PackError("Original drug fields were changed")
    raw = canonical(record)
    writer.db.execute("""INSERT INTO drug_records(source_id,item_seq,counterpart_seq,item_name,
        page_no,row_no,left_blob,right_blob,rest_blob,record_sha256) VALUES (?,?,?,?,?,?,?,?,?,?)""",
        (source, str(record.get("ITEM_SEQ") or record.get("itemSeq") or ""),
         str(record.get("MIXTURE_ITEM_SEQ") or ""),
         str(record.get("ITEM_NAME") or record.get("PRDUCT") or record.get("itemName") or ""),
         page_no, row_no, refs["left_blob"], refs["right_blob"], refs["rest_blob"], sha(raw)))
    writer.stats["input_bytes"] += len(raw)
    writer.stats["records"] += 1
    writer.stats["roundtrip_verified_records"] += 1


def build(snapshot: Path, output: Path) -> dict:
    index = verify_index(snapshot)
    manifest = read_manifest(snapshot)
    writer = PackWriter(output, "drugs")
    source = open_readonly(snapshot / "catalog.sqlite3")
    try:
        for operation in manifest["operations"]:
            identifier = manifest["service"] + "/" + operation
            writer.source(identifier, {
                "title": manifest["source_title"], "publisher": manifest["publisher"],
                "url": manifest["catalog_url"], "operation": operation,
                "snapshot_id": manifest["snapshot_id"],
                "source_manifest_sha256": index["source_manifest_sha256"],
                "collected_at": manifest["completed_at"], "clinical_reviewed_at": None,
                "pages": manifest["operations"][operation]["pages"],
            })
        for row in source.execute("SELECT * FROM records ORDER BY operation,page_no,row_no"):
            if sha(row["payload"].encode()) != row["payload_sha256"]:
                raise PackError("Input record checksum mismatch")
            add_record(writer, manifest["service"] + "/" + row["operation"],
                       json.loads(row["payload"]), row["page_no"], row["row_no"])
            if writer.stats["records"] % 10000 == 0:
                writer.db.commit()
                print(f"{manifest['service']}: {writer.stats['records']}/{index['record_count']} verified", flush=True)
        if writer.stats["records"] != index["record_count"]:
            raise PackError("Record count mismatch")
        return writer.finish({"input_snapshot": manifest["snapshot_id"],
                              "input_database_sha256": index["database_sha256"]})
    finally:
        source.close()
        writer.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = build(args.snapshot, args.output)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
