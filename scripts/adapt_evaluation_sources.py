#!/usr/bin/env python3
"""Normalize downloaded public benchmarks into component-evaluation cases.

The adapters are deterministic and offline. Their outputs are evaluation-only,
never become medical knowledge, and never become scenario-compiler input merely
because they were normalized. Large source documents and MIRAGE retrieval files
are referenced by local locators instead of being copied into every case.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from typing import Any, Iterable, Iterator, Mapping, Sequence


SCRIPT_VERSION = "0.1.0"
SCHEMA_VERSION = "1.0"
DEFAULT_LOCK_MANIFEST = Path("experiments/agent_eval/manifests/data_sources.lock.json")
ADAPTER_DATASET_IDS = {
    "bfcl": "EVAL-FC-BFCL-V4",
    "healthbench": "EVAL-HEALTHBENCH",
    "komedqa": "EVAL-KOMEDQA",
    "kormedmcqa": "EVAL-KORMEDMCQA",
    "longhealth": "EVAL-LONGHEALTH",
    "mirage": "EVAL-MIRAGE",
    "ragtruth": "EVAL-RAGTRUTH",
}
OPTION_LABELS = ("A", "B", "C", "D", "E")


class AdapterError(RuntimeError):
    """Raised when a source cannot be normalized without weakening a boundary."""


@dataclass
class AdapterRun:
    cases: Iterable[dict[str, Any]]
    input_files: list[Path]
    metadata: dict[str, Any] = field(default_factory=dict)
    blocking_issues: list[str] = field(default_factory=list)


def _canonical_bytes(value: object) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def _canonical_hash(value: object) -> str:
    return hashlib.sha256(_canonical_bytes(value)).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except FileNotFoundError as exc:
        raise AdapterError(f"필수 원천 파일을 찾을 수 없습니다: {path}") from exc
    return digest.hexdigest()


def _stable_id(prefix: str, *parts: object, length: int = 20) -> str:
    encoded = "\x1f".join(str(part) for part in parts).encode("utf-8")
    return f"{prefix}-{hashlib.sha256(encoded).hexdigest()[:length].upper()}"


def _nonempty_string(value: Any, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise AdapterError(f"{field_name}이 비어 있습니다.")
    return value.strip()


def _load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError as exc:
        raise AdapterError(f"필수 원천 파일을 찾을 수 없습니다: {path}") from exc
    except json.JSONDecodeError as exc:
        raise AdapterError(f"JSON 형식이 잘못되었습니다: {path}: {exc}") from exc


def _iter_jsonl(path: Path) -> Iterator[dict[str, Any]]:
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as stream:
            for line_number, line in enumerate(stream, 1):
                if not line.strip():
                    raise AdapterError(f"JSONL에 빈 행이 있습니다: {path}:{line_number}")
                try:
                    value = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise AdapterError(
                        f"JSONL 형식이 잘못되었습니다: {path}:{line_number}: {exc}"
                    ) from exc
                if not isinstance(value, dict):
                    raise AdapterError(
                        f"JSONL 행은 object여야 합니다: {path}:{line_number}"
                    )
                yield value
    except FileNotFoundError as exc:
        raise AdapterError(f"필수 원천 파일을 찾을 수 없습니다: {path}") from exc


def _jsonl_index(path: Path, key: str) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for row in _iter_jsonl(path):
        row_id = _nonempty_string(row.get(key), f"{path.name}.{key}")
        if row_id in result:
            raise AdapterError(f"{path}에 중복 {key}가 있습니다: {row_id}")
        result[row_id] = row
    return result


def _policy() -> dict[str, bool]:
    return {
        "evaluation_only": True,
        "do_not_train": True,
        "finetuning_eligible": False,
        "mobile_bundle": False,
        "runtime_rag_eligible": False,
        "approved_medical_knowledge": False,
        "scenario_compiler_input": False,
        "external_transmission_allowed": False,
    }


def _case(
    *,
    dataset_id: str,
    source_record_id: str,
    split: str,
    roles: Sequence[str],
    task_family: str,
    supported_metrics: Sequence[str],
    input_value: Mapping[str, Any],
    gold: Mapping[str, Any],
    raw_for_hash: object,
    locator: Mapping[str, Any],
    source_extra: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    source: dict[str, Any] = {
        "dataset_id": dataset_id,
        "split": split,
        "record_id": source_record_id,
        "record_sha256": _canonical_hash(raw_for_hash),
        "locator": dict(locator),
    }
    if source_extra:
        source.update(source_extra)
    return {
        "schema_version": SCHEMA_VERSION,
        "case_id": _stable_id("CASE", dataset_id, split, source_record_id),
        "source": source,
        "target": {
            "roles": list(roles),
            "task_family": task_family,
            "supported_metrics": list(supported_metrics),
            "component_evaluation_only": True,
        },
        "input": dict(input_value),
        "gold": dict(gold),
        "policy": _policy(),
        "review_status": "adapter_generated_unreviewed",
        "project_evaluation_eligible": False,
    }


def normalize_bfcl_case(
    question: Mapping[str, Any],
    answer: Mapping[str, Any] | None,
    *,
    category: str,
    source_file: str,
    source_index: int,
) -> dict[str, Any]:
    case_id = _nonempty_string(question.get("id"), "BFCL id")
    if answer is not None and answer.get("id") != case_id:
        raise AdapterError(f"BFCL question/gold ID가 다릅니다: {case_id}")
    if answer is None and "irrelevance" in category:
        function_calls: Any = []
        label_available = True
    elif answer is None:
        function_calls = None
        label_available = False
    else:
        function_calls = answer.get("ground_truth")
        label_available = True
    metrics = ["tool_selection_exact_match", "argument_exact_match"]
    if "irrelevance" in category:
        metrics.append("no_call_accuracy")
    return _case(
        dataset_id="EVAL-FC-BFCL-V4",
        source_record_id=case_id,
        split="benchmark",
        roles=["A1"],
        task_family="function_calling",
        supported_metrics=metrics,
        input_value={
            "upstream_case": {
                key: value for key, value in question.items() if key != "id"
            }
        },
        gold={
            "label_available": label_available,
            "function_calls": function_calls,
            "must_not_call": "irrelevance" in category,
        },
        raw_for_hash={"question": question, "answer": answer},
        locator={"file": source_file, "record_index": source_index},
        source_extra={"category": category},
    )


def _masked_text(value: Any, name: str, birthday: str) -> Any:
    if not isinstance(value, str):
        return value
    result = value
    if name:
        result = result.replace(name, "[PATIENT]")
    if birthday:
        result = result.replace(birthday, "[DATE_OF_BIRTH]")
    return result


def normalize_longhealth_cases(
    benchmark: Mapping[str, Any], *, source_file: str
) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    for patient_key in sorted(benchmark):
        patient = benchmark[patient_key]
        if not isinstance(patient, dict):
            raise AdapterError(f"LongHealth patient 형식이 잘못되었습니다: {patient_key}")
        texts = patient.get("texts")
        questions = patient.get("questions")
        if not isinstance(texts, dict) or not isinstance(questions, list):
            raise AdapterError(f"LongHealth texts/questions 형식 오류: {patient_key}")
        name = patient.get("name") if isinstance(patient.get("name"), str) else ""
        birthday = (
            patient.get("birthday") if isinstance(patient.get("birthday"), str) else ""
        )
        patient_alias = _stable_id("LH-PATIENT", patient_key, length=12)
        for index, question in enumerate(questions):
            if not isinstance(question, dict):
                raise AdapterError(f"LongHealth question 형식 오류: {patient_key}:{index}")
            number = question.get("No", index)
            options = {
                label: _masked_text(question.get(f"answer_{label.lower()}"), name, birthday)
                for label in OPTION_LABELS
            }
            if any(not isinstance(value, str) for value in options.values()):
                raise AdapterError(f"LongHealth option 형식 오류: {patient_key}:{number}")
            correct = _masked_text(question.get("correct"), name, birthday)
            if not isinstance(correct, str):
                raise AdapterError(f"LongHealth correct 형식 오류: {patient_key}:{number}")
            acceptable_labels = [
                label for label, option in options.items() if option.strip() == correct.strip()
            ]
            if not acceptable_labels:
                raise AdapterError(
                    f"LongHealth correct와 일치하는 option이 없습니다: {patient_key}:{number}"
                )
            locations = question.get("answer_location")
            if not isinstance(locations, dict):
                raise AdapterError(
                    f"LongHealth answer_location 형식 오류: {patient_key}:{number}"
                )
            for text_id, ranges in locations.items():
                if text_id not in texts or not isinstance(ranges, dict):
                    raise AdapterError(
                        f"LongHealth answer locator가 잘못되었습니다: {patient_key}:{number}"
                    )
                starts, ends = ranges.get("start"), ranges.get("end")
                if (
                    not isinstance(starts, list)
                    or not isinstance(ends, list)
                    or len(starts) != len(ends)
                ):
                    raise AdapterError(
                        f"LongHealth answer range가 잘못되었습니다: {patient_key}:{number}"
                    )
            record_id = f"{patient_key}:question_{number}"
            cases.append(
                _case(
                    dataset_id="EVAL-LONGHEALTH",
                    source_record_id=record_id,
                    split="evaluation",
                    roles=["A2"],
                    task_family="longitudinal_record_comprehension",
                    supported_metrics=[
                        "answer_accuracy",
                        "time_preservation_accuracy",
                        "negation_preservation_accuracy",
                        "fact_preservation_accuracy",
                    ],
                    input_value={
                        "patient_alias": patient_alias,
                        "question": _masked_text(question.get("question"), name, birthday),
                        "options": options,
                        "document_locator": {
                            "file": source_file,
                            "patient_key": patient_key,
                            "text_ids": sorted(texts),
                            "materialize_at_runtime": True,
                            "mask_fields": ["name", "birthday"],
                        },
                    },
                    gold={
                        "answer_text": correct,
                        "acceptable_option_labels": acceptable_labels,
                        "answer_location": locations,
                    },
                    raw_for_hash=question,
                    locator={
                        "file": source_file,
                        "patient_key": patient_key,
                        "question_index": index,
                    },
                    source_extra={
                        "fictional_patient": True,
                        "documents_materialized": False,
                        "direct_identifier_fields_omitted": ["name", "birthday"],
                        "canary_omitted": "canaray-string" in patient,
                    },
                )
            )
    return cases


def _pubmed_id(value: str) -> str:
    match = re.search(r"(?:pubmed/|/)(\d+)/?$", value)
    return f"PMID:{match.group(1)}" if match else value


def normalize_mirage_cases(
    benchmark: Mapping[str, Any],
    *,
    source_file: str,
    bioasq_gold: Mapping[str, Mapping[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    gold_index = bioasq_gold or {}
    for subset in sorted(benchmark):
        rows = benchmark[subset]
        if not isinstance(rows, dict):
            raise AdapterError(f"MIRAGE subset 형식이 잘못되었습니다: {subset}")
        for record_id in sorted(rows):
            row = rows[record_id]
            if not isinstance(row, dict):
                raise AdapterError(f"MIRAGE row 형식 오류: {subset}:{record_id}")
            retrieval: dict[str, Any] = {
                "labels_available": False,
                "document_ids": [],
                "snippet_locators": [],
            }
            metrics = ["rag_answer_accuracy", "retrieval_ablation_accuracy_delta"]
            raw_gold = gold_index.get(record_id) if subset == "bioasq" else None
            if raw_gold is not None:
                gold_question = raw_gold.get("question")
                if not isinstance(gold_question, dict):
                    raise AdapterError(f"BioASQ gold 형식 오류: {record_id}")
                snippets: list[dict[str, Any]] = []
                for snippet_index, snippet in enumerate(gold_question.get("snippets", [])):
                    if not isinstance(snippet, dict):
                        raise AdapterError(f"BioASQ snippet 형식 오류: {record_id}")
                    text = _nonempty_string(snippet.get("text"), "BioASQ snippet text")
                    snippets.append(
                        {
                            "document_id": _pubmed_id(str(snippet.get("document", ""))),
                            "begin_section": snippet.get("beginSection"),
                            "end_section": snippet.get("endSection"),
                            "offset_begin": snippet.get("offsetInBeginSection"),
                            "offset_end": snippet.get("offsetInEndSection"),
                            "text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
                            "source_file": raw_gold.get("source_file"),
                            "question_id": record_id,
                            "snippet_index": snippet_index,
                        }
                    )
                retrieval = {
                    "labels_available": True,
                    "document_ids": [
                        _pubmed_id(str(value))
                        for value in gold_question.get("documents", [])
                    ],
                    "snippet_locators": snippets,
                }
                metrics.extend(["document_recall_at_k", "mean_reciprocal_rank"])
            cases.append(
                _case(
                    dataset_id="EVAL-MIRAGE",
                    source_record_id=f"{subset}:{record_id}",
                    split="test",
                    roles=["A3"],
                    task_family="medical_rag_retrieval",
                    supported_metrics=metrics,
                    input_value={
                        "question": row.get("question"),
                        "options": row.get("options"),
                        "retrieval_query_policy": "question_only",
                        "retrieval_artifact_key": f"test_{record_id}",
                    },
                    gold={"answer_label": row.get("answer"), "retrieval": retrieval},
                    raw_for_hash={"benchmark": row, "bioasq_gold": raw_gold},
                    locator={"file": source_file, "subset": subset, "key": record_id},
                    source_extra={
                        "subset": subset,
                        "retrieved_snippets_materialized": False,
                    },
                )
            )
    return cases


def normalize_healthbench_case(
    row: Mapping[str, Any],
    *,
    variant: str,
    source_index: int,
    source_file: str | None = None,
) -> dict[str, Any]:
    prompt_id = _nonempty_string(row.get("prompt_id"), "HealthBench prompt_id")
    locator = {
        "file": source_file or f"{variant}.jsonl",
        "record_index": source_index,
    }
    common_extra = {"variant": variant, "canary_present": "canary" in row}
    if variant == "oss_meta_eval":
        completion_id = _nonempty_string(
            row.get("completion_id"), "HealthBench completion_id"
        )
        labels = row.get("binary_labels")
        if not isinstance(labels, list) or any(not isinstance(v, bool) for v in labels):
            raise AdapterError(f"HealthBench Meta binary_labels 오류: {completion_id}")
        positive_votes = sum(labels)
        return _case(
            dataset_id="EVAL-HEALTHBENCH",
            source_record_id=f"{prompt_id}:{completion_id}:{source_index}",
            split="oss_meta_eval",
            roles=["A5"],
            task_family="medical_response_verification",
            supported_metrics=[
                "rubric_judgment_accuracy",
                "false_approval_rate",
                "false_block_rate",
            ],
            input_value={
                "prompt": row.get("prompt"),
                "candidate_completion": row.get("completion"),
                "rubric": row.get("rubric"),
                "category": row.get("category"),
            },
            gold={
                "binary_labels": labels,
                "positive_votes": positive_votes,
                "negative_votes": len(labels) - positive_votes,
                "majority_label": positive_votes > len(labels) / 2,
            },
            raw_for_hash=row,
            locator=locator,
            source_extra=common_extra,
        )
    if variant not in {"oss_eval", "consensus", "hard"}:
        raise AdapterError(f"지원하지 않는 HealthBench variant입니다: {variant}")
    rubrics = row.get("rubrics")
    if not isinstance(rubrics, list):
        raise AdapterError(f"HealthBench rubrics 형식 오류: {prompt_id}")
    return _case(
        dataset_id="EVAL-HEALTHBENCH",
        source_record_id=f"{variant}:{prompt_id}:{source_index}",
        split=variant,
        roles=["A4"],
        task_family="medical_response_generation",
        supported_metrics=[
            "rubric_score",
            "medical_safety_violation_rate",
            "response_helpfulness_score",
        ],
        input_value={"prompt": row.get("prompt"), "example_tags": row.get("example_tags", [])},
        gold={
            "rubrics": rubrics,
            "ideal_completions_data": row.get("ideal_completions_data"),
        },
        raw_for_hash=row,
        locator=locator,
        source_extra=common_extra,
    )


def normalize_ragtruth_case(
    source: Mapping[str, Any],
    response: Mapping[str, Any],
    *,
    source_index: int,
    response_index: int,
) -> dict[str, Any]:
    source_id = _nonempty_string(source.get("source_id"), "RAGTruth source_id")
    response_id = str(response.get("id"))
    if str(response.get("source_id")) != source_id:
        raise AdapterError(f"RAGTruth source/response ID가 다릅니다: {response_id}")
    candidate = _nonempty_string(response.get("response"), "RAGTruth response")
    labels = response.get("labels")
    if not isinstance(labels, list):
        raise AdapterError(f"RAGTruth labels 형식 오류: {response_id}")
    normalized_labels: list[dict[str, Any]] = []
    for label_index, label in enumerate(labels):
        if not isinstance(label, dict):
            raise AdapterError(f"RAGTruth label 형식 오류: {response_id}:{label_index}")
        start, end, text = label.get("start"), label.get("end"), label.get("text")
        if (
            not isinstance(start, int)
            or not isinstance(end, int)
            or not isinstance(text, str)
            or start < 0
            or end < start
            or candidate[start:end] != text
        ):
            raise AdapterError(f"RAGTruth span 검증 실패: {response_id}:{label_index}")
        normalized_labels.append(dict(label))
    split = _nonempty_string(response.get("split"), "RAGTruth split")
    return _case(
        dataset_id="EVAL-RAGTRUTH",
        source_record_id=f"{source_id}:{response_id}",
        split=split,
        roles=["A5"],
        task_family="groundedness_verification",
        supported_metrics=[
            "hallucination_detection_f1",
            "hallucination_span_f1",
            "false_approval_rate",
        ],
        input_value={
            "task_type": source.get("task_type"),
            "source_name": source.get("source"),
            "source_context": source.get("source_info"),
            "prompt": source.get("prompt"),
            "candidate_response": candidate,
        },
        gold={
            "has_hallucination": bool(normalized_labels),
            "hallucination_spans": normalized_labels,
            "quality": response.get("quality"),
        },
        raw_for_hash={"source": source, "response": response},
        locator={
            "source_file": "dataset/source_info.jsonl",
            "source_record_index": source_index,
            "response_file": "dataset/response.jsonl",
            "response_record_index": response_index,
        },
        source_extra={
            "generator_model": response.get("model"),
            "temperature": response.get("temperature"),
        },
    )


def normalize_komedqa_case(
    row: Mapping[str, Any], *, source_index: int
) -> dict[str, Any]:
    qa_id = str(row.get("qa_id"))
    return _case(
        dataset_id="EVAL-KOMEDQA",
        source_record_id=qa_id,
        split="evaluation-reserved",
        roles=["KO"],
        task_family="korean_medical_language_qa",
        supported_metrics=[
            "answer_accuracy",
            "korean_medical_meaning_preservation",
        ],
        input_value={
            "question": row.get("question"),
            "question_type": row.get("q_type_name"),
            "domain": row.get("domain_name"),
        },
        gold={"answer": row.get("answer")},
        raw_for_hash=row,
        locator={
            "file": "data/korean/medqa_kr.jsonl",
            "record_index": source_index,
        },
        source_extra={"domain_code": row.get("domain"), "question_type_code": row.get("q_type")},
    )


def normalize_kormedmcqa_case(
    row: Mapping[str, Any],
    *,
    config: str,
    split: str,
    source_index: int,
) -> dict[str, Any]:
    answer = row.get("answer")
    if not isinstance(answer, int) or not 1 <= answer <= 5:
        raise AdapterError(
            f"KorMedMCQA answer는 1~5여야 합니다: {config}:{split}:{source_index}"
        )
    record_id = (
        f"{config}:{split}:{row.get('year')}:{row.get('period')}:{row.get('q_number')}"
    )
    return _case(
        dataset_id="EVAL-KORMEDMCQA",
        source_record_id=record_id,
        split=split,
        roles=["KO"],
        task_family="korean_medical_multiple_choice",
        supported_metrics=["answer_accuracy", "korean_medical_meaning_preservation"],
        input_value={
            "question": row.get("question"),
            "options": {label: row.get(label) for label in OPTION_LABELS},
            "subject": row.get("subject"),
        },
        gold={
            "answer_label": OPTION_LABELS[answer - 1],
            "answer_index_1_based": answer,
            "rationale": row.get("cot"),
        },
        raw_for_hash=row,
        locator={"config": config, "split": split, "record_index": source_index},
        source_extra={
            "config": config,
            "year": row.get("year"),
            "period": row.get("period"),
            "question_number": row.get("q_number"),
        },
    )


def _bfcl_run(source_root: Path) -> AdapterRun:
    data_dir = source_root / "bfcl_eval" / "data"
    possible_dir = data_dir / "possible_answer"
    format_sensitivity_path = data_dir / "BFCL_v4_format_sensitivity.json"
    question_files = sorted(
        (
            path
            for path in data_dir.glob("BFCL_v4_*.json")
            if path.name != format_sensitivity_path.name
        ),
        key=lambda path: path.name,
    )
    if not question_files:
        raise AdapterError(f"BFCL question 파일을 찾을 수 없습니다: {data_dir}")
    input_files = list(question_files)
    format_sensitivity_counts: dict[str, int] = {}
    if format_sensitivity_path.is_file():
        format_value = _load_json(format_sensitivity_path)
        if not isinstance(format_value, dict) or any(
            not isinstance(ids, list) for ids in format_value.values()
        ):
            raise AdapterError("BFCL format sensitivity selection 형식이 잘못되었습니다.")
        format_sensitivity_counts = {
            str(category): len(ids) for category, ids in format_value.items()
        }
        input_files.append(format_sensitivity_path)
    answer_paths = [possible_dir / path.name for path in question_files if (possible_dir / path.name).is_file()]
    input_files.extend(answer_paths)

    def generate() -> Iterator[dict[str, Any]]:
        for question_path in question_files:
            category = question_path.stem.removeprefix("BFCL_v4_")
            answer_path = possible_dir / question_path.name
            answers = _jsonl_index(answer_path, "id") if answer_path.is_file() else {}
            for index, question in enumerate(_iter_jsonl(question_path)):
                answer = answers.get(str(question.get("id")))
                yield normalize_bfcl_case(
                    question,
                    answer,
                    category=category,
                    source_file=question_path.relative_to(source_root).as_posix(),
                    source_index=index,
                )

    missing_gold = [
        path.stem.removeprefix("BFCL_v4_")
        for path in question_files
        if not (possible_dir / path.name).is_file() and "irrelevance" not in path.stem
    ]
    return AdapterRun(
        cases=generate(),
        input_files=input_files,
        metadata={
            "categories_without_direct_gold": missing_gold,
            "format_sensitivity_selection_counts": format_sensitivity_counts,
            "format_sensitivity_file_is_selection_metadata": True,
        },
        blocking_issues=["LICENSE_REVIEW_REQUIRED"],
    )


def _longhealth_run(source_root: Path) -> AdapterRun:
    path = source_root / "data" / "benchmark_v5.json"
    benchmark = _load_json(path)
    if not isinstance(benchmark, dict):
        raise AdapterError("LongHealth benchmark 최상위 값은 object여야 합니다.")
    return AdapterRun(
        cases=normalize_longhealth_cases(
            benchmark, source_file=path.relative_to(source_root).as_posix()
        ),
        input_files=[path],
        metadata={
            "documents_materialized": False,
            "runtime_loader_required": True,
            "upstream_no_public_example_request_preserved": True,
        },
    )


def _load_bioasq_gold(source_root: Path) -> tuple[dict[str, dict[str, Any]], list[Path]]:
    paths = sorted(
        (source_root / "rawdata" / "bioasq").glob("Task*/*_golden.json"),
        key=lambda path: path.as_posix(),
    )
    index: dict[str, dict[str, Any]] = {}
    for path in paths:
        value = _load_json(path)
        questions = value.get("questions") if isinstance(value, dict) else None
        if not isinstance(questions, list):
            raise AdapterError(f"BioASQ questions 형식 오류: {path}")
        for question in questions:
            if not isinstance(question, dict) or question.get("type") != "yesno":
                continue
            question_id = _nonempty_string(question.get("id"), "BioASQ question id")
            if question_id in index:
                raise AdapterError(f"BioASQ question ID 중복: {question_id}")
            index[question_id] = {
                "source_file": path.relative_to(source_root).as_posix(),
                "question": question,
            }
    return index, paths


def _discover_mirage_profiles(source_root: Path) -> list[dict[str, str]]:
    root = source_root / "retrieved_snippets_10k"
    profiles: list[dict[str, str]] = []
    if not root.is_dir():
        return profiles
    for subset_dir in sorted((p for p in root.iterdir() if p.is_dir()), key=lambda p: p.name):
        for corpus_dir in sorted(
            (p for p in subset_dir.iterdir() if p.is_dir()), key=lambda p: p.name
        ):
            for retriever_dir in sorted(
                (p for p in corpus_dir.iterdir() if p.is_dir()), key=lambda p: p.name
            ):
                if (retriever_dir / "scores").is_dir() and (retriever_dir / "snippets").is_dir():
                    profiles.append(
                        {
                            "subset": subset_dir.name,
                            "corpus": corpus_dir.name,
                            "retriever": retriever_dir.name,
                            "score_template": (
                                retriever_dir.relative_to(source_root).as_posix()
                                + "/scores/{artifact_key}.json"
                            ),
                            "snippet_id_template": (
                                retriever_dir.relative_to(source_root).as_posix()
                                + "/snippets/{artifact_key}.json"
                            ),
                        }
                    )
    return profiles


def _mirage_run(source_root: Path) -> AdapterRun:
    benchmark_path = source_root / "benchmark.json"
    benchmark = _load_json(benchmark_path)
    if not isinstance(benchmark, dict):
        raise AdapterError("MIRAGE benchmark 최상위 값은 object여야 합니다.")
    bioasq, bioasq_paths = _load_bioasq_gold(source_root)
    profiles = _discover_mirage_profiles(source_root)
    return AdapterRun(
        cases=normalize_mirage_cases(
            benchmark,
            source_file=benchmark_path.relative_to(source_root).as_posix(),
            bioasq_gold=bioasq,
        ),
        input_files=[benchmark_path, *bioasq_paths],
        metadata={
            "retrieval_profiles": profiles,
            "retrieval_payloads_materialized": False,
            "retrieval_payload_root": "retrieved_snippets_10k",
            "bioasq_gold_question_count": len(bioasq),
            "non_bioasq_retrieval_relevance_labels_available": False,
        },
        blocking_issues=["COMPONENT_DATASET_RIGHTS_REVIEW_REQUIRED"],
    )


HEALTHBENCH_FILES = {
    "2025-05-07-06-14-12_oss_eval.jsonl": "oss_eval",
    "2025-05-07-06-14-12_oss_meta_eval.jsonl": "oss_meta_eval",
    "consensus_2025-05-09-20-00-46.jsonl": "consensus",
    "hard_2025-05-08-21-00-10.jsonl": "hard",
}


def _healthbench_run(source_root: Path) -> AdapterRun:
    paths = [source_root / filename for filename in HEALTHBENCH_FILES]
    missing = [path for path in paths if not path.is_file()]
    if missing:
        raise AdapterError(f"HealthBench 필수 파일이 없습니다: {missing[0]}")

    def generate() -> Iterator[dict[str, Any]]:
        for path in paths:
            variant = HEALTHBENCH_FILES[path.name]
            for index, row in enumerate(_iter_jsonl(path)):
                yield normalize_healthbench_case(
                    row,
                    variant=variant,
                    source_index=index,
                    source_file=path.name,
                )

    return AdapterRun(cases=generate(), input_files=paths)


def _ragtruth_run(source_root: Path) -> AdapterRun:
    source_path = source_root / "dataset" / "source_info.jsonl"
    response_path = source_root / "dataset" / "response.jsonl"
    sources: dict[str, tuple[int, dict[str, Any]]] = {}
    for index, source in enumerate(_iter_jsonl(source_path)):
        source_id = _nonempty_string(source.get("source_id"), "RAGTruth source_id")
        if source_id in sources:
            raise AdapterError(f"RAGTruth source_id 중복: {source_id}")
        sources[source_id] = (index, source)

    def generate() -> Iterator[dict[str, Any]]:
        for response_index, response in enumerate(_iter_jsonl(response_path)):
            source_id = str(response.get("source_id"))
            if source_id not in sources:
                raise AdapterError(f"RAGTruth source가 없습니다: {source_id}")
            source_index, source = sources[source_id]
            yield normalize_ragtruth_case(
                source,
                response,
                source_index=source_index,
                response_index=response_index,
            )

    return AdapterRun(
        cases=generate(),
        input_files=[source_path, response_path],
        blocking_issues=["UPSTREAM_SOURCE_CORPORA_RIGHTS_REVIEW_REQUIRED"],
    )


def _komedqa_run(source_root: Path) -> AdapterRun:
    path = source_root / "data" / "korean" / "medqa_kr.jsonl"

    def generate() -> Iterator[dict[str, Any]]:
        for index, row in enumerate(_iter_jsonl(path)):
            yield normalize_komedqa_case(row, source_index=index)

    return AdapterRun(cases=generate(), input_files=[path])


def _kormedmcqa_run(source_root: Path) -> AdapterRun:
    try:
        from datasets import load_from_disk  # type: ignore[import-not-found]
    except ImportError as exc:
        raise AdapterError(
            "KorMedMCQA Arrow를 읽으려면 datasets 패키지가 필요합니다. "
            "현재 프로젝트의 care_app conda 환경에서 실행하세요."
        ) from exc
    configs = [name for name in ("dentist", "doctor", "nurse", "pharm") if (source_root / name).is_dir()]
    if set(configs) != {"dentist", "doctor", "nurse", "pharm"}:
        raise AdapterError("KorMedMCQA dentist/doctor/nurse/pharm 구성이 모두 필요합니다.")
    input_files = sorted(
        (path for config in configs for path in (source_root / config).rglob("*") if path.is_file()),
        key=lambda path: path.as_posix(),
    )

    def generate() -> Iterator[dict[str, Any]]:
        for config in configs:
            dataset = load_from_disk(str(source_root / config))
            for split in ("train", "dev", "test", "fewshot"):
                if split not in dataset:
                    continue
                for index, row in enumerate(dataset[split]):
                    yield normalize_kormedmcqa_case(
                        row,
                        config=config,
                        split=split,
                        source_index=index,
                    )

    return AdapterRun(
        cases=generate(),
        input_files=input_files,
        metadata={
            "configs": configs,
            "all_upstream_splits_reserved_for_evaluation": True,
            "commercial_restriction": "CC-BY-NC-2.0; never include in product assets",
        },
    )


RUNNERS = {
    "bfcl": _bfcl_run,
    "healthbench": _healthbench_run,
    "komedqa": _komedqa_run,
    "kormedmcqa": _kormedmcqa_run,
    "longhealth": _longhealth_run,
    "mirage": _mirage_run,
    "ragtruth": _ragtruth_run,
}


def _safe_path(workspace_root: Path, path: Path) -> Path:
    root = workspace_root.resolve()
    resolved = path.resolve()
    if not resolved.is_relative_to(root):
        raise AdapterError(f"workspace 밖의 경로는 사용할 수 없습니다: {path}")
    return resolved


def _relative(workspace_root: Path, path: Path) -> str:
    return _safe_path(workspace_root, path).relative_to(workspace_root.resolve()).as_posix()


def _load_source_lock(
    workspace_root: Path, source_name: str, lock_manifest_path: Path
) -> tuple[dict[str, Any], Path, Path]:
    lock_path = _safe_path(workspace_root, lock_manifest_path)
    lock = _load_json(lock_path)
    if not isinstance(lock, dict):
        raise AdapterError("data source lock 최상위 값은 object여야 합니다.")
    policy = lock.get("policy")
    if (
        not isinstance(policy, dict)
        or policy.get("public_benchmarks_are_project_evaluation_only") is not True
        or policy.get("evaluation_data_must_not_be_used_for_finetuning") is not True
    ):
        raise AdapterError("data source lock의 평가 전용/do-not-train 정책이 없습니다.")
    wanted_id = ADAPTER_DATASET_IDS[source_name]
    entries = [
        entry
        for entry in lock.get("data_sources", [])
        if isinstance(entry, dict) and entry.get("id") == wanted_id
    ]
    if len(entries) != 1:
        raise AdapterError(f"data source lock에서 {wanted_id}를 정확히 하나 찾아야 합니다.")
    entry = entries[0]
    usage = entry.get("usage")
    if (
        not isinstance(usage, dict)
        or usage.get("do_not_train") is not True
        or usage.get("mobile_bundle") is not False
        or usage.get("runtime_rag_eligible") is not False
    ):
        raise AdapterError(f"{wanted_id}의 사용 경계가 안전하지 않습니다.")
    local_path = _nonempty_string(entry.get("local_path"), f"{wanted_id}.local_path")
    source_root = _safe_path(workspace_root, workspace_root / local_path)
    if not source_root.is_dir():
        raise AdapterError(f"source directory를 찾을 수 없습니다: {source_root}")
    return entry, source_root, lock_path


def _input_metadata(workspace_root: Path, paths: Sequence[Path]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    seen: set[Path] = set()
    for path in sorted((item.resolve() for item in paths), key=lambda item: item.as_posix()):
        if path in seen:
            continue
        seen.add(path)
        result.append(
            {
                "file": _relative(workspace_root, path),
                "bytes": path.stat().st_size,
                "sha256": _sha256_file(path),
            }
        )
    return result


def adapt_evaluation_source(
    workspace_root: Path,
    source_name: str,
    output_dir: Path,
    *,
    lock_manifest_path: Path = DEFAULT_LOCK_MANIFEST,
    limit: int | None = None,
) -> Path:
    """Adapt one locked public source and write a non-scoreable candidate bundle."""

    workspace_root = workspace_root.resolve()
    if source_name not in RUNNERS:
        raise AdapterError(f"지원하지 않는 source adapter입니다: {source_name}")
    if limit is not None and limit <= 0:
        raise AdapterError("limit은 양의 정수여야 합니다.")
    output = _safe_path(workspace_root, output_dir)
    if output.exists():
        raise AdapterError(f"출력 경로가 이미 존재합니다: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    lock_entry, source_root, lock_path = _load_source_lock(
        workspace_root, source_name, lock_manifest_path
    )
    run = RUNNERS[source_name](source_root)
    temp_dir = Path(tempfile.mkdtemp(prefix=f".{output.name}-", dir=output.parent))
    iterator = iter(run.cases)
    count = 0
    case_ids: set[str] = set()
    role_counts: Counter[str] = Counter()
    cases_digest = hashlib.sha256()
    cases_path = temp_dir / "cases.jsonl"
    is_partial = False
    try:
        with cases_path.open("wb") as stream:
            while limit is None or count < limit:
                try:
                    case = next(iterator)
                except StopIteration:
                    break
                case_id = _nonempty_string(case.get("case_id"), "case_id")
                if case_id in case_ids:
                    raise AdapterError(f"중복 case_id가 생성되었습니다: {case_id}")
                case_ids.add(case_id)
                roles = case.get("target", {}).get("roles", [])
                role_counts.update(role for role in roles if isinstance(role, str))
                encoded = _canonical_bytes(case) + b"\n"
                stream.write(encoded)
                cases_digest.update(encoded)
                count += 1
            if limit is not None:
                try:
                    next(iterator)
                except StopIteration:
                    is_partial = False
                else:
                    is_partial = True
        close = getattr(iterator, "close", None)
        if callable(close):
            close()
        if count == 0:
            raise AdapterError(f"{source_name} adapter가 case를 생성하지 못했습니다.")
        blocking_issues = ["ADAPTER_OUTPUT_UNREVIEWED", *run.blocking_issues]
        if is_partial:
            blocking_issues.append("PARTIAL_ADAPTER_OUTPUT")
        cases_size = cases_path.stat().st_size
        integrity = lock_entry.get("integrity")
        tree_sha256 = integrity.get("tree_sha256") if isinstance(integrity, dict) else None
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "adapter": {
                "script": "scripts/adapt_evaluation_sources.py",
                "version": SCRIPT_VERSION,
                "source_name": source_name,
                "network_access": False,
            },
            "source_lock": {
                "manifest_file": _relative(workspace_root, lock_path),
                "manifest_sha256": _sha256_file(lock_path),
                "dataset_id": lock_entry.get("id"),
                "dataset_name": lock_entry.get("name"),
                "locked_tree_sha256": tree_sha256,
                "license": lock_entry.get("license"),
                "roles": lock_entry.get("roles"),
            },
            "input_files": _input_metadata(workspace_root, run.input_files),
            "record_count": count,
            "role_counts": dict(sorted(role_counts.items())),
            "is_partial": is_partial,
            "review_status": "adapter_generated_unreviewed",
            "evaluation_eligible": False,
            "project_end_to_end_score_eligible": False,
            "blocking_issues": list(dict.fromkeys(blocking_issues)),
            "usage": _policy(),
            "content_policy": {
                "component_benchmark_only": True,
                "not_medical_knowledge": True,
                "not_scenario_compiler_input": True,
                "source_splits_preserved": True,
                "raw_canaries_omitted_from_cases": True,
            },
            "source_specific": run.metadata,
            "outputs": [
                {
                    "file": "cases.jsonl",
                    "bytes": cases_size,
                    "sha256": cases_digest.hexdigest(),
                    "record_count": count,
                }
            ],
        }
        (temp_dir / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
            newline="\n",
        )
        os.replace(temp_dir, output)
    except Exception:
        shutil.rmtree(temp_dir, ignore_errors=True)
        raise
    return output


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="공개 평가 원천을 공통 component-evaluation case로 정규화합니다."
    )
    parser.add_argument("--source", required=True, choices=sorted(RUNNERS))
    parser.add_argument("--workspace-root", type=Path, default=Path.cwd())
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--lock-manifest", type=Path, default=DEFAULT_LOCK_MANIFEST)
    parser.add_argument(
        "--limit",
        type=int,
        help="adapter smoke test용 상한. 제한 출력은 평가에 사용할 수 없습니다.",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    workspace_root = args.workspace_root.resolve()
    output_dir = args.output_dir
    if not output_dir.is_absolute():
        output_dir = workspace_root / output_dir
    lock_manifest = args.lock_manifest
    if not lock_manifest.is_absolute():
        lock_manifest = workspace_root / lock_manifest
    try:
        result = adapt_evaluation_source(
            workspace_root,
            args.source,
            output_dir,
            lock_manifest_path=lock_manifest,
            limit=args.limit,
        )
    except AdapterError as exc:
        print(f"오류: {exc}")
        return 1
    manifest = _load_json(result / "manifest.json")
    print(f"완료: {result}")
    print(f"source: {args.source}")
    print(f"cases: {manifest['record_count']}")
    print(f"partial: {manifest['is_partial']}")
    print("evaluation_eligible: false (사람 검수·봉인 전)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
