from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from scripts.adapt_evaluation_sources import (
    AdapterError,
    adapt_evaluation_source,
    normalize_bfcl_case,
    normalize_healthbench_case,
    normalize_komedqa_case,
    normalize_kormedmcqa_case,
    normalize_longhealth_cases,
    normalize_mirage_cases,
    normalize_ragtruth_case,
)


def _sha256(value: object) -> str:
    encoded = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


class EvaluationSourceAdapterNormalizationTests(unittest.TestCase):
    def test_bfcl_preserves_upstream_calls_and_marks_component_only(self) -> None:
        question = {
            "id": "simple_python_0",
            "question": [[{"role": "user", "content": "삼각형 넓이를 계산해줘"}]],
            "function": [
                {
                    "name": "calculate_triangle_area",
                    "description": "Calculate an area.",
                    "parameters": {"type": "object", "properties": {}},
                }
            ],
        }
        answer = {
            "id": "simple_python_0",
            "ground_truth": [{"calculate_triangle_area": {"base": 3, "height": 4}}],
        }

        case = normalize_bfcl_case(
            question,
            answer,
            category="simple_python",
            source_file="bfcl_eval/data/BFCL_v4_simple_python.json",
            source_index=0,
        )

        self.assertEqual(case["target"]["roles"], ["A1"])
        self.assertEqual(case["source"]["split"], "benchmark")
        self.assertEqual(case["gold"]["function_calls"], answer["ground_truth"])
        self.assertTrue(case["policy"]["do_not_train"])
        self.assertFalse(case["policy"]["scenario_compiler_input"])
        self.assertFalse(case["project_evaluation_eligible"])

    def test_longhealth_omits_documents_names_and_birthdays(self) -> None:
        raw = {
            "patient_01": {
                "texts": {"text_0": "Alice Example was not given Medication X."},
                "name": "Alice Example",
                "birthday": "1970-01-02",
                "diagnosis": "fixture",
                "questions": [
                    {
                        "No": 7,
                        "question": "What was Alice Example not given?",
                        "answer_a": "Medication X",
                        "answer_b": "Medication Y",
                        "answer_c": "Medication Z",
                        "answer_d": "Water",
                        "answer_e": "Food",
                        "correct": "Medication X",
                        "answer_location": {
                            "text_0": {"start": [0.2], "end": [0.4]}
                        },
                    }
                ],
                "canaray-string": "do-not-copy",
            }
        }

        cases = normalize_longhealth_cases(
            raw,
            source_file="data/benchmark_v5.json",
        )

        self.assertEqual(len(cases), 1)
        case = cases[0]
        serialized = json.dumps(case, ensure_ascii=False)
        self.assertNotIn("Alice Example", serialized)
        self.assertNotIn("1970-01-02", serialized)
        self.assertNotIn("was not given Medication X", serialized)
        self.assertEqual(case["target"]["roles"], ["A2"])
        self.assertEqual(case["input"]["question"], "What was [PATIENT] not given?")
        self.assertEqual(
            case["input"]["document_locator"]["text_ids"], ["text_0"]
        )
        self.assertEqual(case["gold"]["answer_location"]["text_0"]["start"], [0.2])
        self.assertEqual(case["gold"]["acceptable_option_labels"], ["A"])

    def test_mirage_adds_bioasq_document_gold_without_copying_snippets(self) -> None:
        benchmark = {
            "bioasq": {
                "BIO-ID": {
                    "question": "Is the fixture supported?",
                    "options": {"A": "yes", "B": "no"},
                    "answer": "A",
                }
            },
            "medqa": {
                "0000": {
                    "question": "Choose one.",
                    "options": {"A": "one", "B": "two"},
                    "answer": "B",
                }
            },
        }
        bioasq = {
            "BIO-ID": {
                "source_file": "rawdata/bioasq/task.json",
                "question": {
                    "id": "BIO-ID",
                    "documents": ["https://pubmed.ncbi.nlm.nih.gov/12345"],
                    "snippets": [
                        {
                            "document": "https://pubmed.ncbi.nlm.nih.gov/12345",
                            "beginSection": "abstract",
                            "endSection": "abstract",
                            "offsetInBeginSection": 10,
                            "offsetInEndSection": 20,
                            "text": "gold snippet text",
                        }
                    ],
                },
            }
        }

        cases = normalize_mirage_cases(
            benchmark,
            source_file="benchmark.json",
            bioasq_gold=bioasq,
        )

        self.assertEqual(len(cases), 2)
        bio_case = next(case for case in cases if case["source"]["subset"] == "bioasq")
        other_case = next(case for case in cases if case["source"]["subset"] == "medqa")
        self.assertEqual(bio_case["target"]["roles"], ["A3"])
        self.assertEqual(
            bio_case["gold"]["retrieval"]["document_ids"], ["PMID:12345"]
        )
        self.assertEqual(
            bio_case["gold"]["retrieval"]["snippet_locators"][0]["text_sha256"],
            hashlib.sha256("gold snippet text".encode("utf-8")).hexdigest(),
        )
        self.assertNotIn("gold snippet text", json.dumps(bio_case, ensure_ascii=False))
        self.assertFalse(other_case["gold"]["retrieval"]["labels_available"])
        self.assertNotIn("recall_at_k", other_case["target"]["supported_metrics"])

    def test_healthbench_routes_eval_to_a4_and_meta_to_a5(self) -> None:
        eval_row = {
            "prompt_id": "P1",
            "prompt": [{"role": "user", "content": "question"}],
            "rubrics": [{"criterion": "be safe", "points": 10, "tags": ["axis:accuracy"]}],
            "example_tags": ["tag"],
            "canary": "secret-canary",
        }
        meta_row = {
            "prompt_id": "P1",
            "completion_id": "C1",
            "prompt": [{"role": "user", "content": "question"}],
            "completion": "candidate",
            "rubric": "be safe",
            "binary_labels": [True, False, True],
            "anonymized_physician_ids": ["a", "b", "c"],
            "category": "accuracy",
            "canary": "secret-canary",
        }

        a4 = normalize_healthbench_case(eval_row, variant="oss_eval", source_index=0)
        a5 = normalize_healthbench_case(meta_row, variant="oss_meta_eval", source_index=0)

        self.assertEqual(a4["target"]["roles"], ["A4"])
        self.assertEqual(a5["target"]["roles"], ["A5"])
        self.assertEqual(a5["gold"]["binary_labels"], [True, False, True])
        self.assertNotIn("anonymized_physician_ids", json.dumps(a5))
        self.assertNotIn("secret-canary", json.dumps(a4))
        self.assertTrue(a4["source"]["canary_present"])

    def test_ragtruth_validates_span_text_and_preserves_upstream_split(self) -> None:
        source = {
            "source_id": "S1",
            "task_type": "QA",
            "source": "fixture",
            "source_info": "Evidence says 1945.",
            "prompt": "When?",
        }
        response = {
            "id": "R1",
            "source_id": "S1",
            "model": "fixture-model",
            "temperature": 0.0,
            "labels": [
                {
                    "start": 15,
                    "end": 19,
                    "text": "2022",
                    "meta": "conflict",
                    "label_type": "Evident Conflict",
                    "implicit_true": False,
                    "due_to_null": False,
                }
            ],
            "split": "test",
            "quality": "good",
            "response": "The answer was 2022.",
        }

        case = normalize_ragtruth_case(source, response, source_index=0, response_index=0)

        self.assertEqual(case["source"]["split"], "test")
        self.assertEqual(case["target"]["roles"], ["A5"])
        self.assertEqual(case["gold"]["hallucination_spans"][0]["text"], "2022")

        response["labels"][0]["text"] = "1945"
        with self.assertRaisesRegex(AdapterError, "span"):
            normalize_ragtruth_case(source, response, source_index=0, response_index=0)

    def test_korean_qa_adapters_keep_all_splits_do_not_train(self) -> None:
        komedqa = normalize_komedqa_case(
            {
                "qa_id": 61,
                "domain": 4,
                "domain_name": "Neurology/Neurosurgery",
                "q_type": 1,
                "q_type_name": "multiple_choice",
                "question": "질문\n1) 가\n2) 나",
                "answer": "2) 나",
            },
            source_index=0,
        )
        kormed = normalize_kormedmcqa_case(
            {
                "subject": "pharm",
                "year": 2022,
                "period": 1,
                "q_number": 3,
                "question": "질문",
                "A": "가",
                "B": "나",
                "C": "다",
                "D": "라",
                "E": "마",
                "answer": 2,
                "cot": "해설",
            },
            config="pharm",
            split="train",
            source_index=0,
        )

        self.assertEqual(komedqa["target"]["roles"], ["KO"])
        self.assertEqual(kormed["gold"]["answer_label"], "B")
        self.assertEqual(kormed["source"]["split"], "train")
        self.assertTrue(kormed["policy"]["do_not_train"])
        self.assertFalse(kormed["policy"]["finetuning_eligible"])


