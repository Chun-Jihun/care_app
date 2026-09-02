#!/usr/bin/env python3
"""Run role component requests with an offline local backend."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Sequence

try:
    from scripts.ds_agent_model_runner import ModelRunnerError, Qwen35Nf4Backend
    from scripts.role_evaluation_harness import (
        HarnessError,
        MirageCachedRetrievalBackend,
        ReplayBackend,
        TransformersLocalBackend,
        run_request_bundle,
    )
except ModuleNotFoundError:  # Direct execution: python scripts/<name>.py
    from ds_agent_model_runner import ModelRunnerError, Qwen35Nf4Backend  # type: ignore
    from role_evaluation_harness import (
        HarnessError,
        MirageCachedRetrievalBackend,
        ReplayBackend,
        TransformersLocalBackend,
        run_request_bundle,
    )


def _within(root: Path, path: Path) -> Path:
    resolved = path.resolve()
    if not resolved.is_relative_to(root.resolve()):
        raise HarnessError(f"workspace 밖의 경로는 사용할 수 없습니다: {path}")
    return resolved


def _load_replay(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    try:
        with path.open("r", encoding="utf-8-sig") as stream:
            for line_number, line in enumerate(stream, 1):
                if not line.strip():
                    raise HarnessError(f"replay JSONL에 빈 행이 있습니다: {line_number}")
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise HarnessError(f"replay 행은 object여야 합니다: {line_number}")
                request_id, raw_text = value.get("request_id"), value.get("raw_text")
                if not isinstance(request_id, str) or not isinstance(raw_text, str):
                    raise HarnessError(
                        f"replay request_id/raw_text 형식 오류: {line_number}"
                    )
                if request_id in result:
                    raise HarnessError(f"replay request_id 중복: {request_id}")
                result[request_id] = raw_text
    except FileNotFoundError as exc:
        raise HarnessError(f"replay 파일을 찾을 수 없습니다: {path}") from exc
    except json.JSONDecodeError as exc:
        raise HarnessError(f"replay JSON 형식 오류: {exc}") from exc
    return result


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="역할별 request bundle을 외부 전송 없이 로컬에서 실행합니다."
    )
    parser.add_argument("--request-bundle", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--workspace-root", type=Path, default=Path.cwd())
    subparsers = parser.add_subparsers(dest="backend", required=True)

    replay = subparsers.add_parser("replay", help="다른 로컬 엔진의 JSONL 출력을 재생")
    replay.add_argument("--replay-jsonl", type=Path, required=True)

    mirage = subparsers.add_parser(
        "mirage-cache", help="MIRAGE의 다운로드된 순위 artifact를 실행"
    )
    mirage.add_argument("--source-root", type=Path, default=Path("data/MIRAGE"))
    mirage.add_argument("--corpus", required=True)
    mirage.add_argument("--retriever", required=True)
    mirage.add_argument("--top-k", type=int, default=10)

    transformers = subparsers.add_parser(
        "transformers", help="로컬 Transformers 모델 실행(의존성·메모리 준비 필요)"
    )
    transformers.add_argument("--model-path", type=Path, default=Path("models/qwen3.5_4b"))
    transformers.add_argument("--max-new-tokens", type=int, default=512)
    transformers.add_argument("--temperature", type=float, default=0.0)
    transformers.add_argument("--device-map", default="auto")
    qwen = subparsers.add_parser(
        "qwen35-nf4", help="잠금된 Qwen3.5-4B Transformers+bitsandbytes NF4 프로필"
    )
    qwen.add_argument(
        "--runtime-profile",
        type=Path,
        default=Path("experiments/agent_eval/manifests/runtime_profiles.json"),
    )
    qwen.add_argument("--runtime-profile-id", default="RT-M1-HF-BNB-NF4-WIN-001")
    qwen.add_argument(
        "--generation-profile",
        choices=("smoke", "primary_scored", "supplier_recommended_secondary"),
        default="primary_scored",
    )
    qwen.add_argument("--seed", type=int)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    root = args.workspace_root.resolve()
    request_bundle = _within(
        root,
        args.request_bundle if args.request_bundle.is_absolute() else root / args.request_bundle,
    )
    output = _within(
        root, args.output_dir if args.output_dir.is_absolute() else root / args.output_dir
    )
    try:
        if args.backend == "replay":
            replay_path = _within(
                root,
                args.replay_jsonl
                if args.replay_jsonl.is_absolute()
                else root / args.replay_jsonl,
            )
            responses = _load_replay(replay_path)
            backend = ReplayBackend(
                responses,
                replay_id="sha256:" + hashlib.sha256(replay_path.read_bytes()).hexdigest(),
            )
        elif args.backend == "mirage-cache":
            source_root = _within(
                root,
                args.source_root if args.source_root.is_absolute() else root / args.source_root,
            )
            backend = MirageCachedRetrievalBackend(
                source_root,
                corpus=args.corpus,
                retriever=args.retriever,
                top_k=args.top_k,
            )
        elif args.backend == "transformers":
            model_path = _within(
                root,
                args.model_path if args.model_path.is_absolute() else root / args.model_path,
            )
            backend = TransformersLocalBackend(
                model_path,
                max_new_tokens=args.max_new_tokens,
                temperature=args.temperature,
                device_map=args.device_map,
            )
        else:
            profile_path = _within(
                root,
                args.runtime_profile
                if args.runtime_profile.is_absolute()
                else root / args.runtime_profile,
            )
            backend = Qwen35Nf4Backend(
                root,
                profile_path,
                profile_id=args.runtime_profile_id,
                generation_profile=args.generation_profile,
                seed=args.seed,
            )
        result = run_request_bundle(root, request_bundle, output, backend)
    except (HarnessError, ModelRunnerError) as exc:
        print(f"오류: {exc}")
        return 1
    manifest = json.loads((result / "manifest.json").read_text(encoding="utf-8"))
    print(f"완료: {result}")
    print(f"responses: {manifest['record_count']}")
    print(f"status: {manifest['status_counts']}")
    print("network_access: false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
