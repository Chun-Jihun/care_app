"""Losslessly package the existing e약은요 snapshot without network requests."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.build_drug_knowledge_pack import add_record
from scripts.knowledge_pack import PackWriter, sha
from scripts.stage_mfds_easy_drug import load_verified_rows


def build(snapshot: Path, output: Path):
    raw = (snapshot / "manifest.json").read_bytes()
    manifest = json.loads(raw)
    rows, _ = load_verified_rows(snapshot, manifest)
    pages = {p["file"]: p["page_no"] for p in manifest["download"]["pages"]}
    writer = PackWriter(output, "drugs")
    try:
        writer.source("easy-drug", {"title": manifest["source"]["title"],
                      "publisher": manifest["source"]["provider"], "url": manifest["source"]["catalog_url"],
                      "snapshot_id": manifest["snapshot_id"], "source_manifest_sha256": sha(raw),
                      "collected_at": manifest["download"]["completed_at"], "clinical_reviewed_at": None,
                      "pages": manifest["download"]["pages"]})
        for row in rows:
            ref = row["source_ref"]
            add_record(writer, "easy-drug", row["item"], pages[ref["page_file"]], ref["item_index"])
        return writer.finish({"input_snapshot": manifest["snapshot_id"], "input_manifest_sha256": sha(raw)})
    finally:
        writer.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(build(args.snapshot, args.output), ensure_ascii=False, indent=2))
