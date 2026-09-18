import json
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from scripts.fetch_mfds_easy_drug import DownloaderError, parse_page_payload
from scripts.mfds_catalog import SERVICES, build_url, normalize_base
from scripts.mfds_local_store import build_index, lookup
from scripts.mfds_snapshot import collect, read_manifest, save_json


def fake_fetch(endpoint, key, *, page_no, num_rows, **kwargs):
    total = 3
    items = [{"ITEM_SEQ": str(i + 1), "ITEM_NAME": "합성품목 " + str(i + 1),
              "MIXTURE_ITEM_SEQ": "42" if i == 0 else "", "CHANGE_DATE": "20260918"}
             for i in range((page_no - 1) * num_rows, min(page_no * num_rows, total))]
    payload = {"header": {"resultCode": "00"}, "body": {
        "pageNo": page_no, "numOfRows": num_rows, "totalCount": total, "items": items}}
    return parse_page_payload(json.dumps(payload).encode(), requested_page_no=page_no,
                              requested_num_rows=num_rows, http_status=200, content_type="application/json")


class LocalSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.snapshot = Path(self.tmp.name) / "snapshot"
        output = patch("sys.stdout", new_callable=io.StringIO)
        output.start()
        self.addCleanup(output.stop)

    def collect(self, **kwargs):
        return collect(self.snapshot, "permits", SERVICES["permits"].endpoint,
                       "SYNTHETIC-KEY-NEVER-REAL", rows=2, workers=1, delay=0, **kwargs)

    def test_all_operations_complete_and_offline_queries_need_no_network_or_key(self):
        m = self.collect(page_fetcher=fake_fetch)
        self.assertEqual(set(m["operations"]), set(SERVICES["permits"].operations))
        self.assertTrue(m["download_complete"])
        self.assertFalse(m["runtime_rag_eligible"])
        build_index(self.snapshot)
        with patch("socket.socket", side_effect=AssertionError("network forbidden")):
            r = lookup(self.snapshot, item_seq="42", limit=1)
        self.assertEqual(r["records"][0]["record"]["ITEM_SEQ"], "1")
        self.assertTrue(r["has_more"])
        self.assertTrue(r["do_not_train"])
        self.assertFalse(r["network_used"])
        self.assertEqual(r["source"]["publisher"], "식품의약품안전처")
        self.assertIsNone(r["source"]["clinical_reviewed_at"])
        self.assertEqual(lookup(self.snapshot, item_seq="missing")["records"], [])
        self.assertIn("의미하지", r["notice"])

    def test_resume_requests_only_missing_pages(self):
        with self.assertRaises(DownloaderError):
            self.collect(page_fetcher=fake_fetch, max_requests=1)
        m = read_manifest(self.snapshot, require_complete=False)
        self.assertFalse(m["download_complete"])
        calls = []
        def fetch(endpoint, key, **kwargs):
            calls.append((endpoint, kwargs["page_no"]))
            return fake_fetch(endpoint, key, **kwargs)
        self.collect(page_fetcher=fetch, resume=True)
        self.assertEqual(len(calls), 5)
        self.assertEqual(calls[0][1], 2)
        build_index(self.snapshot)

    def test_partial_snapshot_cannot_be_indexed(self):
        with self.assertRaises(DownloaderError):
            self.collect(page_fetcher=fake_fetch, max_requests=1)
        with self.assertRaises(DownloaderError):
            build_index(self.snapshot)
        self.assertFalse((self.snapshot / "catalog.sqlite3").exists())

    def test_changed_total_or_short_page_or_repeated_page_fails_closed(self):
        for mode in ("total", "short", "repeat", "missing_metadata"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "snapshot"
                def fetch(endpoint, key, **kwargs):
                    p = fake_fetch(endpoint, key, **kwargs)
                    d = json.loads(p.raw_bytes)
                    b = d["body"]
                    if mode == "total" and kwargs["page_no"] == 2:
                        b["totalCount"] += 1
                    if mode == "short":
                        b["items"] = []
                    if mode == "repeat":
                        b["totalCount"] = 4
                        b["items"] = [{"ITEM_SEQ": "1"}, {"ITEM_SEQ": "2"}]
                    if mode == "missing_metadata":
                        b.pop("totalCount")
                    return parse_page_payload(json.dumps(d).encode(),
                        requested_page_no=kwargs["page_no"], requested_num_rows=2,
                        http_status=200, content_type="application/json")
                with self.assertRaises(DownloaderError):
                    collect(path, "permits", SERVICES["permits"].endpoint, "synthetic-key",
                            rows=2, workers=1, delay=0, page_fetcher=fetch)
                self.assertFalse(read_manifest(path, require_complete=False)["download_complete"])

    def test_tampered_page_rejected_on_resume_and_indexing(self):
        self.collect(page_fetcher=fake_fetch)
        page = next((self.snapshot / "raw").rglob("*.json"))
        page.write_bytes(page.read_bytes() + b" ")
        for action in (lambda: self.collect(page_fetcher=fake_fetch, resume=True),
                       lambda: build_index(self.snapshot)):
            with self.assertRaises(DownloaderError):
                action()

    def test_manifest_cannot_claim_empty_or_missing_operation_is_complete(self):
        self.collect(page_fetcher=fake_fetch)
        m = read_manifest(self.snapshot)
        m["operations"][SERVICES["permits"].operations[0]]["pages"] = []
        save_json(self.snapshot / "manifest.json", m)
        with self.assertRaises(DownloaderError):
            build_index(self.snapshot)

    def test_path_traversal_in_manifest_rejected(self):
        self.collect(page_fetcher=fake_fetch)
        m = read_manifest(self.snapshot)
        m["operations"][SERVICES["permits"].operations[0]]["pages"][0]["file"] = "../secret"
        save_json(self.snapshot / "manifest.json", m)
        with self.assertRaises(DownloaderError):
            build_index(self.snapshot)

    def test_reflected_key_is_never_persisted(self):
        def fetch(endpoint, key, **kwargs):
            p = fake_fetch(endpoint, key, **kwargs)
            d = json.loads(p.raw_bytes)
            d["body"]["items"][0]["extra"] = key
            return parse_page_payload(json.dumps(d).encode(), requested_page_no=1,
                requested_num_rows=2, http_status=200, content_type="application/json")
        with self.assertRaises(DownloaderError):
            self.collect(page_fetcher=fetch)
        for p in self.snapshot.rglob("*.json"):
            self.assertNotIn("SYNTHETIC-KEY-NEVER-REAL", p.read_text(encoding="utf-8"))
        self.assertFalse((self.snapshot / "raw").exists())

    def test_failed_new_snapshot_preserves_previous_index(self):
        self.collect(page_fetcher=fake_fetch)
        db = build_index(self.snapshot)
        previous = db.read_bytes()
        with self.assertRaises(FileExistsError):
            self.collect(page_fetcher=fake_fetch)
        self.assertEqual(db.read_bytes(), previous)
        self.assertTrue(lookup(self.snapshot, name="합성")["records"])

    def test_corrupted_database_is_rejected(self):
        self.collect(page_fetcher=fake_fetch)
        db = build_index(self.snapshot)
        with db.open("ab") as stream:
            stream.write(b"corrupted")
        with self.assertRaises(DownloaderError):
            lookup(self.snapshot, item_seq="1")

    def test_query_rejects_changed_cited_source_after_indexing(self):
        self.collect(page_fetcher=fake_fetch)
        build_index(self.snapshot)
        page = self.snapshot / "raw" / SERVICES["permits"].operations[0] / "page-00001.json"
        page.write_bytes(page.read_bytes() + b" ")
        with self.assertRaises(DownloaderError):
            lookup(self.snapshot, item_seq="1")

    def test_query_uses_literal_parameters(self):
        self.collect(page_fetcher=fake_fetch)
        build_index(self.snapshot)
        self.assertEqual(lookup(self.snapshot, item_seq="' OR 1=1 --")["records"], [])
        self.assertEqual(lookup(self.snapshot, name="%")["records"], [])

    def test_parallel_pages_are_saved_in_sequence(self):
        m = collect(self.snapshot, "dur", SERVICES["dur"].endpoint, "synthetic-key",
                    rows=1, workers=3, delay=0, page_fetcher=fake_fetch)
        for state in m["operations"].values():
            self.assertEqual([p["page_no"] for p in state["pages"]], [1, 2, 3])
        build_index(self.snapshot)
        self.assertTrue(lookup(self.snapshot, item_seq="42")["records"])

    def test_index_publication_interruption_can_be_rebuilt(self):
        self.collect(page_fetcher=fake_fetch)
        original = Path.replace
        def replace(path, target):
            if path.name.startswith(".catalog-"):
                raise OSError("synthetic interrupted publication")
            return original(path, target)
        with patch.object(Path, "replace", replace), self.assertRaises(OSError):
            build_index(self.snapshot)
        self.assertFalse((self.snapshot / "catalog.sqlite3").exists())
        build_index(self.snapshot)
        self.assertTrue(lookup(self.snapshot, item_seq="1")["records"])


class ConfigurationTests(unittest.TestCase):
    def test_provider_page_limit_is_500(self):
        s = SERVICES["dur"]
        endpoint = s.endpoint + "/" + s.operations[0]
        self.assertIn("numOfRows=500", build_url(endpoint, "synthetic-key", page_no=1, num_rows=500, filters={}))
        with self.assertRaises(DownloaderError):
            build_url(endpoint, "synthetic-key", page_no=1, num_rows=501, filters={})

    def test_all_documented_operations_have_an_allowlisted_url(self):
        self.assertEqual(len(SERVICES["dur"].operations), 9)
        self.assertEqual(len(SERVICES["permits"].operations), 3)
        for s in SERVICES.values():
            for op in s.operations:
                url = s.endpoint + "/" + op
                self.assertEqual(normalize_base(url, s), s.endpoint)
                result = build_url(url, "abc%2Bdef%3D", page_no=1, num_rows=100, filters={})
                self.assertEqual(parse_qs(urlsplit(result).query)["serviceKey"], ["abc+def="])

    def test_unsafe_endpoints_are_rejected_without_echoing_values(self):
        s = SERVICES["dur"]
        for endpoint in ("http://apis.data.go.kr" + s.base_path, s.endpoint + "?secret=value",
                         "https://example.com" + s.base_path,
                         "https://user:secret@apis.data.go.kr" + s.base_path,
                         "https://apis.data.go.kr:443" + s.base_path,
                         s.endpoint + "/other", "https://apis.data.go.kr:bad" + s.base_path):
            with self.subTest(endpoint=endpoint), self.assertRaises(DownloaderError) as cm:
                normalize_base(endpoint, s)
            self.assertNotIn("secret", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
