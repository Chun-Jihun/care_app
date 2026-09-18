"""Build a size-limited, explicitly scoped offline review set from local sources."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.build_document_knowledge_pack import add_page
from scripts.knowledge_pack import PackError, PackReader, PackWriter, canonical, open_readonly, sha
from scripts.mfds_catalog import UNREVIEWED
from scripts.mfds_local_store import verify_index
from scripts.mfds_snapshot import file_digest, read_manifest, save_json
from scripts.mobile_core_policy import CORE_DOCUMENTS, CORE_SCOPE, NOTICES, PERMIT_BASIC, PERMIT_DROP, PERMIT_KEEP
from scripts.packed_drugs import PackedDrugWriter
from scripts.stage_mfds_easy_drug import load_verified_rows


def project_permit(record):
    unknown = record.keys() - PERMIT_KEEP - PERMIT_DROP
    if unknown or not record.get("ITEM_SEQ") or not record.get("ITEM_NAME"):
        raise PackError("Permit schema changed; review the explicit inclusion policy")
    return {k: v for k, v in record.items() if k in PERMIT_KEEP}


def build_mfds(snapshot, output, service):
    index = verify_index(snapshot)
    manifest = read_manifest(snapshot)
    if manifest["service"] != service:
        raise PackError("Wrong MFDS input service")
    writer = PackWriter(output, "drugs", packed=True)
    source = open_readonly(snapshot / "catalog.sqlite3")
    try:
        packed = PackedDrugWriter(writer)
        operations = list(manifest["operations"]) if service == "dur" else [PERMIT_BASIC]
        for operation in operations:
            writer.source(service + "/" + operation, {
                "title": manifest["source_title"], "publisher": manifest["publisher"],
                "url": manifest["catalog_url"], "operation": operation, "snapshot_id": manifest["snapshot_id"],
                "source_manifest_sha256": index["source_manifest_sha256"],
                "collected_at": manifest["completed_at"], "clinical_reviewed_at": None,
                "pages": manifest["operations"][operation]["pages"],
            })
            for row in source.execute("SELECT * FROM records WHERE operation=? ORDER BY item_seq,page_no,row_no", (operation,)):
                if sha(row["payload"].encode()) != row["payload_sha256"]:
                    raise PackError("Input record integrity mismatch")
                original = json.loads(row["payload"])
                record = original if service == "dur" else project_permit(original)
                packed.add(service + "/" + operation, record, row["page_no"], row["row_no"])
                if writer.stats["records"] % 100000 == 0:
                    writer.db.commit()
                    print(f"{service}: {writer.stats['records']} packed", flush=True)
        print(f"{service}: verifying every reconstructed record", flush=True)
        packed.finish()
        expected = source.execute("SELECT count(*) FROM records" if service == "dur" else
                                  "SELECT count(*) FROM records WHERE operation=?",
                                  () if service == "dur" else (PERMIT_BASIC,)).fetchone()[0]
        if expected != writer.stats["records"]:
            raise PackError("Source coverage count mismatch")
        return writer.finish({"input_snapshot": manifest["snapshot_id"], "input_database_sha256": index["database_sha256"],
                              "coverage": {**CORE_SCOPE, "notice_ko": NOTICES[service]},
                              "excluded_operations": [op for op in manifest["operations"] if op not in operations],
                              "excluded_fields": sorted(PERMIT_DROP) if service == "permits" else []})
    finally:
        source.close()
        writer.close()


def build_easy(snapshot, output):
    raw = (snapshot / "manifest.json").read_bytes()
    m = json.loads(raw)
    rows, _ = load_verified_rows(snapshot, m)
    pages = {p["file"]: p["page_no"] for p in m["download"]["pages"]}
    writer = PackWriter(output, "drugs", packed=True)
    try:
        packed = PackedDrugWriter(writer)
        writer.source("easy-drug", {"title": m["source"]["title"], "publisher": m["source"]["provider"],
                      "url": m["source"]["catalog_url"], "snapshot_id": m["snapshot_id"],
                      "source_manifest_sha256": sha(raw), "collected_at": m["download"]["completed_at"],
                      "clinical_reviewed_at": None, "pages": m["download"]["pages"]})
        for row in rows:
            # Remove only the product-photo URL and business registration ID.
            record = {k: v for k, v in row["item"].items() if k not in ("itemImage", "bizrno")}
            ref = row["source_ref"]
            packed.add("easy-drug", record, pages[ref["page_file"]], ref["item_index"])
        packed.finish()
        return writer.finish({"input_manifest_sha256": sha(raw), "excluded_fields": ["itemImage", "bizrno"],
                              "coverage": {**CORE_SCOPE, "notice_ko": NOTICES["easy-drug"]}})
    finally:
        writer.close()


def build_documents(full_pack, output):
    reader = PackReader(full_pack)
    writer = PackWriter(output, "documents")
    found, excluded = set(), []
    try:
        for row in reader.db.execute("SELECT id,metadata FROM sources"):
            metadata = json.loads(row["metadata"])
            name = Path(metadata["path"]).name
            if name not in CORE_DOCUMENTS:
                excluded.append({"source_id": row["id"], "name": name})
                continue
            found.add(name)
            writer.source(row["id"], metadata)
            for page in reader.db.execute("SELECT * FROM document_pages WHERE source_id=? ORDER BY page_no", (row["id"],)):
                text = reader.blob(page["text_blob"])
                if sha(text) != page["text_sha256"]:
                    raise PackError("Document text mismatch")
                image = reader.blob(page["image_blob"]) if page["image_blob"] else None
                identifier = add_page(writer, row["id"], page["page_no"], text.decode(), image)
                for asset in reader.db.execute("SELECT * FROM page_assets WHERE page_id=? ORDER BY ordinal", (page["id"],)):
                    raw = reader.blob(asset["blob_id"])
                    writer.db.execute("INSERT INTO page_assets VALUES (?,?,?,?)",
                                      (identifier, asset["ordinal"], writer.add_blob(raw), asset["description"]))
                    writer.stats["assets"] += 1
        if found != CORE_DOCUMENTS:
            raise PackError("A required caregiver document is missing")
        return writer.finish({"input_package_sha256": reader.manifest["database_sha256"],
                              "document_count": len(found), "excluded_documents": excluded,
                              "coverage": {**CORE_SCOPE, "notice_ko": NOTICES["documents"]}})
    finally:
        writer.close()
        reader.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--permits", type=Path, required=True)
    parser.add_argument("--dur", type=Path, required=True)
    parser.add_argument("--easy-drug", type=Path, required=True)
    parser.add_argument("--documents", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    packages = {}
    for key, build in (
        ("dur", lambda: build_mfds(args.dur, args.output / "dur", "dur")),
        ("permits", lambda: build_mfds(args.permits, args.output / "permits", "permits")),
        ("easy-drug", lambda: build_easy(args.easy_drug, args.output / "easy-drug")),
        ("documents", lambda: build_documents(args.documents, args.output / "documents")),
    ):
        m = build()
        packages[key] = {"directory": key, "database_sha256": m["database_sha256"],
                         "manifest_sha256": file_digest(args.output / key / "manifest.json"),
                         "database_bytes": m["database_bytes"], "stats": m["stats"]}
        print(key, m["database_bytes"], "bytes", flush=True)
    total = sum(p.stat().st_size for p in args.output.rglob('*') if p.is_file())
    if total + 32768 > CORE_SCOPE["max_total_bytes"]:
        raise PackError("Core set exceeds 50 MiB limit; no complete set published")
    result = {"schema": "care-mobile-core-set-v1", "purpose": "development_preview", **UNREVIEWED,
              "coverage": CORE_SCOPE, "packages": packages, "payload_bytes": total}
    save_json(args.output / "manifest.json", result)
    print(json.dumps({"complete": True, "total_MiB": round(total / 1048576, 2), "packages": len(packages)}))


if __name__ == "__main__":
    main()
