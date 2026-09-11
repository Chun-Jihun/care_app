"""Small, explicit artifact contracts for development-only AI comparisons."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
EXPERIMENT = ROOT / 'experiments/ai_baseline_v1'
DATA = ROOT / 'data/ai-baseline-v1'
SCOPE = 'automated_development_diagnostic_not_medical_performance'


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def inside(root: Path, relative: str) -> Path:
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError('artifact path escapes its root')
    return path


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding='utf-8'))


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    temporary.replace(path)


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line]


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x', encoding='utf-8', newline='\n') as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + '\n')


def inventory(directory: Path) -> list[dict]:
    return [{'path': p.relative_to(directory).as_posix(), 'bytes': p.stat().st_size,
             'sha256': sha256(p)} for p in sorted(directory.rglob('*'))
            if p.is_file() and '.cache' not in p.relative_to(directory).parts]


def verify_files(directory: Path, files: list[dict], *, allow_extra: tuple[str, ...] = ()) -> None:
    if not files:
        raise ValueError('empty file inventory')
    seen = set()
    for entry in files:
        name = entry['path']
        if name in seen:
            raise ValueError('duplicate inventory path')
        seen.add(name)
        path = inside(directory, name)
        if not path.is_file() or path.stat().st_size != entry['bytes'] or sha256(path) != entry['sha256']:
            raise ValueError(f'artifact integrity check failed: {name}')
    actual = {p.relative_to(directory).as_posix() for p in directory.rglob('*')
              if p.is_file() and '.cache' not in p.relative_to(directory).parts}
    if actual - seen - set(allow_extra):
        raise ValueError('unlisted files in frozen artifact directory')


def configure_cache() -> None:
    cache = ROOT / '.tools/ai-baseline-cache'
    values = {'HF_HOME': cache / 'hf', 'HF_HUB_CACHE': cache / 'hf/hub',
              'XDG_CACHE_HOME': cache, 'PADDLE_HOME': cache / 'paddle',
              'PADDLE_DATA_HOME': cache / 'paddle/dataset',
              'PADDLE_PDX_CACHE_HOME': cache / 'paddlex',
              'NUMBA_CACHE_DIR': cache / 'numba', 'MPLCONFIGDIR': cache / 'matplotlib',
              'TORCH_HOME': cache / 'torch'}
    for name, path in values.items():
        os.environ[name] = str(path)
    os.environ.update(HF_HUB_DISABLE_TELEMETRY='1', HF_HUB_DISABLE_IMPLICIT_TOKEN='1',
                      HF_HUB_DISABLE_PROGRESS_BARS='1', TOKENIZERS_PARALLELISM='false',
                      PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK='True', DO_NOT_TRACK='1')


def offline() -> list[str]:
    """Block Python network calls in addition to the execution sandbox."""
    configure_cache()
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_DATASETS_OFFLINE='1')
    attempts: list[str] = []
    def audit(event: str, args: tuple) -> None:
        if event in {'socket.connect', 'socket.getaddrinfo', 'socket.sendto'}:
            attempts.append(event)
            raise PermissionError('network disabled for offline AI evaluation')
    sys.addaudithook(audit)
    return attempts
