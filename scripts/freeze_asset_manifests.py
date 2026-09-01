#!/usr/bin/env python3
"""Create deterministic lock manifests for local model and dataset assets.

The command never accesses the network. Model files are recorded individually.
Dataset directories use a compact content-tree SHA-256 that incorporates every
included file's relative path, byte length, and SHA-256 digest.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterator, Mapping, Sequence


SCRIPT_VERSION = "0.1.0"
DEFAULT_CATALOG = Path("experiments/agent_eval/manifests/asset_sources.json")
DEFAULT_OUTPUT_DIR = Path("experiments/agent_eval/manifests")
EXCLUDED_DIRECTORY_NAMES = {".git", ".cache", "__pycache__"}
EXCLUDED_FILE_NAMES = {".DS_Store", "Thumbs.db", ".env"}
ProgressCallback = Callable[[int, int], None]


class ManifestError(RuntimeError):
    """Raised when an asset cannot be locked safely or consistently."""


@dataclass(frozen=True)
class DirectoryDigest:
    tree_sha256: str
    file_count: int
    total_bytes: int


def sha256_file(path: Path, *, chunk_size: int = 4 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(chunk_size):
            digest.update(chunk)
    return digest.hexdigest()


def _is_excluded_file(name: str) -> bool:
    return name in EXCLUDED_FILE_NAMES or name.startswith(".env.") or name.endswith(".tmp")


def iter_asset_files(root: Path) -> Iterator[Path]:
    """Yield asset files in a deterministic traversal without following links."""

    if not root.is_dir():
        raise ManifestError(f"자산 디렉터리를 찾을 수 없습니다: {root}")

    for current, directory_names, file_names in os.walk(root, followlinks=False):
        directory_names[:] = sorted(
            name for name in directory_names if name not in EXCLUDED_DIRECTORY_NAMES
        )
        file_names.sort()
        current_path = Path(current)

        for directory_name in directory_names:
            directory = current_path / directory_name
            if directory.is_symlink():
                raise ManifestError(f"심볼릭 링크 디렉터리는 lock 대상이 될 수 없습니다: {directory}")

        for file_name in file_names:
            if _is_excluded_file(file_name):
                continue
            path = current_path / file_name
            if path.is_symlink():
                raise ManifestError(f"심볼릭 링크 파일은 lock 대상이 될 수 없습니다: {path}")
            if path.is_file():
                yield path


def _tree_record(relative_path: str, size: int, content_sha256: str) -> bytes:
    record = [relative_path, size, content_sha256]
    return json.dumps(record, ensure_ascii=True, separators=(",", ":")).encode("utf-8") + b"\n"


def hash_directory(
    root: Path,
    *,
    progress: ProgressCallback | None = None,
    workers: int = 1,
) -> DirectoryDigest:
    """Hash every included byte into one compact deterministic tree digest."""

    if workers < 1:
        raise ManifestError("hash workers는 1 이상이어야 합니다.")

    def hash_entry(path: Path) -> tuple[str, int, str]:
        relative_path = path.relative_to(root).as_posix()
        size = path.stat().st_size
        return relative_path, size, sha256_file(path)

    def batches(iterator: Iterator[Path], batch_size: int) -> Iterator[list[Path]]:
        batch: list[Path] = []
        for item in iterator:
            batch.append(item)
            if len(batch) == batch_size:
                yield batch
                batch = []
        if batch:
            yield batch

    digest = hashlib.sha256()
    file_count = 0
    total_bytes = 0
    with ThreadPoolExecutor(max_workers=workers) as executor:
        for batch in batches(iter_asset_files(root), workers * 16):
            # executor.map preserves input order, so the tree digest remains
            # identical regardless of worker scheduling.
            for relative_path, size, content_sha256 in executor.map(hash_entry, batch):
                digest.update(_tree_record(relative_path, size, content_sha256))
                file_count += 1
                total_bytes += size
                if progress is not None:
                    progress(file_count, total_bytes)
    return DirectoryDigest(digest.hexdigest(), file_count, total_bytes)


def load_catalog(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError as exc:
        raise ManifestError(f"자산 선언 파일을 찾을 수 없습니다: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ManifestError(f"자산 선언 JSON 형식이 잘못되었습니다: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ManifestError("자산 선언 최상위 값은 JSON object여야 합니다.")
    if not isinstance(value.get("models"), list) or not isinstance(
        value.get("data_sources"), list
    ):
        raise ManifestError("자산 선언에는 models와 data_sources 배열이 필요합니다.")
    return value


def _safe_asset_path(workspace_root: Path, value: Any) -> tuple[str, Path]:
    if not isinstance(value, str) or not value.strip():
        raise ManifestError("local_path는 비어 있지 않은 문자열이어야 합니다.")
    normalized = value.replace("\\", "/")
    pure = PurePosixPath(normalized)
    if pure.is_absolute() or ".." in pure.parts:
        raise ManifestError(f"workspace 밖을 가리키는 local_path는 허용하지 않습니다: {value}")
    relative = pure.as_posix()
    root = workspace_root.resolve()
    resolved = (root / Path(*pure.parts)).resolve()
    if not resolved.is_relative_to(root):
        raise ManifestError(f"workspace 밖을 가리키는 local_path는 허용하지 않습니다: {value}")
    return relative, resolved


def _copy_declared_fields(declaration: Mapping[str, Any], excluded: set[str]) -> dict[str, Any]:
    return {
        key: json.loads(json.dumps(value, ensure_ascii=False))
        for key, value in declaration.items()
        if key not in excluded
    }


def _detect_huggingface_revision(model_path: Path) -> tuple[str | None, str]:
    tree_dir = model_path / ".cache" / "huggingface" / "trees"
    if not tree_dir.is_dir():
        return None, "unrecorded_at_download"
    candidates = sorted(path.stem for path in tree_dir.glob("*.json") if path.is_file())
    if len(candidates) == 1:
        return candidates[0], "huggingface_cache_tree_metadata"
    if not candidates:
        return None, "unrecorded_at_download"
    raise ManifestError(
        f"모델 캐시에 리비전 후보가 여러 개라 자동 고정할 수 없습니다: {model_path}"
    )


def _model_lock(workspace_root: Path, declaration: Mapping[str, Any]) -> dict[str, Any]:
    local_path, model_path = _safe_asset_path(workspace_root, declaration.get("local_path"))
    required = bool(declaration.get("required", True))
    base = _copy_declared_fields(declaration, {"local_path", "required"})
    base["local_path"] = local_path
    base["required"] = required
    if not model_path.exists():
        if required:
            raise ManifestError(f"필수 모델 자산이 없습니다: {local_path}")
        base["availability"] = "missing"
        return base

    revision, revision_source = _detect_huggingface_revision(model_path)
    expected_revision = declaration.get("expected_revision")
    if expected_revision and revision and expected_revision != revision:
        raise ManifestError(
            f"모델 리비전이 선언과 다릅니다: {local_path}: {revision} != {expected_revision}"
        )

    files: list[dict[str, Any]] = []
    total_bytes = 0
    for path in iter_asset_files(model_path):
        relative_path = path.relative_to(model_path).as_posix()
        size = path.stat().st_size
        files.append({"path": relative_path, "bytes": size, "sha256": sha256_file(path)})
        total_bytes += size

    if not files:
        raise ManifestError(f"모델 자산에 lock할 파일이 없습니다: {local_path}")
    base.update(
        {
            "availability": "present",
            "revision": revision,
            "revision_source": revision_source,
            "integrity": {
                "algorithm": "sha256",
                "coverage": "all_included_files_individually",
                "excluded_directory_names": sorted(EXCLUDED_DIRECTORY_NAMES),
                "excluded_file_names": sorted(EXCLUDED_FILE_NAMES),
                "file_count": len(files),
                "total_bytes": total_bytes,
            },
            "files": files,
        }
    )
    return base


def _load_raw_snapshot_approval(asset_path: Path, manifest_name: str) -> dict[str, Any]:
    manifest_path = asset_path / manifest_name
    try:
        raw = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError as exc:
        raise ManifestError(f"raw snapshot manifest가 없습니다: {manifest_path}") from exc
    except json.JSONDecodeError as exc:
        raise ManifestError(f"raw snapshot manifest JSON이 잘못되었습니다: {manifest_path}") from exc

    download = raw.get("download") or {}
    handling = raw.get("handling") or {}
    state = raw.get("approval_state")
    runtime_eligible = bool(handling.get("runtime_rag_eligible", False))
    if state != "raw_unreviewed" or runtime_eligible:
        raise ManifestError(
            "e약은요 raw snapshot은 raw_unreviewed이며 runtime RAG 비활성 상태여야 합니다."
        )
    return {
        "snapshot_id": raw.get("snapshot_id"),
        "state": state,
        "runtime_rag_eligible": runtime_eligible,
        "download_complete": bool(download.get("complete", False)),
        "page_count": download.get("page_count"),
        "downloaded_item_count": download.get("downloaded_item_count"),
        "raw_manifest_sha256": sha256_file(manifest_path),
    }


def _data_lock(
    workspace_root: Path,
    declaration: Mapping[str, Any],
    *,
    progress: ProgressCallback | None = None,
    hash_workers: int = 1,
) -> dict[str, Any]:
    local_path, asset_path = _safe_asset_path(workspace_root, declaration.get("local_path"))
    required = bool(declaration.get("required", True))
    base = _copy_declared_fields(
        declaration, {"local_path", "required", "raw_snapshot_manifest"}
    )
    base["local_path"] = local_path
    base["required"] = required
    if not asset_path.exists():
        if required:
            raise ManifestError(f"필수 데이터 자산이 없습니다: {local_path}")
        base["availability"] = "missing"
        return base

    usage = declaration.get("usage")
    if not isinstance(usage, dict):
        raise ManifestError(f"데이터 자산에 usage 정책이 필요합니다: {local_path}")
    for field in ("do_not_train", "mobile_bundle", "runtime_rag_eligible"):
        if field not in usage or not isinstance(usage[field], bool):
            raise ManifestError(f"데이터 usage.{field} boolean이 필요합니다: {local_path}")

    digest = hash_directory(asset_path, progress=progress, workers=hash_workers)
    base.update(
        {
            "availability": "present",
            "integrity": {
                "algorithm": "sha256-content-tree-v1",
                "canonical_record": "JSONL [relative_posix_path,byte_length,file_sha256]",
                "coverage": "all_included_file_content",
                "excluded_directory_names": sorted(EXCLUDED_DIRECTORY_NAMES),
                "excluded_file_names": sorted(EXCLUDED_FILE_NAMES),
                "tree_sha256": digest.tree_sha256,
                "file_count": digest.file_count,
                "total_bytes": digest.total_bytes,
            },
        }
    )
    raw_manifest_name = declaration.get("raw_snapshot_manifest")
    if raw_manifest_name:
        if not isinstance(raw_manifest_name, str):
            raise ManifestError("raw_snapshot_manifest는 문자열이어야 합니다.")
        base["approval"] = _load_raw_snapshot_approval(asset_path, raw_manifest_name)
    return base


def build_locks(
    workspace_root: Path,
    catalog: Mapping[str, Any],
    *,
    progress_factory: Callable[[str], ProgressCallback | None] | None = None,
    hash_workers: int = 1,
) -> tuple[dict[str, Any], dict[str, Any]]:
    model_ids: set[str] = set()
    models = []
    for declaration in catalog["models"]:
        if not isinstance(declaration, dict) or not declaration.get("id"):
            raise ManifestError("모든 모델 선언에는 id가 필요합니다.")
        if declaration["id"] in model_ids:
            raise ManifestError(f"중복 모델 ID입니다: {declaration['id']}")
        model_ids.add(declaration["id"])
        models.append(_model_lock(workspace_root, declaration))

    data_ids: set[str] = set()
    data_sources = []
    for declaration in catalog["data_sources"]:
        if not isinstance(declaration, dict) or not declaration.get("id"):
            raise ManifestError("모든 데이터 선언에는 id가 필요합니다.")
        if declaration["id"] in data_ids:
            raise ManifestError(f"중복 데이터 ID입니다: {declaration['id']}")
        data_ids.add(declaration["id"])
        progress = progress_factory(declaration["id"]) if progress_factory else None
        data_sources.append(
            _data_lock(
                workspace_root,
                declaration,
                progress=progress,
                hash_workers=hash_workers,
            )
        )

    common = {
        "schema_version": "1.0",
        "generator": {
            "script": "scripts/freeze_asset_manifests.py",
            "version": SCRIPT_VERSION,
            "network_access": False,
        },
        "license_checked_at": catalog.get("license_checked_at"),
    }
    models_lock = {**common, "models": models}
    data_lock = {
        **common,
        "policy": {
            "public_benchmarks_are_project_evaluation_only": True,
            "evaluation_data_must_not_be_used_for_finetuning": True,
            "raw_medical_sources_require_staging_and_clinical_approval": True,
            "mobile_bundle_requires_explicit_approved_snapshot": True,
        },
        "data_sources": data_sources,
    }
    return models_lock, data_lock


def _json_bytes(value: Mapping[str, Any]) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def _write_atomic(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with temporary.open("wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        if temporary.exists():
            temporary.unlink()


def _compare_or_write(path: Path, content: bytes, verify: bool) -> None:
    if verify:
        try:
            current = path.read_bytes()
        except FileNotFoundError as exc:
            raise ManifestError(f"검증할 lock 파일이 없습니다: {path}") from exc
        if current != content:
            raise ManifestError(f"자산 상태가 lock 파일과 다릅니다: {path}")
        return
    _write_atomic(path, content)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="로컬 모델과 평가·RAG 데이터의 결정적 SHA-256 lock manifest를 생성합니다."
    )
    parser.add_argument("--workspace-root", type=Path, default=Path("."))
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument(
        "--verify",
        action="store_true",
        help="파일을 쓰지 않고 현재 자산이 기존 lock과 동일한지 검증합니다.",
    )
    parser.add_argument(
        "--progress-every",
        type=int,
        default=5000,
        help="대용량 데이터 해싱 진행상황을 출력할 파일 간격입니다.",
    )
    parser.add_argument(
        "--hash-workers",
        type=int,
        default=4,
        help="파일 내용 해시에 사용할 제한된 worker 수입니다.",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.progress_every < 1 or args.hash_workers < 1:
        print("오류: --progress-every와 --hash-workers는 1 이상이어야 합니다.", file=sys.stderr)
        return 1

    workspace_root = args.workspace_root.resolve()
    catalog_path = args.catalog
    if not catalog_path.is_absolute():
        catalog_path = workspace_root / catalog_path
    output_dir = args.output_dir
    if not output_dir.is_absolute():
        output_dir = workspace_root / output_dir
    if not output_dir.resolve().is_relative_to(workspace_root):
        print("오류: output-dir은 workspace 내부여야 합니다.", file=sys.stderr)
        return 1

    def progress_factory(asset_id: str) -> ProgressCallback:
        last_reported = 0

        def report(file_count: int, total_bytes: int) -> None:
            nonlocal last_reported
            if file_count - last_reported >= args.progress_every:
                print(
                    f"[{asset_id}] {file_count:,} files, {total_bytes / (1024 ** 3):.2f} GiB hashed",
                    flush=True,
                )
                last_reported = file_count

        return report

    try:
        catalog = load_catalog(catalog_path)
        models_lock, data_lock = build_locks(
            workspace_root,
            catalog,
            progress_factory=progress_factory,
            hash_workers=args.hash_workers,
        )
        _compare_or_write(
            output_dir / "models.lock.json", _json_bytes(models_lock), args.verify
        )
        _compare_or_write(
            output_dir / "data_sources.lock.json", _json_bytes(data_lock), args.verify
        )
    except ManifestError as exc:
        print(f"오류: {exc}", file=sys.stderr)
        return 1

    action = "verified" if args.verify else "written"
    print(f"models.lock.json: {action}")
    print(f"data_sources.lock.json: {action}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
