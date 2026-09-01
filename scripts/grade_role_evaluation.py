#!/usr/bin/env python3
"""Grade role component responses with upstream-supported deterministic metrics."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Sequence

try:
    from scripts.role_evaluation_harness import HarnessError, grade_response_bundle
except ModuleNotFoundError:  # Direct execution: python scripts/<name>.py
    from role_evaluation_harness import HarnessError, grade_response_bundle


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="role component response를 결정적으로 채점합니다."
    )
    parser.add_argument("--case-bundle", type=Path, required=True)
    parser.add_argument("--request-bundle", type=Path, required=True)
    parser.add_argument("--response-bundle", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--workspace-root", type=Path, default=Path.cwd())
    parser.add_argument("--judgments-jsonl", type=Path)
    parser.add_argument("--retrieval-k", type=int, default=10)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    root = args.workspace_root.resolve()

    def resolve(path: Path) -> Path:
        return path if path.is_absolute() else root / path

    try:
        result = grade_response_bundle(
            root,
            resolve(args.case_bundle),
            resolve(args.request_bundle),
            resolve(args.response_bundle),
            resolve(args.output_dir),
            judgments_path=resolve(args.judgments_jsonl)
            if args.judgments_jsonl
            else None,
            retrieval_k=args.retrieval_k,
        )
    except HarnessError as exc:
        print(f"오류: {exc}")
        return 1
    summary = json.loads((result / "summary.json").read_text(encoding="utf-8"))
    print(f"완료: {result}")
    print(f"scored: {summary['scored_responses']}/{summary['total_responses']}")
    print(f"metrics: {summary['metric_means']}")
    print("official_benchmark_result: false")
    print("project_end_to_end_result: false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
