#!/usr/bin/env python3
"""Render adapted public cases into A1~A5/KO component requests."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Sequence

try:
    from scripts.role_evaluation_harness import HarnessError, render_request_bundle
except ModuleNotFoundError:  # Direct execution: python scripts/<name>.py
    from role_evaluation_harness import HarnessError, render_request_bundle


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="source adapter case를 역할별 component request bundle로 렌더링합니다."
    )
    parser.add_argument("--case-bundle", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--role", required=True, choices=("A1", "A2", "A3", "A4", "A5", "KO"))
    parser.add_argument("--workspace-root", type=Path, default=Path.cwd())
    parser.add_argument("--limit", type=int, help="smoke 실행용 문항 상한")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    root = args.workspace_root.resolve()
    case_bundle = args.case_bundle if args.case_bundle.is_absolute() else root / args.case_bundle
    output = args.output_dir if args.output_dir.is_absolute() else root / args.output_dir
    try:
        result = render_request_bundle(
            root,
            case_bundle,
            output,
            role_id=args.role,
            limit=args.limit,
        )
    except HarnessError as exc:
        print(f"오류: {exc}")
        return 1
    manifest = json.loads((result / "manifest.json").read_text(encoding="utf-8"))
    print(f"완료: {result}")
    print(f"role: {args.role}")
    print(f"requests: {manifest['record_count']}")
    print(f"projection_supported: {manifest['projection_supported_case_count']}")
    print(f"skipped: {manifest['skipped_case_count']}")
    print(f"partial: {manifest['is_partial']}")
    print("mode: component_projection (DS-AGENT E2E 결과 아님)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
