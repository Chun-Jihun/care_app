from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from scripts.role_evaluation_harness import (
    HarnessError,
    MirageCachedRetrievalBackend,
    ReplayBackend,
    UnsupportedProjection,
    grade_response,
    parse_json_response,
    render_component_case,
    render_request_bundle,
    run_request_bundle,
)


def _json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def _jsonl_bytes(values: list[dict[str, object]]) -> bytes:
    return b"".join(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode(
            "utf-8"
        )
        + b"\n"
        for value in values
    )


def _component_case(
    case_id: str,
    role: str,
    dataset_id: str,
    input_value: dict[str, object],
    gold: dict[str, object],
    *,
    source_extra: dict[str, object] | None = None,
) -> dict[str, object]:
    source: dict[str, object] = {
        "dataset_id": dataset_id,
        "split": "test",
        "record_id": case_id,
        "record_sha256": "a" * 64,
        "locator": {"file": "fixture.jsonl", "record_index": 0},
    }
    if source_extra:
        source.update(source_extra)
    return {
        "schema_version": "1.0",
        "case_id": case_id,
        "source": source,
        "target": {
            "roles": [role],
            "task_family": "fixture",
            "supported_metrics": [],
            "component_evaluation_only": True,
        },
        "input": input_value,
        "gold": gold,
        "policy": {
            "evaluation_only": True,
            "do_not_train": True,
            "finetuning_eligible": False,
            "mobile_bundle": False,
            "runtime_rag_eligible": False,
            "approved_medical_knowledge": False,
            "scenario_compiler_input": False,
            "external_transmission_allowed": False,
        },
        "review_status": "adapter_generated_unreviewed",
        "project_evaluation_eligible": False,
    }


def _write_case_bundle(root: Path, cases: list[dict[str, object]]) -> Path:
    bundle = root / "cases"
    bundle.mkdir()
    content = _jsonl_bytes(cases)
    (bundle / "cases.jsonl").write_bytes(content)
    manifest = {
        "schema_version": "1.0",
        "adapter": {"version": "0.1.0", "source_name": "fixture"},
        "source_lock": {"dataset_id": cases[0]["source"]["dataset_id"]},
        "record_count": len(cases),
        "is_partial": False,
        "evaluation_eligible": False,
        "usage": {"do_not_train": True, "mobile_bundle": False},
        "outputs": [
            {
                "file": "cases.jsonl",
                "bytes": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
                "record_count": len(cases),
            }
        ],
    }
    (bundle / "manifest.json").write_bytes(_json_bytes(manifest))
    return bundle


