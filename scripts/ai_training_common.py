"""Artifact boundaries for local development training (never an app data reader)."""
from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil

from scripts.ai_baseline_common import (ROOT, inventory, read_json, read_jsonl,
    sha256, verify_files, write_json, write_jsonl, offline)

DATA = ROOT / 'data/ai-training-v1'
EXPERIMENT = ROOT / 'experiments/ai_training_v1'


def stamp():
    return datetime.now(timezone.utc).isoformat()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), sort_keys=True)


def dataset(task):
    directory = DATA / 'inputs' / task
    manifest = read_json(directory / 'manifest.json')
    verify_files(directory, manifest['files'], allow_extra=('manifest.json',))
    if manifest.get('evaluation_eligible') is not False:
        raise ValueError('only development data permitted')
    return directory, manifest


def model_asset(name):
    if name == 'qwen35_4b':
        lock = read_json(ROOT / 'experiments/agent_eval/manifests/model_comparison_v1/models.lock.json')
        entry = next(row for row in lock['models'] if row['id'] == 'M1')
    else:
        lock = read_json(ROOT / 'experiments/ai_baseline_v1/assets.lock.json')
        entry = lock['models'][name]
    directory = ROOT / entry['local_path']
    verify_files(directory, entry['files'])
    return directory, entry


def new_run(run_id, args):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,99}', run_id):
        raise ValueError('invalid run id')
    directory = DATA / 'runs' / run_id
    directory.mkdir(parents=True, exist_ok=False)
    source = directory / 'source'
    source.mkdir()
    for path in sorted((ROOT / 'scripts').glob('*.py')):
        if path.name.startswith(('ai_training_', 'prepare_ai_training', 'run_ai_training', 'queue_ai_training',
                                 'ai_baseline_', 'report_ai_training')):
            shutil.copyfile(path, source / path.name)
    from importlib.metadata import distributions,version
    summary = {'run_id': run_id, 'status': 'running', 'started_at': stamp(),
        'process_id': os.getpid(),
        'config': args, 'evaluation_eligible': False, 'medical_release_gate_result': False,
        'source_files': inventory(source),
        # .pth-based isolated environments can contain two distributions of one package.
        # Resolve by active sys.path order; do not let the last distribution win.
        'packages': {name:version(name) for name in sorted(
            {d.metadata['Name'] for d in distributions() if d.metadata['Name']})}}
    import platform
    summary.update(python=platform.python_version(),platform=platform.platform())
    write_json(directory / 'summary.json', summary)
    return directory, summary


def seal_inputs(directory, metadata):
    metadata.update(evaluation_eligible=False, medical_release_gate_result=False,
                    prepared_at=stamp(), files=inventory(directory))
    write_json(directory / 'manifest.json', metadata)


def check_splits(splits, *, text_key='question'):
    """Reject duplicate questions/groups across synthetic splits before training."""
    seen_ids, seen_groups, seen_questions = {}, {}, {}
    for split, rows in splits.items():
        local_ids = set()
        for row in rows:
            if row['id'] in local_ids:
                raise ValueError('duplicate row id')
            local_ids.add(row['id'])
            if row['split'] != split:
                raise ValueError('incorrect split label')
            for value, seen in [(row['id'],seen_ids), (row['group_id'],seen_groups),
                                (row[text_key],seen_questions)]:
                if value in seen and seen[value] != split:
                    raise ValueError('cross-split contamination')
                seen[value] = split


def completion_tokens(prompt_ids, answer_ids, eos, max_length):
    if not prompt_ids or not answer_ids or type(eos) is not int:
        raise ValueError('empty prompt/target or ambiguous EOS')
    ids = list(prompt_ids) + list(answer_ids) + [eos]
    if len(ids) > max_length:
        raise ValueError('sequence exceeds profile; never truncate a training target')
    labels = [-100] * len(prompt_ids) + list(answer_ids) + [eos]
    return ids, labels
