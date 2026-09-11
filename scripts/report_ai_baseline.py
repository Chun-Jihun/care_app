"""Publish only verified, complete run summaries; preserve failed attempts separately."""
from __future__ import annotations

import argparse
from collections import Counter
from pathlib import Path
import re
import json

from scripts.ai_baseline_common import (ROOT, DATA, EXPERIMENT, SCOPE, inside, read_json,
    read_jsonl, sha256, write_json)
from scripts.run_ai_baseline import aggregate
from scripts.ai_baseline_metrics import chat_score, transcript_score, strict_critical_tokens
from scripts.ai_baseline_rendering import render_record_facts
from scripts.ai_baseline_filtering import resolve_filter_with_boundary_trim


def verified_run(directory: Path) -> dict:
    manifest = read_json(directory/'manifest.json')
    if manifest.get('evaluation_eligible') is not False or manifest.get('medical_release_gate_result') is not False:
        raise ValueError('invalid evaluation scope')
    if manifest['status'] not in {'completed','completed_with_errors','failed'}:
        raise ValueError('run has not finished')
    if manifest.get('source_snapshot'):
        snapshot = manifest['source_snapshot']
        if snapshot['sha256_by_file'] != {Path(path).name:digest for path,digest in manifest['code'].items()}:
            raise ValueError('source snapshot does not match recorded code')
        for name,digest in snapshot['sha256_by_file'].items():
            if sha256(inside(directory,snapshot['path']+'/'+name)) != digest:
                raise ValueError('source snapshot changed')
    summary = read_json(directory/'summary.json')
    if sha256(directory/'summary.json') != manifest['summary_sha256']:
        raise ValueError('summary changed after run')
    rows = []
    if manifest.get('predictions_sha256'):
        if sha256(directory/'predictions.jsonl') != manifest['predictions_sha256']:
            raise ValueError('predictions changed after run')
        rows = read_jsonl(directory/'predictions.jsonl')
    ids = [r['id'] for r in rows]
    selected = manifest.get('selected_ids',[])
    if len(set(ids)) != len(ids) or ids != selected[:len(ids)]:
        raise ValueError('duplicate, reordered, or foreign prediction IDs')
    if manifest['status'].startswith('completed') and ids != selected:
        raise ValueError('completed run has missing predictions')
    if manifest['status'] == 'completed' and (not rows or any(r['error'] for r in rows)):
        raise ValueError('completed run contains execution failures or no cases')
    if summary['overall'] != aggregate(rows,manifest['task']) or summary['status'] != manifest['status']:
        raise ValueError('summary does not match predictions')
    diagnostics = {'hit_token_cap_count':sum(bool(r.get('output',{}).get('hit_token_cap')) for r in rows if r['error'] is None)}
    if rows and manifest['task'] == 'chat':
        source = DATA/'inputs/synthetic'
        if sha256(source/'manifest.json') != manifest['input_manifest_sha256']:
            raise ValueError('input manifest changed')
        input_manifest = read_json(source/'manifest.json')
        declared = next(r for r in input_manifest['files'] if r['path']=='chat-development.jsonl')
        if sha256(source/'chat-development.jsonl') != declared['sha256']:
            raise ValueError('development labels changed')
        cases = {r['id']:r for r in read_jsonl(source/'chat-development.jsonl')}
        if ids[:40] == list(cases)[:40]:
            shared = rows[:40]
            diagnostics['common_screen40'] = {'overall':aggregate(shared,'chat'),
                'by_language':{lang:aggregate([r for r in shared if r['language']==lang],'chat')
                               for lang in sorted({r['language'] for r in shared})}}
        adapted = []
        rendered = []
        changed = 0
        for row in rows:
            if row['error']:
                adapted.append(row)
                rendered.append(row)
                continue
            raw = row['output']['text']
            match = re.fullmatch(r'\s*```(?:json)?\s*\n([\s\S]*?)\n```\s*',raw)
            text = match[1] if match else raw
            changed += bool(match)
            case = cases[row['id']]
            adapted.append(dict(row,score=chat_score(text,case['expected'],{r['id'] for r in case['input']['records']})))
            rendered_text = render_record_facts(text,case['input']['records'])
            rendered.append(dict(row,score=chat_score(rendered_text,case['expected'],{r['id'] for r in case['input']['records']})))
        diagnostics['fence_only_adapter'] = {'post_hoc':True,'changed_outputs':changed,
            'note':'Removes only one entire JSON code fence; does not change contents or the primary score.',
            'overall':aggregate(adapted,'chat')}
        diagnostics['fence_adapter_and_host_fact_rendering'] = {'post_hoc':True,
            'note':'Copy values for the model-selected IDs from supplied records; never uses gold or changes IDs/status. '
                   'Does not validate the selected date/item and cannot independently establish safety.',
            'overall':aggregate(rendered,'chat')}
        if manifest['mode'] == 'filter':
            trimmed = []
            for row in rows:
                if row['error']:
                    trimmed.append(row)
                    continue
                case = cases[row['id']]
                try:
                    resolved = resolve_filter_with_boundary_trim(row['output']['raw_filter_output'],
                        case['input']['question'],case['input']['records'])
                    text = json.dumps(resolved,ensure_ascii=False)
                except (TypeError,ValueError):
                    text = ''
                trimmed.append(dict(row,score=chat_score(text,case['expected'],{r['id'] for r in case['input']['records']})))
            diagnostics['filter_boundary_trim'] = {'post_hoc':True,
                'note':'Trims only extracted day/time/item boundaries. No new model run; original latency is retained, '
                       'not a measurement of the modified pipeline. Source values and internal whitespace are preserved.',
                'overall':aggregate(trimmed,'chat')}
    if rows and manifest['task'] == 'asr':
        source = DATA/'inputs/asr'
        if sha256(source/'manifest.json') != manifest['input_manifest_sha256']:
            raise ValueError('input manifest changed')
        declared = next(r for r in read_json(source/'manifest.json')['files'] if r['path']=='asr-public_validation.jsonl')
        if sha256(source/declared['path']) != declared['sha256']:
            raise ValueError('ASR input metadata changed')
        cases = {r['id']:r for r in read_jsonl(source/declared['path'])}
        diagnostics['rtf_by_language'] = {}
        for lang in sorted({r['language'] for r in rows}):
            matching = [r for r in rows if r['language']==lang and r['split']!='control' and r['error'] is None]
            duration = sum(cases[r['id']]['duration_seconds'] for r in matching)
            diagnostics['rtf_by_language'][lang] = sum(r['seconds'] for r in matching)/duration if duration else None
        import importlib.metadata
        from opencc import OpenCC
        converter = OpenCC('t2s')
        chinese = [r for r in rows if r['language']=='zh-Hans' and r['error'] is None]
        canonical = [dict(r,score=transcript_score(cases[r['id']]['reference'],converter.convert(r['output']['text'])))
                     for r in chinese]
        stats = aggregate(canonical,'asr')
        diagnostics['chinese_script_conversion'] = {'post_hoc':True,
            'engine':'OpenCC','version':importlib.metadata.version('opencc'),'config':'t2s',
            'n':stats['n'],'cer':stats['cer'],
            'note':'Prediction converted to Simplified for display comparison only; original prediction and primary score preserved. '
                   'Not a new model run, translation, or proof of correct medical terminology.'}
    if rows and manifest['task'] in {'ocr','asr'}:
        source = DATA/'inputs'/('asr' if manifest['task']=='asr' else 'synthetic')
        filename = 'asr-public_validation.jsonl' if manifest['task']=='asr' else 'ocr-development.jsonl'
        if sha256(source/'manifest.json') != manifest['input_manifest_sha256']:
            raise ValueError('input manifest changed')
        declaration = next(r for r in read_json(source/'manifest.json')['files'] if r['path']==filename)
        if sha256(source/filename) != declaration['sha256']:
            raise ValueError('transcription labels changed')
        cases = {r['id']:r for r in read_jsonl(source/filename)}
        relevant = [r for r in rows if r['error'] is None and strict_critical_tokens(cases[r['id']]['reference'])]
        diagnostics['critical_tokens_case_sensitive'] = {'post_hoc':True,'n':len(relevant),
            'exact_count':sum(strict_critical_tokens(cases[r['id']]['reference']) == strict_critical_tokens(r['output']['text']) for r in relevant),
            'note':'Numeric/Latin-unit multiset with original case; does not validate field association or all medical units.'}
        if manifest['task']=='ocr':
            diagnostics['colon_width_normalization'] = {'post_hoc':True,'mapping':{'U+FF1A':'U+003A'},'by_language':{}}
            for lang in sorted({r['language'] for r in rows}):
                subset = [r for r in rows if r['language']==lang]
                adjusted = [dict(r,score=transcript_score(cases[r['id']]['reference'].replace('\uff1a',':'),
                            r['output']['text'].replace('\uff1a',':'))) if r['error'] is None else r for r in subset]
                stats = aggregate(adjusted,'ocr')
                diagnostics['colon_width_normalization']['by_language'][lang] = {'n':stats['n'],'cer':stats['cer']}
    return {'run_id':directory.name,'path':directory.relative_to(ROOT).as_posix(),
            'manifest_sha256':sha256(directory/'manifest.json'),
            'task':manifest['task'],'model':manifest['model'],'mode':manifest['mode'],
            'result_role':'diagnostic' if manifest.get('diagnostic_case_ids') else 'main',
            'ocr_mkldnn':manifest.get('ocr_mkldnn',False),
            'load_seconds':manifest.get('load_seconds'),
            'peak_gpu_allocated_gib':manifest.get('peak_gpu_allocated_gib'),
            'peak_gpu_reserved_gib':manifest.get('peak_gpu_reserved_gib'),
            'peak_working_set_gib':manifest.get('process_peak_working_set_gib'),
            'python_network_attempts':manifest.get('python_network_attempts'),
            'source_snapshot_available':bool(manifest.get('source_snapshot')),
            'input_manifest_sha256':manifest.get('input_manifest_sha256'),
            'error':manifest.get('error'),'diagnostics':diagnostics,**summary}


