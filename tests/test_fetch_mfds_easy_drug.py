import json
import tempfile
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from scripts.fetch_mfds_easy_drug import (
    ApiResponseError,
    ConfigurationError,
    PageResult,
    build_manifest,
    build_request_url,
    load_dotenv,
    normalize_endpoint,
    parse_page_payload,
    write_bytes_atomic,
)


class EndpointSafetyTests(unittest.TestCase):
    def test_service_base_url_is_expanded_to_list_endpoint(self) -> None:
        endpoint = normalize_endpoint(
            "https://apis.data.go.kr/1471000/DrbEasyDrugInfoService"
        )

        self.assertEqual(
            endpoint,
            "https://apis.data.go.kr/1471000/DrbEasyDrugInfoService/"
            "getDrbEasyDrugList",
        )

    def test_untrusted_host_is_rejected_before_key_can_be_sent(self) -> None:
        with self.assertRaises(ConfigurationError):
            normalize_endpoint(
                "https://example.com/1471000/DrbEasyDrugInfoService/"
                "getDrbEasyDrugList"
            )

    def test_http_endpoint_is_rejected(self) -> None:
        with self.assertRaises(ConfigurationError):
            normalize_endpoint(
                "http://apis.data.go.kr/1471000/DrbEasyDrugInfoService/"
                "getDrbEasyDrugList"
            )

    def test_endpoint_with_query_is_rejected(self) -> None:
        with self.assertRaises(ConfigurationError):
            normalize_endpoint(
                "https://apis.data.go.kr/1471000/DrbEasyDrugInfoService/"
                "getDrbEasyDrugList?ServiceKey=must-not-be-here"
            )

    def test_encoded_service_key_is_not_double_encoded(self) -> None:
        encoded_key = "abc%2Bdef%2Fghi%3D"
        url = build_request_url(
            normalize_endpoint(
                "https://apis.data.go.kr/1471000/DrbEasyDrugInfoService"
            ),
            encoded_key,
            page_no=1,
            num_rows=10,
            filters={},
        )

        query = urlsplit(url).query
        self.assertNotIn("%252B", query)
        self.assertEqual(parse_qs(query)["ServiceKey"], ["abc+def/ghi="])
        self.assertEqual(parse_qs(query)["type"], ["json"])


class DotenvTests(unittest.TestCase):
    def test_load_dotenv_preserves_equals_in_value_and_removes_quotes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            env_path = Path(temp_dir) / ".env"
            env_path.write_text(
                "A='value=with=equals'\nB=plain\n# ignored\n",
                encoding="utf-8",
            )

            values = load_dotenv(env_path)

        self.assertEqual(values["A"], "value=with=equals")
        self.assertEqual(values["B"], "plain")


class ResponseValidationTests(unittest.TestCase):
    def test_valid_response_wrapper_is_parsed(self) -> None:
        payload = json.dumps(
            {
                "response": {
                    "header": {"resultCode": "00", "resultMsg": "NORMAL SERVICE"},
                    "body": {
                        "pageNo": 1,
                        "numOfRows": 10,
                        "totalCount": 12,
                        "items": [
                            {"itemSeq": "1", "itemName": "product-a"},
                            {"itemSeq": "2", "itemName": "product-b"},
                        ],
                    },
                }
            },
            ensure_ascii=False,
        ).encode("utf-8")

        result = parse_page_payload(
            payload,
            requested_page_no=1,
            requested_num_rows=10,
            http_status=200,
            content_type="application/json",
        )

        self.assertEqual(result.result_code, "00")
        self.assertEqual(result.item_count, 2)
        self.assertEqual(result.total_count, 12)

    def test_nested_item_shape_is_supported(self) -> None:
        payload = json.dumps(
            {
                "header": {"resultCode": "00", "resultMsg": "NORMAL SERVICE"},
                "body": {
                    "pageNo": "1",
                    "numOfRows": "10",
                    "totalCount": "1",
                    "items": {"item": {"itemSeq": "1", "itemName": "product-a"}},
                },
            }
        ).encode("utf-8")

        result = parse_page_payload(
            payload,
            requested_page_no=1,
            requested_num_rows=10,
            http_status=200,
            content_type="application/json",
        )

        self.assertEqual(result.item_count, 1)

    def test_non_success_api_result_is_rejected(self) -> None:
        payload = json.dumps(
            {
                "response": {
                    "header": {
                        "resultCode": "30",
                        "resultMsg": "SERVICE KEY IS NOT REGISTERED ERROR",
                    },
                    "body": {},
                }
            }
        ).encode("utf-8")

        with self.assertRaises(ApiResponseError) as raised:
            parse_page_payload(
                payload,
                requested_page_no=1,
                requested_num_rows=10,
                http_status=200,
                content_type="application/json",
            )

        self.assertEqual(raised.exception.result_code, "30")

    def test_malformed_json_is_rejected(self) -> None:
        with self.assertRaises(ApiResponseError):
            parse_page_payload(
                b"not-json",
                requested_page_no=1,
                requested_num_rows=10,
                http_status=200,
                content_type="text/plain",
            )


class PersistenceSafetyTests(unittest.TestCase):
    def test_manifest_does_not_contain_service_key_or_keyed_url(self) -> None:
        page = PageResult(
            raw_bytes=b'{"response": {}}',
            result_code="00",
            result_message="NORMAL SERVICE",
            page_no=1,
            num_rows=10,
            total_count=1,
            item_count=1,
            http_status=200,
            content_type="application/json",
        )
        secret = "abc%2Bdef%2Fghi%3D"

        manifest = build_manifest(
            snapshot_id="20260901T120000Z",
            endpoint=(
                "https://apis.data.go.kr/1471000/DrbEasyDrugInfoService/"
                "getDrbEasyDrugList"
            ),
            request_parameters={"pageNo": 1, "numOfRows": 10, "type": "json"},
            pages=[("page-00001.json", page)],
            started_at="2026-09-01T12:00:00Z",
            completed_at="2026-09-01T12:00:01Z",
            mode="single_page",
            complete=False,
        )
        serialized = json.dumps(manifest)

        self.assertNotIn(secret, serialized)
        self.assertNotIn("ServiceKey", serialized)
        self.assertNotIn("?", manifest["source"]["endpoint"])
        self.assertEqual(manifest["approval_state"], "raw_unreviewed")

    def test_atomic_write_refuses_to_overwrite_raw_response(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            target = Path(temp_dir) / "page-00001.json"
            write_bytes_atomic(target, b"first")

            with self.assertRaises(FileExistsError):
                write_bytes_atomic(target, b"second")

            self.assertEqual(target.read_bytes(), b"first")


if __name__ == "__main__":
    unittest.main()