class EvaluationSourceAdapterIntegrationTests(unittest.TestCase):
    def test_adapter_writes_deterministic_manifest_and_refuses_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source_root = root / "KoMedQA"
            (source_root / "data" / "korean").mkdir(parents=True)
            row = {
                "qa_id": 1,
                "domain": 17,
                "domain_name": "Internal Medicine",
                "q_type": 2,
                "q_type_name": "short_answer",
                "question": "질문",
                "answer": "답",
            }
            source_file = source_root / "data" / "korean" / "medqa_kr.jsonl"
            source_file.write_text(
                json.dumps(row, ensure_ascii=False) + "\n", encoding="utf-8"
            )
            tree_hash = _sha256(
                [["data/korean/medqa_kr.jsonl", source_file.stat().st_size, hashlib.sha256(source_file.read_bytes()).hexdigest()]]
            )
            lock = {
                "schema_version": "1.0",
                "policy": {
                    "public_benchmarks_are_project_evaluation_only": True,
                    "evaluation_data_must_not_be_used_for_finetuning": True,
                },
                "data_sources": [
                    {
                        "id": "EVAL-KOMEDQA",
                        "name": "KoMedQA",
                        "local_path": "KoMedQA",
                        "license": {"status": "verified_fixture"},
                        "roles": ["Korean_medical_language_component_evaluation"],
                        "usage": {
                            "purpose": ["component_evaluation"],
                            "do_not_train": True,
                            "mobile_bundle": False,
                            "runtime_rag_eligible": False,
                        },
                        "integrity": {"tree_sha256": tree_hash},
                    }
                ],
            }
            lock_path = root / "data_sources.lock.json"
            lock_path.write_text(json.dumps(lock), encoding="utf-8")
            output = root / "adapted"

            result = adapt_evaluation_source(
                root,
                "komedqa",
                output,
                lock_manifest_path=lock_path,
            )

            manifest = json.loads((result / "manifest.json").read_text(encoding="utf-8"))
            cases = [
                json.loads(line)
                for line in (result / "cases.jsonl").read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(manifest["record_count"], 1)
            self.assertEqual(manifest["source_lock"]["dataset_id"], "EVAL-KOMEDQA")
            self.assertEqual(manifest["outputs"][0]["sha256"], hashlib.sha256((result / "cases.jsonl").read_bytes()).hexdigest())
            self.assertEqual(len(cases), 1)
            self.assertFalse(manifest["evaluation_eligible"])
            self.assertFalse(manifest["is_partial"])

            with self.assertRaisesRegex(AdapterError, "이미 존재"):
                adapt_evaluation_source(
                    root,
                    "komedqa",
                    output,
                    lock_manifest_path=lock_path,
                )

    def test_limit_marks_output_partial_and_not_scoreable(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source_root = root / "KoMedQA"
            (source_root / "data" / "korean").mkdir(parents=True)
            rows = [
                {
                    "qa_id": index,
                    "domain": 17,
                    "domain_name": "Internal Medicine",
                    "q_type": 2,
                    "q_type_name": "short_answer",
                    "question": f"질문 {index}",
                    "answer": f"답 {index}",
                }
                for index in range(3)
            ]
            source_file = source_root / "data" / "korean" / "medqa_kr.jsonl"
            source_file.write_text(
                "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows),
                encoding="utf-8",
            )
            lock = {
                "schema_version": "1.0",
                "policy": {
                    "public_benchmarks_are_project_evaluation_only": True,
                    "evaluation_data_must_not_be_used_for_finetuning": True,
                },
                "data_sources": [
                    {
                        "id": "EVAL-KOMEDQA",
                        "name": "KoMedQA",
                        "local_path": "KoMedQA",
                        "license": {"status": "verified_fixture"},
                        "roles": ["Korean_medical_language_component_evaluation"],
                        "usage": {"purpose": ["component_evaluation"], "do_not_train": True, "mobile_bundle": False, "runtime_rag_eligible": False},
                        "integrity": {"tree_sha256": "fixture-tree"},
                    }
                ],
            }
            lock_path = root / "lock.json"
            lock_path.write_text(json.dumps(lock), encoding="utf-8")

            result = adapt_evaluation_source(
                root,
                "komedqa",
                root / "partial",
                lock_manifest_path=lock_path,
                limit=1,
            )
            manifest = json.loads((result / "manifest.json").read_text(encoding="utf-8"))
            self.assertTrue(manifest["is_partial"])
            self.assertEqual(manifest["record_count"], 1)
            self.assertIn("PARTIAL_ADAPTER_OUTPUT", manifest["blocking_issues"])


if __name__ == "__main__":
    unittest.main()