def previous_failures() -> list[dict]:
    from scripts.report_model_comparison import _verify_outputs
    base = ROOT/'data/agent-eval/model-comparison-v1/screening'
    rows = []
    for name in ['m1-qwen35-t1-development-8','m2-qwen3-t1-development-8','m5-exaone-t1-development-8']:
        directory = base/name
        manifest = read_json(directory/'manifest.json')
        _verify_outputs(directory,manifest)
        cases = read_jsonl(directory/'trace_summaries.jsonl')
        calls = read_jsonl(directory/'model_calls.jsonl')
        failed = [r for r in cases if not r['all_expected_checks_passed']]
        rows.append({'run_id':name,'manifest_sha256':sha256(directory/'manifest.json'),
            'n':len(cases),'passed':len(cases)-len(failed),
            'failed_ids':[r['item_id'] for r in failed],
            'failed_check_counts':dict(Counter(k for r in failed for k,v in r['expected_checks'].items() if not v)),
            'schema_error_calls':sum(r['status'] in {'schema_error','parse_error'} for r in calls),
            'validation_errors':dict(Counter(e for r in calls for e in r.get('validation_errors',[]))),
            'safe_abstention_in_passing_cases':sum('EVIDENCE_NOT_FOUND' in r['failure_codes'] for r in cases if r['all_expected_checks_passed'])})
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--run-ids',nargs='+',required=True)
    parser.add_argument('--report-id',required=True)
    parser.add_argument('--history-run-ids',nargs='*',default=[])
    args = parser.parse_args()
    if len(set(args.run_ids)) != len(args.run_ids) or not set(args.history_run_ids).issubset(args.run_ids):
        raise ValueError('duplicate run or unknown history run')
    destination = inside(EXPERIMENT/'results',args.report_id)
    if destination.exists():
        raise ValueError('report already exists')
    runs = [verified_run(inside(DATA/'runs',name)) for name in args.run_ids]
    for run in runs:
        if run['run_id'] in args.history_run_ids:
            run['result_role'] = 'history_excluded_from_comparison'
    result = {'scope':SCOPE,'evaluation_eligible':False,'medical_release_gate_result':False,
              'reporter_code':{p.relative_to(ROOT).as_posix():sha256(p) for p in sorted((ROOT/'scripts').glob('*ai_baseline*.py'))},
              'runs':runs,'previous_failures':previous_failures()}
    write_json(destination/'results.json',result)
    lines = ['# AI baseline V1 — 자동 개발 진단','',
             '의료 정확도 또는 모바일 성능 검증이 아니다. 실행 오류와 모델의 오답을 분리한다.', '',
             '| Run | 상태 | N | 과업 정확/문자 오류율 | 평균 초 | GPU peak GiB |',
             '|---|---|---:|---:|---:|---:|']
    for run in runs:
        stats = run['overall']
        value = (f"{stats.get('task_exact_count',0)}/{stats['n']}" if run['task']=='chat'
                 else f"CER {stats['cer']:.4f}" if stats.get('cer') is not None else '미측정')
        if run['status'] != 'completed':
            value = '미완료 — 성능 비교 제외'
        elif run['result_role'] != 'main':
            value += ' (진단/이력 — 채택 비교 제외)'
        latency = f"{stats['mean_seconds']:.3f}" if 'mean_seconds' in stats else '—'
        memory = f"{run['peak_gpu_allocated_gib']:.3f}" if run['peak_gpu_allocated_gib'] else '—'
        lines.append(f"| {run['run_id']} | {run['status']} | {stats['n']} | {value} | {latency} | {memory} |")
    lines += ['', 'CER은 NFC·소문자·공백만 정규화하며 문장부호/소수점은 보존한다. '
              '공백 단위 WER은 CJK 언어 간 순위에 사용하지 않는다. 무음의 삽입 문자는 CER 분모에 섞지 않고 별도 집계한다.',
              '', '언어별 결과·실행 설정·입력/모델/코드 해시는 results.json과 해당 실행 manifest.json을 참조한다.']
    (destination/'results.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    print(destination.relative_to(ROOT).as_posix())


if __name__ == '__main__':
    main()
