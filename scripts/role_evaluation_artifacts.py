"""Verified local evaluation bundles and legacy component serialization."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
from typing import Any, Mapping

try:
    from scripts.role_evaluation_contracts import (
        HarnessError,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from role_evaluation_contracts import (
        HarnessError,
    )


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
        raise HarnessError(f"필수 파일을 찾을 수 없습니다: {path}") from exc
    return digest.hexdigest()

def _stable_id(prefix: str, *parts: object, length: int = 20) -> str:
    text = "\x1f".join(str(part) for part in parts).encode("utf-8")
    return f"{prefix}-{hashlib.sha256(text).hexdigest()[:length].upper()}"

def _nonempty_string(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise HarnessError(f"{name}이 비어 있습니다.")
    return value.strip()

def _load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError as exc:
        raise HarnessError(f"필수 JSON을 찾을 수 없습니다: {path}") from exc
    except json.JSONDecodeError as exc:
        raise HarnessError(f"JSON 형식이 잘못되었습니다: {path}: {exc}") from exc

def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as stream:
            for line_number, line in enumerate(stream, 1):
                if not line.strip():
                    raise HarnessError(f"JSONL에 빈 행이 있습니다: {path}:{line_number}")
                try:
                    value = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise HarnessError(
                        f"JSONL 형식이 잘못되었습니다: {path}:{line_number}: {exc}"
                    ) from exc
                if not isinstance(value, dict):
                    raise HarnessError(
                        f"JSONL 행은 object여야 합니다: {path}:{line_number}"
                    )
                values.append(value)
    except FileNotFoundError as exc:
        raise HarnessError(f"필수 JSONL을 찾을 수 없습니다: {path}") from exc
    return values

def _safe_path(workspace_root: Path, path: Path) -> Path:
    root = workspace_root.resolve()
    resolved = path.resolve()
    if not resolved.is_relative_to(root):
        raise HarnessError(f"workspace 밖의 경로는 사용할 수 없습니다: {path}")
    return resolved

def _relative(workspace_root: Path, path: Path) -> str:
    return _safe_path(workspace_root, path).relative_to(workspace_root.resolve()).as_posix()

def _declared_output(manifest: Mapping[str, Any], filename: str) -> Mapping[str, Any]:
    outputs = manifest.get("outputs")
    if not isinstance(outputs, list):
        raise HarnessError("bundle manifest outputs 형식이 잘못되었습니다.")
    matches = [
        value
        for value in outputs
        if isinstance(value, dict) and value.get("file") == filename
    ]
    if len(matches) != 1:
        raise HarnessError(f"manifest에서 {filename} 선언을 정확히 하나 찾아야 합니다.")
    return matches[0]

def _load_verified_bundle(
    bundle_dir: Path, filename: str
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    manifest = _load_json(bundle_dir / "manifest.json")
    if not isinstance(manifest, dict):
        raise HarnessError("bundle manifest 최상위 값은 object여야 합니다.")
    declaration = _declared_output(manifest, filename)
    path = bundle_dir / filename
    try:
        size = path.stat().st_size
    except FileNotFoundError as exc:
        raise HarnessError(f"bundle 출력 파일이 없습니다: {path}") from exc
    if size != declaration.get("bytes"):
        raise HarnessError(f"{filename} 크기가 manifest와 다릅니다.")
    if _sha256_file(path) != declaration.get("sha256"):
        raise HarnessError(f"{filename} SHA-256이 manifest와 다릅니다.")
    rows = _load_jsonl(path)
    if declaration.get("record_count") != len(rows):
        raise HarnessError(f"{filename} 레코드 수가 manifest와 다릅니다.")
    return manifest, rows

def _output_declaration(filename: str, content: bytes, count: int) -> dict[str, Any]:
    return {
        "file": filename,
        "bytes": len(content),
        "sha256": hashlib.sha256(content).hexdigest(),
        "record_count": count,
    }

def _write_atomic_bundle(
    output: Path,
    files: Mapping[str, bytes],
) -> Path:
    if output.exists():
        raise HarnessError(f"출력 경로가 이미 존재합니다: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}-", dir=output.parent))
    try:
        for filename, content in files.items():
            (temporary / filename).write_bytes(content)
        os.replace(temporary, output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return output
