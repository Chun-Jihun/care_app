"""Verify completed run artifacts and summarize before/after without hiding failures."""
import argparse
from collections import Counter
import json
import math

from scripts.ai_training_common import DATA,EXPERIMENT,ROOT,dataset,read_json,read_jsonl,sha256,verify_files,write_json


def verified_transcript_score(*,reference,prediction,recorded,legacy=False):
    from scripts.ai_baseline_metrics import transcript_score
    original=(transcript_score(reference=prediction,prediction=reference) if legacy
        else transcript_score(reference=reference,prediction=prediction))
    if original!=recorded:raise ValueError('media score differs from recorded scoring convention')
    return transcript_score(reference=reference,prediction=prediction)


def verify_chat_predictions(directory,summary):
    from scripts.ai_baseline_filtering import resolve_filter_with_boundary_trim
    inputs,_=dataset('chat')
    if sha256(inputs/'manifest.json')!=summary['input_manifest_sha256']:
        raise ValueError('chat input manifest changed')
    split=summary['config']['split']
    if split=='baseline-heldout':
        old=ROOT/'data/ai-baseline-v1/inputs/synthetic'
        verify_files(old,read_json(old/'manifest.json')['files'],allow_extra=('manifest.json',))
        if sha256(old/'chat-heldout.jsonl')!=summary['regression_source_sha256']:
            raise ValueError('regression input changed')
        cases=[dict(r,question=r['input']['question'],records=r['input']['records']) for r in read_jsonl(old/'chat-heldout.jsonl')]
    else:cases=read_jsonl(inputs/f'{split}.jsonl')
    limit=summary['config'].get('limit',0)
    if limit:cases=cases[:limit]
    predictions=read_jsonl(directory/'predictions.jsonl')
    if [r['id'] for r in predictions]!=summary['selected_ids'] or summary['selected_ids']!=[r['id'] for r in cases]:
        raise ValueError('missing, duplicate or reordered chat predictions')
    counts=Counter();languages={}
    for prediction,row in zip(predictions,cases):
        if prediction['language']!=row['language']:raise ValueError('chat language mismatch')
        text=prediction['prediction']['text']
        try:
            parsed=json.loads(text)
            valid=(isinstance(parsed,dict) and set(parsed)=={'kind','day','time','item'}
                and parsed['kind'] in {'lookup','medical'}
                and all(parsed[k] is None or isinstance(parsed[k],str) for k in ['day','time','item']))
            exact=parsed==row['target'] if 'target' in row else None
            resolved=resolve_filter_with_boundary_trim(text,row['question'],row['records'])
        except (ValueError,TypeError):valid=False;exact=False;resolved=None
        score={'schema_valid':valid,'filter_exact':exact,'host_exact':resolved==row['expected'],
            'unsafe_medical_record_answer':row['expected']['status']=='needs_evidence'
                and resolved is not None and resolved['status']=='record_answer'}
        if prediction['score']!=score or prediction['resolved']!=resolved:
            raise ValueError('chat prediction score differs from recomputation')
        for counter in [counts,languages.setdefault(row['language'],Counter())]:
            counter['count']+=1
            for key,value in score.items():
                if value:counter[key]+=1
    metrics=summary['metrics']
    if dict(counts)!=metrics['overall'] or {k:dict(v) for k,v in languages.items()}!=metrics['per_language']:
        raise ValueError('chat summary differs from predictions')
    return {'count':len(predictions),'scores_recomputed':True}


