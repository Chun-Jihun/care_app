"""CPU recognizer diagnostics on sealed synthetic line images, not camera accuracy."""
import argparse
import json
import math
from pathlib import Path
import time

from scripts.ai_training_common import verify_files
from scripts.ai_baseline_metrics import strict_critical_tokens
from scripts.summarize_mobile_ai_validation import normalized, distance
from scripts.audit_mobile_release import sha, ROOT


def main():
    import numpy as np
    import onnxruntime as ort
    from PIL import Image
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError('Choose a new output')
    inputs = ROOT / 'data/ai-validation-v1/inputs/ocr'
    manifest = json.loads((inputs / 'manifest.json').read_text(encoding='utf-8'))
    verify_files(inputs, manifest['files'], allow_extra=('manifest.json',))
    model = ROOT / 'data/mobile-ai/exports/ocr-ko-v9/recognizer.onnx'
    chars_path = model.with_name('characters.json')
    chars = json.loads(chars_path.read_text(encoding='utf-8'))
    options = ort.SessionOptions()
    options.log_severity_level = 3
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    session = ort.InferenceSession(str(model), sess_options=options, providers=['CPUExecutionProvider'])
    cases = [json.loads(line) for line in (inputs / 'test.jsonl').read_text(encoding='utf-8').splitlines()]
    rows = []
    for case in cases:
        if case['language'] != 'ko':
            continue
        start = time.monotonic()
        with Image.open(inputs / case['path']) as image:
            image = image.convert('RGB')
            width = min(320, max(1, math.ceil(48 * image.width / image.height)))
            pixels = np.asarray(image.resize((width, 48), Image.Resampling.BILINEAR), dtype=np.float32)
        tensor = np.zeros((1, 3, 48, 320), dtype=np.float32)
        tensor[0, :, :, :width] = ((pixels[:, :, ::-1] / 127.5) - 1).transpose(2, 0, 1)
        values = session.run(None, {session.get_inputs()[0].name: tensor})[0]
        if values.shape[0] != 1 or values.shape[2] != len(chars):
            raise ValueError('Unexpected CTC shape')
        output = []
        previous = -1
        for index in np.argmax(values[0], axis=1):
            if index and index != previous:
                output.append(chars[int(index)])
            previous = index
        text = ''.join(output)
        left, right = normalized(case['reference']), normalized(text)
        marker = case.get('negation_marker')
        rows.append(dict(id=case['id'], variant=case['variant'], reference=case['reference'], prediction=text,
            characters=len(left), edits=distance(left, right), exact=left == right,
            numeric_unit_match=strict_critical_tokens(case['reference']) == strict_critical_tokens(text),
            negation_preserved=normalized(marker) in right if marker else None,
            milliseconds=round(1000 * (time.monotonic() - start))))
    groups = {}
    for variant in sorted({r['variant'] for r in rows}):
        subset = [r for r in rows if r['variant'] == variant]
        groups[variant] = dict(cases=len(subset), exact=sum(r['exact'] for r in subset),
            cer=sum(r['edits'] for r in subset) / sum(r['characters'] for r in subset),
            numeric_unit_errors=sum(not r['numeric_unit_match'] for r in subset),
            negation_cases=sum(r['negation_preserved'] is not None for r in subset),
            negation_errors=sum(r['negation_preserved'] is False for r in subset))
    result = dict(scope='KO ONNX recognizer-only CPU; whole synthetic line, no detector or camera',
        evaluation_eligible=False, medical_release_gate_result=False, quality_gate_passed=False,
        threads=2, onnxruntime=ort.__version__, model_sha256=sha(model), dictionary_sha256=sha(chars_path),
        input_manifest_sha256=sha(inputs / 'manifest.json'), groups=groups, cases=rows)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(groups, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
