"""Frozen-weight follow-up diagnostics, isolated from all training artifacts."""
from collections import defaultdict
from contextlib import contextmanager
import os
from pathlib import Path
import re
import shutil
import traceback

from scripts.ai_training_common import (ROOT, inventory, offline, read_json, read_jsonl,
    sha256, stamp, verify_files, write_json, write_jsonl, seal_inputs)
from scripts.ai_baseline_metrics import transcript_score, strict_critical_tokens

DATA = ROOT / 'data/ai-validation-v1'
EXPERIMENT = ROOT / 'experiments/ai_validation_v1'


def inputs(task):
    directory = DATA / 'inputs' / task
    manifest = read_json(directory / 'manifest.json')
    verify_files(directory, manifest['files'], allow_extra=('manifest.json',))
    if manifest['evaluation_eligible'] is not False:
        raise ValueError('development inputs required')
    return directory, read_jsonl(directory / 'test.jsonl'), manifest


@contextmanager
def run(run_id, config):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,99}', run_id):
        raise ValueError('invalid run id')
    directory = DATA / 'runs' / run_id
    directory.mkdir(parents=True, exist_ok=False)
    source = directory / 'source'; source.mkdir()
    for path in (ROOT / 'scripts').glob('*.py'):
        if any(s in path.name for s in ('ai_validation', 'ai_training', 'ai_baseline')):
            shutil.copyfile(path, source / path.name)
    shutil.copyfile(EXPERIMENT / 'README.md', source / 'protocol.md')
    from importlib.metadata import version
    summary = dict(run_id=run_id, status='running', config=config, started_at=stamp(),
        process_id=os.getpid(), evaluation_eligible=False, medical_release_gate_result=False,
        source_files=inventory(source), protocol_sha256=sha256(EXPERIMENT / 'README.md'),
        packages={p: version(p) for p in ('torch','transformers','peft','numpy','paddlepaddle')})
    write_json(directory / 'summary.json', summary)
    attempts = offline()
    try:
        yield directory, summary
        summary['status'] = 'completed'
    except BaseException as exc:
        summary.update(status='failed', error_type=type(exc).__name__, error=str(exc))
        (directory / 'failure.txt').write_text(traceback.format_exc(), encoding='utf-8')
        raise
    finally:
        summary.update(finished_at=stamp(), python_network_attempts=attempts,
            artifacts=[dict(path=p.name, bytes=p.stat().st_size, sha256=sha256(p))
                       for p in sorted(directory.glob('*.jsonl'))])
        write_json(directory / 'summary.json', summary)


def media_score(reference, text):
    return dict(score=transcript_score(reference=reference, prediction=text),
        strict_numeric_unit_match=strict_critical_tokens(reference)==strict_critical_tokens(text),
        reference_has_critical=bool(strict_critical_tokens(reference)))


def aggregate_media(rows, group_keys=('language','variant')):
    groups = defaultdict(list)
    for row in rows:
        groups['all'].append(row)
        for key in group_keys:
            if key in row: groups[f'{key}:{row[key]}'].append(row)
    output = {}
    for key, items in groups.items():
        speech = [r for r in items if r['reference']]
        controls = [r for r in items if not r['reference']]
        critical = [r for r in speech if r['reference_has_critical']]
        n = sum(r['score']['reference_characters'] for r in speech)
        output[key] = dict(count=len(items), reference_nonempty=len(speech),
            cer=sum(r['score']['character_edits'] for r in speech)/n if n else None,
            exact=sum(r['reference']==r['text'] for r in speech),
            critical_count=len(critical), critical_match=sum(r['strict_numeric_unit_match'] for r in critical),
            spurious_critical=sum(not r['strict_numeric_unit_match'] for r in speech if not r['reference_has_critical']),
            nonempty_reference_empty_output=sum(not r['text'].strip() for r in speech),
            controls=len(controls), control_nonempty=sum(bool(r['text'].strip()) for r in controls))
    return output


def speech_intervals(probabilities, *, window=512, sample_rate=16000,
                     threshold=0.5, min_speech_ms=250):
    """Conservative whole-clip gate; contiguous above-threshold windows, no trimming."""
    import math
    minimum = math.ceil(min_speech_ms*sample_rate/1000/window)
    spans=[]; start=None
    for index, probability in enumerate([*probabilities, 0.0]):
        if not math.isfinite(probability) or not 0 <= probability <= 1:
            raise ValueError('invalid VAD probability')
        if probability >= threshold and start is None: start=index
        elif probability < threshold and start is not None:
            if index-start >= minimum: spans.append([start*window, index*window])
            start=None
    return spans