class RoleRendererTests(unittest.TestCase):
    def test_a1_bfcl_renders_tools_without_gold(self) -> None:
        case = _component_case(
            "CASE-A1",
            "A1",
            "EVAL-FC-BFCL-V4",
            {
                "upstream_case": {
                    "question": [[{"role": "user", "content": "Use the calculator"}]],
                    "function": [
                        {
                            "name": "calculate",
                            "description": "calculate",
                            "parameters": {"type": "object", "properties": {}},
                        }
                    ],
                }
            },
            {
                "label_available": True,
                "function_calls": [{"calculate": {"x": "GOLD-ONLY"}}],
                "must_not_call": False,
            },
            source_extra={"category": "simple_python"},
        )

        request = render_component_case(case, Path.cwd())

        serialized = json.dumps(request, ensure_ascii=False)
        self.assertEqual(request["role_id"], "A1")
        self.assertEqual(request["evaluation_contract"]["mode"], "component_projection")
        self.assertIn("calculate", serialized)
        self.assertNotIn("GOLD-ONLY", serialized)
        self.assertEqual(request["response_schema"]["required"], ["tool_calls"])

    def test_a1_bfcl_multiturn_requires_official_runtime(self) -> None:
        case = _component_case(
            "CASE-A1-MULTITURN",
            "A1",
            "EVAL-FC-BFCL-V4",
            {
                "upstream_case": {
                    "question": [
                        [{"role": "user", "content": "first turn"}],
                        [{"role": "user", "content": "second turn"}],
                    ],
                    "involved_classes": ["GorillaFileSystem"],
                    "initial_config": {},
                }
            },
            {"label_available": True, "function_calls": []},
            source_extra={"category": "multi_turn_base"},
        )

        with self.assertRaises(UnsupportedProjection) as raised:
            render_component_case(case, Path.cwd())

        self.assertEqual(raised.exception.reason_code, "BFCL_OFFICIAL_RUNTIME_REQUIRED")

    def test_a2_longhealth_materializes_masked_documents(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source_root = root / "LongHealth"
            (source_root / "data").mkdir(parents=True)
            raw = {
                "patient_01": {
                    "name": "Alice Example",
                    "birthday": "1970-01-02",
                    "texts": {
                        "text_0": "Alice Example did not take the evening medicine on 1970-01-02."
                    },
                    "questions": [],
                }
            }
            (source_root / "data" / "benchmark_v5.json").write_text(
                json.dumps(raw), encoding="utf-8"
            )
            case = _component_case(
                "CASE-A2",
                "A2",
                "EVAL-LONGHEALTH",
                {
                    "patient_alias": "LH-PATIENT-X",
                    "question": "What did [PATIENT] not take?",
                    "options": {"A": "medicine", "B": "water"},
                    "document_locator": {
                        "file": "data/benchmark_v5.json",
                        "patient_key": "patient_01",
                        "text_ids": ["text_0"],
                        "materialize_at_runtime": True,
                        "mask_fields": ["name", "birthday"],
                    },
                },
                {"answer_text": "medicine", "acceptable_option_labels": ["A"]},
            )

            request = render_component_case(
                case,
                root,
                source_roots={"EVAL-LONGHEALTH": source_root},
            )

            serialized = json.dumps(request, ensure_ascii=False)
            self.assertIn("did not take", serialized)
            self.assertNotIn("Alice Example", serialized)
            self.assertNotIn("1970-01-02", serialized)
            self.assertIn("[PATIENT]", serialized)
            self.assertEqual(request["response_schema"]["required"], ["answer_label"])

    def test_a3_mirage_uses_question_only_for_retrieval(self) -> None:
        case = _component_case(
            "CASE-A3",
            "A3",
            "EVAL-MIRAGE",
            {
                "question": "Which evidence is relevant?",
                "options": {"A": "OPTION-LEAK", "B": "other"},
                "retrieval_query_policy": "question_only",
                "retrieval_artifact_key": "test_BIO-ID",
            },
            {
                "answer_label": "A",
                "retrieval": {
                    "labels_available": True,
                    "document_ids": ["PMID:123"],
                    "snippet_locators": [],
                },
            },
            source_extra={"subset": "bioasq"},
        )

        request = render_component_case(case, Path.cwd())

        serialized = json.dumps(request, ensure_ascii=False)
        self.assertIn("Which evidence is relevant?", serialized)
        self.assertNotIn("OPTION-LEAK", serialized)
        self.assertEqual(request["role_id"], "A3")
        self.assertEqual(request["runtime"]["retrieval_artifact_key"], "test_BIO-ID")

    def test_a4_healthbench_hides_rubrics_and_a5_receives_one_rubric(self) -> None:
        a4_case = _component_case(
            "CASE-A4",
            "A4",
            "EVAL-HEALTHBENCH",
            {"prompt": [{"role": "user", "content": "health question"}]},
            {"rubrics": [{"criterion": "HIDDEN-RUBRIC", "points": 10}]},
            source_extra={"variant": "oss_eval"},
        )
        a5_case = _component_case(
            "CASE-A5",
            "A5",
            "EVAL-HEALTHBENCH",
            {
                "prompt": [{"role": "user", "content": "health question"}],
                "candidate_completion": "candidate",
                "rubric": "VISIBLE-RUBRIC",
                "category": "accuracy",
            },
            {"binary_labels": [True, True, False], "majority_label": True},
            source_extra={"variant": "oss_meta_eval"},
        )

        a4 = render_component_case(a4_case, Path.cwd())
        a5 = render_component_case(a5_case, Path.cwd())

        self.assertNotIn("HIDDEN-RUBRIC", json.dumps(a4, ensure_ascii=False))
        self.assertIn("VISIBLE-RUBRIC", json.dumps(a5, ensure_ascii=False))
        self.assertEqual(a4["response_schema"]["required"], ["answer"])
        self.assertEqual(a5["response_schema"]["required"], ["criterion_met"])

    def test_ragtruth_a5_and_korean_support_have_distinct_schemas(self) -> None:
        rag_case = _component_case(
            "CASE-RAG",
            "A5",
            "EVAL-RAGTRUTH",
            {
                "task_type": "QA",
                "source_context": "source",
                "prompt": "question",
                "candidate_response": "answer",
            },
            {"has_hallucination": True, "hallucination_spans": []},
        )
        ko_case = _component_case(
            "CASE-KO",
            "KO",
            "EVAL-KORMEDMCQA",
            {"question": "질문", "options": {"A": "가", "B": "나"}},
            {"answer_label": "B"},
        )

        rag = render_component_case(rag_case, Path.cwd())
        ko = render_component_case(ko_case, Path.cwd())

        self.assertEqual(rag["response_schema"]["required"], ["has_hallucination", "spans"])
        self.assertEqual(ko["response_schema"]["required"], ["answer_label"])


class RunnerTests(unittest.TestCase):
    def test_parse_json_response_handles_fence_and_rejects_non_object(self) -> None:
        parsed = parse_json_response('prefix\n```json\n{"answer_label":"B"}\n```')
        self.assertEqual(parsed, {"answer_label": "B"})
        with self.assertRaisesRegex(HarnessError, "object"):
            parse_json_response("[1, 2]")

    def test_render_and_replay_run_preserve_hash_chain(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            case = _component_case(
                "CASE-KO",
                "KO",
                "EVAL-KORMEDMCQA",
                {"question": "질문", "options": {"A": "가", "B": "나"}},
                {"answer_label": "B"},
            )
            case_bundle = _write_case_bundle(root, [case])
            request_bundle = render_request_bundle(
                root, case_bundle, root / "requests", role_id="KO"
            )
            request = json.loads(
                (request_bundle / "requests.jsonl").read_text(encoding="utf-8").strip()
            )
            backend = ReplayBackend(
                {request["request_id"]: '{"answer_label":"B"}'},
                replay_id="unit-test",
            )

            response_bundle = run_request_bundle(
                root,
                request_bundle,
                root / "responses",
                backend,
            )

            manifest = json.loads(
                (response_bundle / "manifest.json").read_text(encoding="utf-8")
            )
            response = json.loads(
                (response_bundle / "responses.jsonl").read_text(encoding="utf-8").strip()
            )
            self.assertEqual(response["status"], "ok")
            self.assertEqual(response["parsed_output"]["answer_label"], "B")
            self.assertEqual(
                manifest["request_bundle"]["manifest_sha256"],
                hashlib.sha256((request_bundle / "manifest.json").read_bytes()).hexdigest(),
            )
            self.assertFalse(manifest["project_end_to_end_result"])

    def test_request_bundle_records_unsupported_bfcl_cases(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            supported = _component_case(
                "CASE-A1-SUPPORTED",
                "A1",
                "EVAL-FC-BFCL-V4",
                {
                    "upstream_case": {
                        "question": [[{"role": "user", "content": "calculate"}]],
                        "function": [{"name": "calculate", "parameters": {}}],
                    }
                },
                {"label_available": True, "function_calls": []},
                source_extra={"category": "simple_python"},
            )
            unsupported = _component_case(
                "CASE-A1-UNSUPPORTED",
                "A1",
                "EVAL-FC-BFCL-V4",
                {
                    "upstream_case": {
                        "question": [
                            [{"role": "user", "content": "first"}],
                            [{"role": "user", "content": "second"}],
                        ],
                        "involved_classes": ["GorillaFileSystem"],
                    }
                },
                {"label_available": True, "function_calls": []},
                source_extra={"category": "multi_turn_base"},
            )
            case_bundle = _write_case_bundle(root, [supported, unsupported])

            request_bundle = render_request_bundle(
                root, case_bundle, root / "requests", role_id="A1"
            )

            manifest = json.loads(
                (request_bundle / "manifest.json").read_text(encoding="utf-8")
            )
            requests = (request_bundle / "requests.jsonl").read_text(
                encoding="utf-8"
            ).splitlines()
            skipped = [
                json.loads(line)
                for line in (request_bundle / "skipped_cases.jsonl")
                .read_text(encoding="utf-8")
                .splitlines()
            ]
            self.assertEqual(len(requests), 1)
            self.assertEqual(manifest["matching_case_count"], 2)
            self.assertEqual(manifest["projection_supported_case_count"], 1)
            self.assertEqual(manifest["skipped_case_count"], 1)
            self.assertFalse(manifest["projection_coverage_complete"])
            self.assertEqual(
                skipped[0]["reason_code"], "BFCL_OFFICIAL_RUNTIME_REQUIRED"
            )
            self.assertNotIn("gold", skipped[0])

    def test_runner_rejects_parsed_json_that_violates_response_schema(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            case = _component_case(
                "CASE-KO",
                "KO",
                "EVAL-KORMEDMCQA",
                {"question": "질문", "options": {"A": "가", "B": "나"}},
                {"answer_label": "B"},
            )
            case_bundle = _write_case_bundle(root, [case])
            request_bundle = render_request_bundle(
                root, case_bundle, root / "requests", role_id="KO"
            )
            request = json.loads(
                (request_bundle / "requests.jsonl").read_text(encoding="utf-8").strip()
            )
            backend = ReplayBackend(
                {request["request_id"]: '{"answer_label":"Z","extra":true}'},
                replay_id="invalid-schema",
            )

            response_bundle = run_request_bundle(
                root, request_bundle, root / "responses", backend
            )
            response = json.loads(
                (response_bundle / "responses.jsonl").read_text(encoding="utf-8").strip()
            )

            self.assertEqual(response["status"], "schema_error")
            self.assertEqual(response["error_code"], "RESPONSE_SCHEMA_INVALID")
            self.assertIsNone(response["parsed_output"])

    def test_mirage_cached_backend_loads_only_requested_top_k(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            leaf = root / "MIRAGE" / "retrieved_snippets_10k" / "bioasq" / "pubmed" / "bm25"
            (leaf / "scores").mkdir(parents=True)
            (leaf / "snippets").mkdir()
            (leaf / "scores" / "test_X.json").write_text("[9.0, 8.0, 7.0]", encoding="utf-8")
            (leaf / "snippets" / "test_X.json").write_text(
                '[{"id":"chunk-1"},{"id":"chunk-2"},{"id":"chunk-3"}]',
                encoding="utf-8",
            )
            backend = MirageCachedRetrievalBackend(
                root / "MIRAGE", corpus="pubmed", retriever="bm25", top_k=2
            )
            request = {
                "request_id": "REQ-1",
                "runtime": {
                    "subset": "bioasq",
                    "retrieval_artifact_key": "test_X",
                },
            }

            result = backend.generate(request)

            self.assertEqual(
                json.loads(result.raw_text)["ranked_document_ids"],
                ["chunk-1", "chunk-2"],
            )
            self.assertEqual(result.usage["retrieved_count"], 2)


class GraderTests(unittest.TestCase):
    def test_a1_exact_call_grading(self) -> None:
        case = _component_case(
            "CASE-A1",
            "A1",
            "EVAL-FC-BFCL-V4",
            {},
            {
                "label_available": True,
                "function_calls": [{"search": {"query": "care"}}],
                "must_not_call": False,
            },
            source_extra={"category": "simple_python"},
        )
        response = {"status": "ok", "parsed_output": {"tool_calls": [{"name": "search", "arguments": {"query": "care"}}]}}

        score = grade_response(case, response)

        self.assertTrue(score["scored"])
        self.assertEqual(score["metrics"]["tool_selection_accuracy"], 1.0)
        self.assertEqual(score["metrics"]["argument_exact_match"], 1.0)

    def test_a2_and_korean_exact_answer_grading(self) -> None:
        a2 = _component_case(
            "CASE-A2",
            "A2",
            "EVAL-LONGHEALTH",
            {},
            {"answer_text": "medicine", "acceptable_option_labels": ["A", "C"]},
        )
        ko = _component_case(
            "CASE-KO",
            "KO",
            "EVAL-KORMEDMCQA",
            {},
            {"answer_label": "B"},
        )

        self.assertEqual(
            grade_response(a2, {"status": "ok", "parsed_output": {"answer_label": "C"}})["metrics"]["answer_accuracy"],
            1.0,
        )
        self.assertEqual(
            grade_response(ko, {"status": "ok", "parsed_output": {"answer_label": "A"}})["metrics"]["answer_accuracy"],
            0.0,
        )

    def test_a3_recall_mrr_and_id_namespace_block(self) -> None:
        case = _component_case(
            "CASE-A3",
            "A3",
            "EVAL-MIRAGE",
            {},
            {
                "retrieval": {
                    "labels_available": True,
                    "document_ids": ["PMID:1", "PMID:2"],
                    "snippet_locators": [],
                }
            },
        )
        score = grade_response(
            case,
            {
                "status": "ok",
                "parsed_output": {"ranked_document_ids": ["PMID:9", "PMID:2"]},
            },
            retrieval_k=2,
        )
        blocked = grade_response(
            case,
            {
                "status": "ok",
                "parsed_output": {
                    "ranked_document_ids": ["pubmed23n1085_18865", "pubmed23n1126_16588"]
                },
            },
            retrieval_k=2,
        )

        self.assertEqual(score["metrics"]["recall_at_k"], 0.5)
        self.assertEqual(score["metrics"]["mean_reciprocal_rank"], 0.5)
        self.assertFalse(blocked["scored"])
        self.assertIn("RETRIEVAL_ID_MAPPING_MISSING", blocked["failure_codes"])

    def test_a4_requires_judgment_and_aggregates_supplied_rubrics(self) -> None:
        case = _component_case(
            "CASE-A4",
            "A4",
            "EVAL-HEALTHBENCH",
            {},
            {
                "rubrics": [
                    {"criterion": "good", "points": 10},
                    {"criterion": "unsafe", "points": -10},
                ]
            },
        )
        response = {"status": "ok", "parsed_output": {"answer": "candidate"}}

        pending = grade_response(case, response)
        scored = grade_response(
            case,
            response,
            judgment={
                "judge_type": "human",
                "rubric_results": [
                    {"rubric_index": 0, "met": True},
                    {"rubric_index": 1, "met": False},
                ],
            },
        )

        self.assertFalse(pending["scored"])
        self.assertIn("HEALTHBENCH_JUDGMENT_REQUIRED", pending["failure_codes"])
        self.assertEqual(scored["metrics"]["local_weighted_rubric_fraction"], 1.0)
        self.assertFalse(scored["metrics"]["official_healthbench_score"])

    def test_a5_healthbench_and_ragtruth_metrics(self) -> None:
        meta = _component_case(
            "CASE-META",
            "A5",
            "EVAL-HEALTHBENCH",
            {},
            {"binary_labels": [False, False, True], "majority_label": False},
        )
        rag = _component_case(
            "CASE-RAG",
            "A5",
            "EVAL-RAGTRUTH",
            {},
            {
                "has_hallucination": True,
                "hallucination_spans": [
                    {"start": 10, "end": 20, "text": "abcdefghij", "label_type": "Evident Conflict"}
                ],
            },
        )

        meta_score = grade_response(
            meta,
            {"status": "ok", "parsed_output": {"criterion_met": True}},
        )
        rag_score = grade_response(
            rag,
            {
                "status": "ok",
                "parsed_output": {
                    "has_hallucination": True,
                    "spans": [{"start": 15, "end": 20, "label_type": "Evident Conflict"}],
                },
            },
        )

        self.assertEqual(meta_score["metrics"]["verifier_accuracy"], 0.0)
        self.assertEqual(meta_score["metrics"]["false_approval"], 1.0)
        self.assertEqual(rag_score["metrics"]["hallucination_detection_accuracy"], 1.0)
        self.assertAlmostEqual(rag_score["metrics"]["hallucination_span_precision"], 1.0)
        self.assertAlmostEqual(rag_score["metrics"]["hallucination_span_recall"], 0.5)


if __name__ == "__main__":
    unittest.main()
