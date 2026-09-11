"""Download allowlisted PUBLIC assets. No credentials or patient inputs are read."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import fnmatch
from pathlib import Path

from scripts.ai_baseline_common import (ROOT, EXPERIMENT, DATA, SCOPE, configure_cache,
                                       inventory, read_json, verify_files, write_json)

MODELS = {
    'qwen35_2b': ('Qwen/Qwen3.5-2B', '15852e8c16360a2fea060d615a32b45270f8a8fc'),
    'gemma4_e2b': ('google/gemma-4-E2B-it', '3e22461f65e89153144f8adb70e3b8c2cc9845a7'),
    'qwen3_asr_06b': ('Qwen/Qwen3-ASR-0.6B-hf', '7f1569a48a89f3e3f4dc3a5c9d28bddd903bc76c'),
    'whisper_base': ('openai/whisper-base', 'e37978b90ca9030d5170a5c07aadb050351a65bb'),
    'whisper_small': ('openai/whisper-small', '973afd24965f72e36ca33b3055d56a652f456b4d'),
    'ppocr5_det': ('PaddlePaddle/PP-OCRv5_mobile_det', '0d63e78e2b680928f6b1747d76a08db6e645efb7'),
    'ppocr5_ko': ('PaddlePaddle/korean_PP-OCRv5_mobile_rec', 'c02ecaf1f22bfd1c618cce154fd19185b47e663a'),
    'ppocr5_multi': ('PaddlePaddle/PP-OCRv5_mobile_rec', '682f20538d8c086cb2128e5cfac775e6c4904e85'),
}
PATTERNS = ['*.json', '*.safetensors', '*.jinja', '*.txt', '*.yml', '*.yaml',
            '*.pdiparams', '*.model', 'README.md', 'LICENSE*', 'NOTICE*', 'merges.txt', 'vocab.json']


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--models', nargs='*', choices=list(MODELS), default=list(MODELS))
    parser.add_argument('--fleurs', action='store_true')
    args = parser.parse_args()
    configure_cache()
    from huggingface_hub import HfApi, hf_hub_download
    api = HfApi(token=False)
    lock_path = EXPERIMENT / 'assets.lock.json'
    lock = read_json(lock_path) if lock_path.exists() else {
        'schema_version': 1, 'result_scope': SCOPE, 'evaluation_eligible': False,
        'medical_release_gate_result': False, 'models': {}, 'datasets': {}}
    for name in args.models:
        repo, revision = MODELS[name]
        directory = ROOT / 'models/ai-baseline-v1' / name
        previous = lock['models'].get(name, {})
        if previous.get('status') == 'downloaded':
            verify_files(directory, previous['files'])
            print(f'{name}: verified existing files', flush=True)
            continue
        try:
            info = api.model_info(repo, revision=revision, files_metadata=True)
            if info.gated:
                raise ValueError('gated asset requires a separate access decision')
            selected = [x for x in info.siblings if any(fnmatch.fnmatch(x.rfilename, p) for p in PATTERNS)]
            size = sum(x.size or 0 for x in selected)
            if size > 16 * 1024**3:
                raise ValueError('asset exceeds per-model download limit')
            print(f'{name}: public revision {info.sha}, {size} bytes', flush=True)
            for entry in selected:
                hf_hub_download(repo, entry.rfilename, revision=info.sha,
                                local_dir=directory, token=False)
            lock['models'][name] = {'status': 'downloaded', 'repository_id': repo,
                'revision': info.sha, 'license_metadata': info.card_data.to_dict().get('license') if info.card_data else None,
                'local_path': directory.relative_to(ROOT).as_posix(), 'files': inventory(directory)}
        except Exception as exc:
            lock['models'][name] = {'status': 'unavailable', 'repository_id': repo,
                                    'error_type': type(exc).__name__}
            print(f'{name}: unavailable ({type(exc).__name__})', flush=True)
        lock['updated_at'] = datetime.now(timezone.utc).isoformat()
        write_json(lock_path, lock)
    if args.fleurs:
        repo = 'google/fleurs'
        info = api.dataset_info(repo, revision='168de341b3db6859a9bac1c50a2ef5e3b47647e0', files_metadata=True)
        directory = DATA / 'sources/fleurs'
        names = []
        for config in ['ko_kr', 'en_us', 'ja_jp', 'cmn_hans_cn']:
            selected = [x for x in info.siblings if x.rfilename.startswith(config + '/validation/')
                        and x.rfilename.endswith('.parquet')]
            if not selected:
                raise ValueError(f'missing FLEURS validation: {config}')
            if sum(x.size or 0 for x in selected) > 512 * 1024**2:
                raise ValueError('FLEURS download exceeds per-language limit')
            for entry in selected:
                hf_hub_download(repo, entry.rfilename, repo_type='dataset', revision=info.sha,
                                local_dir=directory, token=False)
                names.append(entry.rfilename)
            print(f'fleurs: downloaded {config} validation', flush=True)
        lock['datasets']['fleurs'] = {'repository_id': repo, 'revision': info.sha,
            'source_split': 'validation', 'selection': 'first 50 rows per language',
            'local_path': directory.relative_to(ROOT).as_posix(), 'files': inventory(directory)}
        write_json(lock_path, lock)


if __name__ == '__main__':
    main()
