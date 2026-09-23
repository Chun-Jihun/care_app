"""Run shared mobile prompts on the exported CPU GGUF; no private app data."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def grade(text, expected):
    try:
        value = json.loads(text)
        ids = value['evidence_ids']
        valid = (isinstance(value, dict) and set(value) == {'evidence_ids'}
                 and isinstance(ids, list) and all(isinstance(i, str) for i in ids)
                 and len(ids) == len(set(ids)))
        return dict(json_contract=valid, exact_ids=valid and set(ids) == set(expected))
    except (ValueError, TypeError, KeyError):
        return dict(json_contract=False, exact_ids=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    output = args.directory / 'selector.json'
    if output.exists():
        raise ValueError('Use a new evaluation directory')
    executable = ROOT / 'data/mobile-ai/sources/llama-windows-b10903/llama-completion.exe'
    model = ROOT / 'data/mobile-ai/exports/chat/chat-q4km-text.gguf'
    report = dict(evaluation_eligible=False, medical_release_gate_result=False,
                  runtime='llama.cpp b10903 Windows CPU; not phone latency', threads=2,
                  model_sha256=digest(model), executable_sha256=digest(executable),
                  prompt_source_sha256=digest(ROOT / 'mobile/lib/domain/evidence_selection_prompt.dart'), cases=[])
    for case in json.loads((args.directory / 'selector-cases.json').read_text(encoding='utf-8')):
        start = time.monotonic()
        try:
            result = subprocess.run([str(executable), '-m', str(model), '-f', str(args.directory / case['prompt_file']),
                '-c', '4096', '-b', '256', '-ub', '64', '-t', '2', '-tb', '2', '-ngl', '0',
                '-n', '160', '--temp', '0', '--repeat-penalty', '1', '--no-conversation',
                '--no-display-prompt', '--no-warmup', '--no-escape', '--simple-io'],
                capture_output=True, encoding='utf-8', errors='strict', timeout=240, check=True)
            text = result.stdout.strip()
            # completion emits its terminator on stdout; it is runtime framing, not model JSON.
            if text.endswith('[end of text]'):
                text = text[:-len('[end of text]')].rstrip()
            row = dict(id=case['id'], output=text, expected=case['expected'], **grade(text, case['expected']))
        except (subprocess.SubprocessError, UnicodeError) as error:
            row = dict(id=case['id'], error_type=type(error).__name__, json_contract=False, exact_ids=False)
        row['seconds'] = round(time.monotonic() - start, 2)
        row['prompt_sha256'] = digest(args.directory / case['prompt_file'])
        report['cases'].append(row)
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(case['id'], row['exact_ids'], row['seconds'], flush=True)
    report['passed'] = sum(r['exact_ids'] for r in report['cases'])
    report['total'] = len(report['cases'])
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