def verify_media_predictions(directory,summary):
    """Recompute metrics against frozen references, including older OCR output files."""
    from scripts.ai_baseline_metrics import strict_critical_tokens
    is_asr='base_asset' in summary
    task='asr' if is_asr else 'ocr'
    inputs,_=dataset(task)
    if sha256(inputs/'manifest.json')!=summary['input_manifest_sha256']:
        raise ValueError('media input manifest changed')
    if is_asr:
        from scripts.run_ai_training_asr import aggregate
        from opencc import OpenCC
        simplified=OpenCC('t2s')
        allowed=None
    else:
        from scripts.run_ai_training_ocr import scores as aggregate
        allowed={'ko','en'} if summary['config']['model']=='ko' else {'en','ja','zh-Hans','zh-Hant'}
    legacy=summary.get('transcript_metric_version')!='reference-first-v2'
    artifacts=[];corrected_metrics={};diagnostics={}
    for split in ['validation','test']:
        expected=[r for r in read_jsonl(inputs/f'{split}.jsonl') if allowed is None or r['language'] in allowed]
        for phase in ['baseline','trained']:
            path=directory/f'{phase}-{split}.jsonl'
            predictions=read_jsonl(path)
            if [r['id'] for r in predictions]!=[r['id'] for r in expected]:
                raise ValueError('missing, duplicate or reordered media predictions')
            corrected=[]
            for prediction,row in zip(predictions,expected):
                if any(prediction[key]!=row[key] for key in ['language','reference']):
                    raise ValueError('prediction reference differs from frozen input')
                text=prediction['text'];reference=row['reference']
                corrected_row=dict(prediction,score=verified_transcript_score(
                    reference=reference,prediction=text,recorded=prediction['score'],legacy=legacy))
                strict=strict_critical_tokens(text)==strict_critical_tokens(reference)
                if prediction['strict_numeric_unit_match']!=strict:
                    raise ValueError('numeric/unit score differs from recomputation')
                if is_asr:
                    display=simplified.convert(text) if row['language'].startswith('zh') else text
                    if prediction['display_text']!=display:
                        raise ValueError('display normalization score differs from recomputation')
                    corrected_row['display_score']=verified_transcript_score(reference=reference,
                        prediction=display,recorded=prediction['display_score'],legacy=legacy)
                corrected.append(corrected_row)
            if aggregate(predictions)!=summary[f'{phase}_{split}']:
                raise ValueError('media summary differs from predictions')
            artifacts.append({'path':path.name,'sha256':sha256(path),'count':len(predictions)})
            corrected_metrics[f'{phase}_{split}']=aggregate(corrected)
            speech=[r for r in corrected if r['reference']]
            critical=[r for r in speech if strict_critical_tokens(r['reference'])]
            diagnostics[f'{phase}_{split}']={
                'critical_reference_cases':len(critical),
                'critical_exact':sum(r['strict_numeric_unit_match'] for r in critical),
                'spurious_critical_cases':sum(not strict_critical_tokens(r['reference'])
                    and bool(strict_critical_tokens(r['text'])) for r in speech),
                'hit_token_cap_count':sum(r.get('hit_token_cap',False) for r in corrected)}
    return {'artifacts':artifacts,'metrics':corrected_metrics,
        'diagnostics':diagnostics,
        'transcript_metric_version':'reference-first-v2',
        'correction':('Original runner passed transcript_score(prediction, reference), which reversed CER denominators and silence metadata. Original predictions/summary retained; these report metrics recompute with reference first. Training and fixed hyperparameters were unaffected.' if legacy else None)}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--report-id',required=True)
    args=parser.parse_args()
    from scripts.ai_baseline_common import inside
    destination=inside(EXPERIMENT/'results',args.report_id)
    if destination==EXPERIMENT/'results':raise ValueError('report id required')
    destination.mkdir(parents=True,exist_ok=False)
    runs=[]
    for path in sorted((DATA/'runs').glob('*/summary.json')):
        summary=read_json(path);directory=path.parent
        if summary['status']=='running':raise ValueError('cannot finalize a report with active runs')
        verify_files(directory/'source',summary['source_files'])
        verification={}
        if summary['status']=='completed':
            if summary.get('evaluation_eligible') is not False or summary.get('medical_release_gate_result') is not False:
                raise ValueError('invalid development scope')
            if 'adapter_files' in summary:verify_files(directory/'adapter',summary['adapter_files'])
            if 'checkpoint_sha256' in summary and sha256(directory/'ctc-head.pdparams')!=summary['checkpoint_sha256']:
                raise ValueError('OCR checkpoint changed')
            if 'predictions_sha256' in summary and sha256(directory/'predictions.jsonl')!=summary['predictions_sha256']:
                raise ValueError('predictions changed')
            if 'target_sha256' in summary and sha256(directory/'training-targets.jsonl')!=summary['target_sha256']:
                raise ValueError('training target artifact changed')
            for artifact in summary.get('prediction_artifacts',[]):
                if sha256(directory/artifact['path'])!=artifact['sha256']:
                    raise ValueError('before/after prediction artifact changed')
            if 'optimizer_steps' in summary:
                losses=read_jsonl(directory/'loss.jsonl')
                if len(losses)!=summary['optimizer_steps'] or not losses:
                    raise ValueError('incomplete optimization log')
                if [row['step'] for row in losses]!=list(range(1,len(losses)+1)):
                    raise ValueError('optimization steps are not contiguous')
                for row in losses:
                    gradient=row.get('gradient_norm',row.get('gradient_l1'))
                    if not math.isfinite(row['loss']) or gradient is None or not math.isfinite(gradient) or gradient<=0:
                        raise ValueError('invalid loss or gradient log')
                delta=summary.get('adapter_delta_l1',summary.get('head_delta_l1'))
                if delta is None or not math.isfinite(delta) or delta<=0:
                    raise ValueError('missing weight-change evidence')
                summary['loss_first']=losses[0]['loss'];summary['loss_last']=losses[-1]['loss']
            if 'trained_test' in summary:
                verification['recomputed_media_artifacts']=verify_media_predictions(directory,summary)
            if 'metrics' in summary:
                verification['recomputed_chat']=verify_chat_predictions(directory,summary)
            if summary.get('python_network_attempts'):
                raise ValueError('completed run attempted Python networking')
        runs.append({'summary_sha256':sha256(path),'summary':summary,
                     'verification':verification,
                     'path':directory.relative_to(DATA).as_posix()})
    payload={'evaluation_eligible':False,'medical_release_gate_result':False,'runs':runs,
        'effective_runtime':read_json(EXPERIMENT/'training-environment.json'),
        'early_runtime_metadata_note':'early new_run snapshots enumerated all visible distributions, so duplicate numpy metadata could show the shadowed base version. training-environment.json records resolved active versions; no package reinstall occurred between these runs. Later new_run resolves metadata by active sys.path order.',
        'limitations':['synthetic chatbot/OCR; public read speech; no clinical or mobile validation',
                       'single seed and small pilot; no statistical generalization claim',
                       'teacher-filtered corpus differs in size/composition from gold SFT',
                       'wall time under shared PC use is not a mobile speed benchmark']}
    write_json(destination/'results.json',payload)
    lines=['# 추가 학습·증류 개발 실험 결과','',
        '모든 수치는 로컬 개발 실험이다. 실패·중단 실행을 0점 또는 완료로 처리하지 않는다.','',
        'OCR/ASR 점수는 정답을 기준으로 재계산했다. 초기 실행의 전사 평가 함수 인자 순서 오류가 있는 원본 summary는 이력으로 보존하고, 아래 표와 results.json의 verification.recomputed_media_artifacts.metrics에 수정한 값을 기록한다.','',
        '| 실행 | 상태 | 학습/검증 결과 |','|---|---|---|']
    for run in runs:
        s=run['summary'];detail=''
        if s['status']=='completed':
            if 'metrics' in s:
                m=s['metrics']['overall']
                detail=f"조건 일치 {m.get('filter_exact',0)}/{m['count']}; 조회 일치 {m.get('host_exact',0)}/{m['count']}"
                if s['config'].get('split')=='baseline-heldout':
                    detail=f"조회 일치 {m.get('host_exact',0)}/{m['count']}; 별도 조건 추출 정답 없음"
            elif 'trained_test' in s:
                metrics=run['verification']['recomputed_media_artifacts']['metrics']
                key='all';before=metrics['baseline_test'][key];after=metrics['trained_test'][key]
                detail=f"시험 CER {before['cer']:.6f} → {after['cer']:.6f}; 원문 일치 {before['exact']} → {after['exact']}"
            elif 'optimizer_steps' in s:
                detail=f"{s['train_examples']}건, {s['optimizer_steps']} update; loss {s['loss_first']:.4f} → {s['loss_last']:.4f}"
        else:detail=s.get('error_type',s.get('interruption','unfinished'))
        lines.append(f"| {s['run_id']} | {s['status']} | {detail} |")
    lines.extend(['','원본·adapter/체크포인트 해시, 언어별 지표, 학습 설정과 실행 환경은 results.json에 보관한다.',''])
    (destination/'results.md').write_text('\n'.join(lines),encoding='utf-8')
    print(destination,flush=True)


if __name__=='__main__':main()
