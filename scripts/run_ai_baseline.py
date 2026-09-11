"""Run a fresh, hash-verified development comparison. Never consumes held-out cases."""
from __future__ import annotations

import argparse
from collections import defaultdict
from datetime import datetime, timezone
import importlib.metadata
import json
from pathlib import Path
import platform
import statistics
import time
import traceback

from scripts.ai_baseline_common import (ROOT, DATA, EXPERIMENT, SCOPE, inside, offline,
    read_json, read_jsonl, sha256, verify_files, write_json)
from scripts.ai_baseline_metrics import chat_score, transcript_score


def asset(name: str) -> dict:
    if name == 'qwen35_4b':
        old = read_json(ROOT/'experiments/agent_eval/manifests/model_comparison_v1/models.lock.json')
        entry = next(x for x in old['models'] if x['id'] == 'M1')
    else:
        entry = read_json(EXPERIMENT/'assets.lock.json')['models'][name]
        if entry.get('status') != 'downloaded':
            raise ValueError(f'asset is not ready: {name}')
    verify_files(inside(ROOT, entry['local_path']), entry['files'])
    return entry


def aggregate(rows: list[dict], task: str) -> dict:
    successful = [r for r in rows if r['error'] is None]
    result = {'n':len(rows), 'execution_errors':len(rows)-len(successful)}
    latencies = sorted(r['seconds'] for r in successful)
    if latencies:
        result.update(mean_seconds=statistics.mean(latencies), median_seconds=statistics.median(latencies),
                      p95_seconds=latencies[min(len(latencies)-1, int(len(latencies)*.95))])
    if task == 'chat':
        for key in ['json_valid','schema_valid','task_exact','unauthorized_id','status_exact','ids_exact','facts_exact']:
            result[key+'_count'] = sum(bool(r['score'].get(key)) for r in successful)
    else:
        chars = sum(r['score']['reference_characters'] for r in successful)
        words = sum(r['score']['reference_words'] for r in successful)
        edits = sum(r['score']['character_edits'] for r in successful if r['score']['reference_characters'])
        w_edits = sum(r['score']['word_edits'] for r in successful if r['score']['reference_words'])
        critical = [r for r in successful if r['score']['has_critical_tokens']]
        result.update(cer=edits/chars if chars else None, wer=w_edits/words if words else None,
            exact_count=sum(r['score']['exact'] for r in successful),
            critical_token_cases=len(critical), critical_tokens_exact_count=sum(r['score']['critical_tokens_exact'] for r in critical),
            silence_hallucination_count=sum(r['score']['silence_hallucination'] for r in successful))
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--task', choices=['chat','ocr','asr'], required=True)
    parser.add_argument('--model', choices=['qwen35_2b','qwen35_4b','gemma4_e2b','ppocr5_ko','ppocr5_multi',
                                          'whisper_base','whisper_small','qwen3_asr_06b'], required=True)
    parser.add_argument('--mode', choices=['plain','grammar','filter'], default='plain')
    parser.add_argument('--limit-per-language', type=int, default=0)
    parser.add_argument('--case-ids', nargs='+', help='Explicit development IDs for a separately named diagnostic run')
    parser.add_argument('--ocr-mkldnn', action='store_true', help='Separate OCR CPU kernel optimization condition')
    parser.add_argument('--run-id', required=True)
    args = parser.parse_args()
    expected_task = ('ocr' if args.model.startswith('ppocr') else 'asr'
                     if args.model.startswith('whisper') or 'asr' in args.model else 'chat')
    if args.task != expected_task or args.limit_per_language < 0 or (args.mode != 'plain' and args.task != 'chat'):
        parser.error('incompatible task, mode or sample limit')
    if args.ocr_mkldnn and args.task != 'ocr':
        parser.error('MKLDNN flag is only valid for OCR')
    directory = inside(DATA/'runs',args.run_id)
    if directory == DATA/'runs' or directory.exists():
        raise ValueError('run ID must identify a new directory; results are never overwritten')
    directory.mkdir(parents=True)
    manifest = {'schema_version':1,'scope':SCOPE,'evaluation_eligible':False,'medical_release_gate_result':False,
        'status':'preparing','started_at':datetime.now(timezone.utc).isoformat(),
        'task':args.task,'model':args.model,'mode':args.mode,'limit_per_language':args.limit_per_language,
        'diagnostic_case_ids':args.case_ids,
        'ocr_mkldnn':args.ocr_mkldnn,
        'system':platform.platform(),'python':platform.python_version(),
        'packages':{name:importlib.metadata.version(name) for name in
                    ['torch','transformers','bitsandbytes','numpy','paddleocr','paddlepaddle','lm-format-enforcer']},
        'code':{p.relative_to(ROOT).as_posix():sha256(p) for p in sorted((ROOT/'scripts').glob('*ai_baseline*.py'))},
        'settings':{'batch_size':1,'chat_max_new_tokens':160,'asr_max_new_tokens':256,
                    'chat_quantization':'NF4, BF16 compute, no double quantization; CUDA SDPA',
                    'asr_precision':'FP16 CUDA SDPA','ocr_device':'CPU, 4 threads',
                    'ocr_mkldnn':args.ocr_mkldnn,
                    'decoding':'greedy','warmup_cases':0,'latency_includes_first_inference':True}}
    write_json(directory/'manifest.json',manifest)
    source_directory = directory/'source'
    source_directory.mkdir()
    for relative,digest in manifest['code'].items():
        source = ROOT/relative
        if sha256(source) != digest:
            raise ValueError('source changed while preparing the run')
        (source_directory/source.name).write_bytes(source.read_bytes())
    manifest['source_snapshot'] = {'path':'source','sha256_by_file':
                                  {Path(path).name:digest for path,digest in manifest['code'].items()}}
    patch_path = EXPERIMENT/'runtime-patches.json'
    if patch_path.exists():
        patches = read_json(patch_path)
        for patch in patches['patches']:
            if sha256(inside(ROOT,patch['path'])) != patch['after_sha256']:
                raise ValueError('runtime compatibility patch changed')
        manifest['runtime_compatibility_patches'] = patches
    write_json(directory/'manifest.json',manifest)
    network_attempts = offline()
    results = []
    try:
        entries = {args.model:asset(args.model)}
        if args.task == 'ocr':
            entries['ppocr5_det'] = asset('ppocr5_det')
        manifest['models'] = entries
        inputs_dir = DATA/'inputs'/('asr' if args.task == 'asr' else 'synthetic')
        inputs_manifest = read_json(inputs_dir/'manifest.json')
        verify_files(inputs_dir,inputs_manifest['files'],allow_extra=('manifest.json',))
        manifest['input_manifest_sha256'] = sha256(inputs_dir/'manifest.json')
        cases = read_jsonl(inputs_dir/(f'{args.task}-'+('public_validation' if args.task == 'asr' else 'development')+'.jsonl'))
        if args.case_ids:
            requested = set(args.case_ids)
            if len(requested) != len(args.case_ids) or not requested.issubset({r['id'] for r in cases}):
                raise ValueError('unknown or duplicate diagnostic case IDs')
            cases = [r for r in cases if r['id'] in requested]
        if args.model == 'ppocr5_ko':
            cases = [r for r in cases if r['language'] in {'ko','en'}]
        elif args.model == 'ppocr5_multi':
            cases = [r for r in cases if r['language'] in {'en','ja','zh-Hans','zh-Hant'}]
        selected, counts = [], defaultdict(int)
        for case in cases:
            group = case['language'] if case['split'] != 'control' else 'control'
            if not args.limit_per_language or counts[group] < args.limit_per_language:
                selected.append(case)
                counts[group] += 1
        if not selected:
            raise ValueError('empty selected input set')
        manifest['selected_ids'] = [r['id'] for r in selected]
        from scripts.ai_baseline_backends import ChatBackend, AsrBackend, OcrBackend, CHAT_PROMPT, CHAT_SCHEMA
        manifest['chat_prompt'] = CHAT_PROMPT if args.task == 'chat' else None
        manifest['chat_schema'] = CHAT_SCHEMA if args.task == 'chat' else None
        model_dir = inside(ROOT,entries[args.model]['local_path'])
        started = time.perf_counter()
        if args.mode == 'filter':
            from scripts.ai_baseline_filtering import FilterChatBackend, FILTER_PROMPT
            manifest['chat_prompt'] = FILTER_PROMPT
            manifest['chat_schema'] = 'kind/day/time/item filter contract; host resolves supplied records'
            backend = FilterChatBackend(model_dir)
        elif args.task == 'chat':
            backend = ChatBackend(model_dir,args.mode == 'grammar')
        elif args.task == 'asr':
            backend = AsrBackend(model_dir,args.model == 'qwen3_asr_06b')
        else:
            backend = OcrBackend(inside(ROOT,entries['ppocr5_det']['local_path']),model_dir,
                                 args.model == 'ppocr5_ko',mkldnn=args.ocr_mkldnn)
        manifest['load_seconds'] = time.perf_counter()-started
        manifest['model_eos_token_ids'] = getattr(backend,'stop_token_ids',None)
        if args.task != 'ocr':
            import torch
            torch.cuda.synchronize()
            torch.cuda.reset_peak_memory_stats()
            manifest['gpu'] = torch.cuda.get_device_name()
        manifest['status'] = 'running'
        write_json(directory/'manifest.json',manifest)
        with (directory/'predictions.jsonl').open('x',encoding='utf-8') as handle:
            for index, case in enumerate(selected):
                row = {key:case.get(key) for key in ['id','language','split','family','variant']}
                started = time.perf_counter()
                try:
                    if args.task == 'chat':
                        output = backend.predict(case['input'])
                        score = chat_score(output['text'],case['expected'],{r['id'] for r in case['input']['records']})
                    else:
                        path = inside(inputs_dir,case['path'])
                        output = backend.predict(path,case['language']) if args.task == 'asr' else backend.predict(path)
                        score = transcript_score(case['reference'],output['text'])
                    if args.task != 'ocr':
                        torch.cuda.synchronize()
                    row.update(output=output,score=score,error=None)
                except Exception as exc:
                    row.update(output=None,score=None,error={'type':type(exc).__name__,'message':str(exc)})
                row['seconds'] = time.perf_counter()-started
                results.append(row)
                handle.write(json.dumps(row,ensure_ascii=False,allow_nan=False)+'\n')
                handle.flush()
                if (index+1)%10 == 0 or index+1 == len(selected) or row['error']:
                    print(f'{args.run_id}: {index+1}/{len(selected)} errors={sum(r["error"] is not None for r in results)}',flush=True)
                if len(results) >= 3 and all(r['error'] for r in results[-3:]):
                    raise RuntimeError('three consecutive execution errors; aborting for diagnosis')
        manifest['status'] = 'completed' if not any(r['error'] for r in results) else 'completed_with_errors'
        if args.task != 'ocr':
            manifest['peak_gpu_allocated_gib'] = torch.cuda.max_memory_allocated()/1024**3
            manifest['peak_gpu_reserved_gib'] = torch.cuda.max_memory_reserved()/1024**3
        import psutil
        memory = psutil.Process().memory_info()
        manifest['process_peak_working_set_gib'] = getattr(memory,'peak_wset',memory.rss)/1024**3
    except Exception as exc:
        manifest['status'] = 'failed'
        manifest['error'] = {'type':type(exc).__name__,'message':str(exc)}
        traceback.print_exc()
    finally:
        manifest['finished_at'] = datetime.now(timezone.utc).isoformat()
        manifest['python_network_attempts'] = network_attempts
        if (directory/'predictions.jsonl').exists():
            manifest['predictions_sha256'] = sha256(directory/'predictions.jsonl')
        summary = {'scope':SCOPE,'evaluation_eligible':False,'medical_release_gate_result':False,
            'status':manifest['status'],'overall':aggregate(results,args.task),
            'by_language':{lang:aggregate([r for r in results if r['language']==lang and r['split']!='control'],args.task)
                           for lang in sorted({r['language'] for r in results})}}
        for dimension in ['family','variant','split']:
            summary['by_'+dimension] = {str(value):aggregate([r for r in results if r[dimension]==value],args.task)
                                       for value in sorted({r[dimension] for r in results if r[dimension] is not None},key=str)}
        write_json(directory/'summary.json',summary)
        manifest['summary_sha256'] = sha256(directory/'summary.json')
        write_json(directory/'manifest.json',manifest)
        print(json.dumps({'run_id':args.run_id,**summary['overall'],'status':manifest['status']},ensure_ascii=False),flush=True)
    if manifest['status'] != 'completed':
        raise SystemExit(1)


if __name__ == '__main__':
    main()
