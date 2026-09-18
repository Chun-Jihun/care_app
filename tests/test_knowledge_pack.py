import json
import sqlite3
import tempfile
import unittest
import zlib
from pathlib import Path

from scripts.build_drug_knowledge_pack import add_record
from scripts.knowledge_pack import PackError, PackReader, PackWriter, canonical, sha, unpack_blob


class KnowledgePackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "pack"

    def make_pack(self):
        writer = PackWriter(self.path, "drugs")
        writer.source("synthetic", {"title": "Synthetic, not medical"})
        record = {"ITEM_SEQ": "0001", "MIXTURE_ITEM_SEQ": "0002", "ITEM_NAME": "synthetic",
                  "PROHBT_CONTENT": "합성 검사: 0.5 mg 미만. 단, 조건과 예외는 원문대로.\n" * 3000,
                  "EMPTY": "", "NULL": None, "ZERO": 0, "STRUCTURE": [True, {"x": "y"}]}
        add_record(writer, "synthetic", record, 2, 3)
        add_record(writer, "synthetic", record, 2, 4)
        changed = dict(record, CHART="제형별 차이를 합치면 안 됨")
        add_record(writer, "synthetic", changed, 2, 5)
        manifest = writer.finish()
        return record, changed, manifest

    def test_every_field_roundtrips_and_product_variants_are_not_merged(self):
        record, changed, manifest = self.make_pack()
        reader = PackReader(self.path)
        self.addCleanup(reader.close)
        self.assertEqual(reader.drug(1), record)
        self.assertEqual(reader.drug(2), record)
        self.assertEqual(reader.drug(3), changed)
        self.assertEqual(len(reader.lookup("0002")), 3)
        self.assertEqual(manifest["stats"]["roundtrip_verified_records"], 3)
        self.assertLess(manifest["database_bytes"], manifest["stats"]["input_bytes"])

    def test_medical_activation_is_rejected(self):
        self.make_pack()
        reader = PackReader(self.path)
        self.addCleanup(reader.close)
        with self.assertRaises(PackError):
            reader.clinical_context("question")
        m = reader.manifest
        self.assertFalse(m["mobile_bundle"])
        self.assertFalse(m["runtime_rag_eligible"])
        self.assertTrue(m["do_not_train"])

    def test_old_citation_cannot_open_a_different_package(self):
        self.make_pack()
        with self.assertRaises(PackError):
            PackReader(self.path, expected_hash="0" * 64)

    def test_truncated_or_changed_package_is_rejected(self):
        self.make_pack()
        with (self.path / "knowledge.sqlite3").open("ab") as stream:
            stream.write(b"changed")
        with self.assertRaises(PackError):
            PackReader(self.path)

    def test_forged_clinical_status_is_rejected(self):
        self.make_pack()
        path = self.path / "manifest.json"
        m = json.loads(path.read_text(encoding="utf-8"))
        m["runtime_rag_eligible"] = True
        path.write_text(json.dumps(m), encoding="utf-8")
        with self.assertRaises(PackError):
            PackReader(self.path)

    def test_incomplete_pack_has_no_manifest_and_cannot_be_opened(self):
        writer = PackWriter(self.path, "drugs")
        writer.close()
        self.assertFalse((self.path / "manifest.json").exists())
        with self.assertRaises(FileNotFoundError):
            PackReader(self.path)

    def test_output_never_overwrites_existing_package(self):
        self.make_pack()
        with self.assertRaises(FileExistsError):
            PackWriter(self.path, "drugs")

    def test_builder_cannot_override_review_flags(self):
        writer = PackWriter(self.path, "drugs")
        try:
            with self.assertRaises(PackError):
                writer.finish({"mobile_bundle": True})
            self.assertFalse((self.path / "manifest.json").exists())
        finally:
            writer.close()

    def test_block_size_trailing_data_and_corruption_fail_closed(self):
        raw = b"a" * 100000
        payload = zlib.compress(raw)
        for p, size, checksum in ((payload, 1, sha(raw)), (payload + b"x", len(raw), sha(raw)),
                                   (payload, len(raw), "0" * 64), (payload[:-2], len(raw), sha(raw))):
            with self.assertRaises((PackError, zlib.error)):
                unpack_blob(p, size, checksum)


if __name__ == "__main__":
    unittest.main()
