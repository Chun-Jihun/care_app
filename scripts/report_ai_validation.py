"""Recompute new diagnostic results from sealed inputs and raw predictions."""
from collections import defaultdict
import json
import re

from scripts.ai_validation_common import (DATA,EXPERIMENT,ROOT,aggregate_media,inputs,
    inventory,media_score,read_json,read_jsonl,sha256,speech_intervals,stamp,verify_files,write_json)
from scripts.ai_baseline_filtering import resolve_filter_with_boundary_trim
from scripts.ai_baseline_metrics import normalized,strict_critical_tokens

RUN_IDS=['chat-base-v1','chat-sft-v1','chat-distill-v1','ocr-ko-v1','ocr-multi-v1',
         'vad-v1','asr-base-v1','asr-trained-v1','ocr-pages-v2']


def require(condition,message):
    if not condition: raise ValueError(message)


def load_runs():
    result={}
    for name in RUN_IDS:
        directory=DATA/'runs'/name; summary=read_json(directory/'summary.json')
        require(summary['status']=='completed',f'incomplete run: {name}')
        require(not summary['python_network_attempts'],f'network attempt: {name}')
        require(summary['evaluation_eligible'] is False and summary['medical_release_gate_result'] is False,'invalid release flags')
        verify_files(directory/'source',summary['source_files'])
        for artifact in summary['artifacts']:
            path=directory/artifact['path']
            require(path.stat().st_size==artifact['bytes'] and sha256(path)==artifact['sha256'],f'changed artifact: {name}')
        result[name]=summary
    return result


def raw(name,file,expected):
    rows=read_jsonl(DATA/'runs'/name/(file+'.jsonl'))
    require([r['id'] for r in rows]==[r['id'] for r in expected],f'prediction order/coverage: {name}/{file}')
    for row,source in zip(rows,expected):
        require(row['reference']==source['reference'],'reference changed')
        for key,value in media_score(row['reference'],row['text']).items():
            require(row[key]==value,f'metric mismatch: {row["id"]}/{key}')
    return rows


def changes(before,after):
    require([r['id'] for r in before]==[r['id'] for r in after],'unpaired comparison')
    return dict(exact_improved=sum(a['text']!=a['reference'] and b['text']==b['reference'] for a,b in zip(before,after)),
        exact_regressed=sum(a['text']==a['reference'] and b['text']!=b['reference'] for a,b in zip(before,after)),
        critical_improved=sum(not a['strict_numeric_unit_match'] and b['strict_numeric_unit_match'] for a,b in zip(before,after)),
        critical_regressed=sum(a['strict_numeric_unit_match'] and not b['strict_numeric_unit_match'] for a,b in zip(before,after)),
        critical_errors=[dict(id=a['id'],reference=a['reference'],before=a['text'],after=b['text'])
                         for a,b in zip(before,after) if not a['strict_numeric_unit_match'] or not b['strict_numeric_unit_match']])


def main():
    summaries=load_runs()
    datasets={task:inputs(task) for task in ['chat','ocr','asr','ocr-pages']}
    report=dict(scope='frozen_weight_development_diagnostics',created_at=stamp(),evaluation_eligible=False,
        medical_release_gate_result=False,runs=summaries,chat={},ocr={},asr={},pages={},
        inputs={task:dict(manifest_sha256=sha256(folder/'manifest.json'),manifest=manifest)
                for task,(folder,_,manifest) in datasets.items()})
    for name,summary in summaries.items():
        task='ocr-pages' if name.startswith('ocr-pages-') else 'asr' if name.startswith(('asr','vad')) else name.split('-')[0]
        require(summary['input_manifest_sha256']==report['inputs'][task]['manifest_sha256'],'run/input mismatch')
    for task in ['chat','asr']:
        peers=[s for k,s in summaries.items() if k.startswith(task+'-')]
        require(all(s['base_asset']==peers[0]['base_asset'] for s in peers),'unpaired base assets')
    peers=[summaries[f'chat-{arm}-v1'] for arm in ['base','sft','distill']]
    require(all(p['prompt']==peers[0]['prompt'] and p['batch_size']==4 and p['max_new_tokens']==160 for p in peers),'unpaired chat settings')
    peers=[summaries[f'asr-{arm}-v1'] for arm in ['base','trained']]
    require(all(p['default_begin_suppress_tokens']==[220,50257] and p['eos_token_id']==50257 and p['max_new_tokens']==256
                and p['gpu_memory_fraction']==0.5 and p['cpu_threads']==2 for p in peers),'unpaired ASR settings')
    for task in ['chat','asr']:
        peers=[s for k,s in summaries.items() if k.startswith(task+'-')]
        relevant={'run_ai_validation.py','ai_validation_common.py','ai_baseline_metrics.py',
                  'run_ai_training_chat.py','ai_baseline_backends.py','ai_baseline_filtering.py'}
        source_hashes=[{r['path']:r['sha256'] for r in p['source_files'] if r['path'] in relevant} for p in peers]
        require(all(h==source_hashes[0] for h in source_hashes),'inference/scoring source changed across model arms')
    for arm in ['base','sft','distill']:
        rows=datasets['chat'][1]; name=f'chat-{arm}-v1'
        predictions=read_jsonl(DATA/'runs'/name/'predictions.jsonl')
        require([r['id'] for r in rows]==[p['id'] for p in predictions],'chat order mismatch')
        groups=defaultdict(list); errors=[]
        for row,prediction in zip(rows,predictions):
            try: result=resolve_filter_with_boundary_trim(prediction['prediction']['text'],row['question'],row['records'])
            except (ValueError,TypeError): result=None
            require(result==prediction['resolved'],'chat host output mismatch')
            correct=result==row['expected']
            require(correct==prediction['score']['host_exact'],'chat score mismatch')
            for label in ['all','scope:'+row['scope'],'family:'+row['family'],row['scope']+':'+row['language']]:
                groups[label].append(correct)
            if not correct: errors.append(dict(id=row['id'],family=row['family'],question=row['question'],
                raw=prediction['prediction']['text'],expected=row['expected'],actual=result))
        repeat_rows=read_jsonl(DATA/'runs'/name/'batch1-repeat.jsonl')
        require([p['id'] for p in repeat_rows]==[rows[i]['id'] for i in [0,17,24,41,48,65,72,89,96,113]],'repeat coverage mismatch')
        by_id={p['id']:(row,p) for row,p in zip(rows,predictions)}
        for repeat in repeat_rows:
            row,first=by_id[repeat['id']]
            try: result=resolve_filter_with_boundary_trim(repeat['prediction']['text'],row['question'],row['records'])
            except (ValueError,TypeError): result=None
            require(result==repeat['resolved'],'repeat host mismatch')
            require((repeat['prediction']['text']==first['prediction']['text'])==repeat['raw_equal'],'repeat raw score mismatch')
            require((result==first['resolved'])==repeat['host_equal'],'repeat host score mismatch')
        repeat_score=dict(count=len(repeat_rows),raw_equal=sum(p['raw_equal'] for p in repeat_rows),
                          host_equal=sum(p['host_equal'] for p in repeat_rows))
        require(repeat_score==summaries[name]['batch1_repeat'],'repeat aggregate mismatch')
        report['chat'][arm]=dict(groups={k:dict(count=len(v),correct=sum(v)) for k,v in groups.items()},errors=errors,repeat=repeat_score)
    for kind,allowed in [('ko',{'ko','en'}),('multi',{'en','ja','zh-Hans','zh-Hant'})]:
        rows=[r for r in datasets['ocr'][1] if r['language'] in allowed]
        arms={arm:raw(f'ocr-{kind}-v1',arm,rows) for arm in ['base','trained']}
        report['ocr'][kind]={arm:aggregate_media(values) for arm,values in arms.items()}
        report['ocr'][kind]['changes']=changes(arms['base'],arms['trained'])
        for arm,values in arms.items():
            marked=[r for r in values if r['negation_marker']]
            report['ocr'][kind][arm]['negation']=dict(count=len(marked),preserved=sum(r['negation_marker'] in r['text'] for r in marked))
            require(report['ocr'][kind][arm]==summaries[f'ocr-{kind}-v1'][arm],'OCR aggregate mismatch')
    rows=datasets['asr'][1]; vad_rows=read_jsonl(DATA/'runs/vad-v1/predictions.jsonl')
    require([r['id'] for r in rows]==[r['id'] for r in vad_rows],'VAD coverage mismatch')
    for source,row in zip(rows,vad_rows):
        require(speech_intervals(row['probabilities'])==row['intervals'] and bool(row['intervals'])==row['has_speech'],'VAD gate mismatch')
        require(row['expected_speech']==bool(source['reference']),'VAD reference mismatch')
    vad_groups=defaultdict(list)
    for row in vad_rows:
        for label in ['all','variant:'+row['variant'],'language:'+row['language']]: vad_groups[label].append(row)
    report['vad']={k:dict(count=len(v),speech=sum(r['expected_speech'] for r in v),
        missed_speech=sum(r['expected_speech'] and not r['has_speech'] for r in v),
        false_speech=sum(not r['expected_speech'] and r['has_speech'] for r in v)) for k,v in vad_groups.items()}
    require(report['vad']==summaries['vad-v1']['groups'],'VAD aggregate mismatch')
    asr_predictions={}
    for model in ['base','trained']:
        report['asr'][model]={}
        for decoder in ['default','allow_eos']:
            values=raw(f'asr-{model}-v1',decoder,rows); asr_predictions[(model,decoder)]=values
            score=aggregate_media(values)
            require(score==summaries[f'asr-{model}-v1'][decoder],'ASR aggregate mismatch')
            report['asr'][model][decoder]=dict(ungated=score)
            report['asr'][model][decoder]['clean_only']=aggregate_media([r for r in values if r['variant']=='clean'])
            display=[]; gated=[]
            for item,decision in zip(values,vad_rows):
                require(item['display_score']==media_score(item['reference'],item['display_text']),'display score mismatch')
                display.append(dict(item,text=item['display_text'],**item['display_score']))
                text=item['text'] if decision['has_speech'] else ''
                gated.append({**item,'text':text,**media_score(item['reference'],text)})
            report['asr'][model][decoder].update(display=aggregate_media(display),vad_gated=aggregate_media(gated),
                hit_token_cap=sum(r['hit_token_cap'] for r in values))
    report['asr']['clean_default_changes']=changes(
        [r for r in asr_predictions[('base','default')] if r['variant']=='clean'],
        [r for r in asr_predictions[('trained','default')] if r['variant']=='clean'])
    report['asr']['critical_regression_text_review']=[
        dict(id='FV-ASR-en-12',category='equivalent_number_rendering',detail='100 becomes a hundred'),
        dict(id='FV-ASR-en-19',category='equivalent_number_rendering',detail='2-3 km becomes two to three kilometers'),
        dict(id='FV-ASR-zh-Hans-15',category='numeric_value_differs_from_public_reference',detail='reference November (11) becomes October (10)')]
    report['asr']['critical_regression_review_scope']='Developer text comparison, not clinical or independent audio-reference adjudication; strict metrics unchanged.'
    from scripts.run_ai_validation_pages import match_rows
    detections=read_jsonl(DATA/'runs/ocr-pages-v2/detection.jsonl')
    page_sources=datasets['ocr-pages'][1]
    require([p['id'] for p in page_sources]==[d['id'] for d in detections],'document coverage mismatch')
    for page,detection in zip(page_sources,detections):
        boxes=[[min(p[0] for p in polygon),min(p[1] for p in polygon),
                max(p[0] for p in polygon),max(p[1] for p in polygon)] for polygon in detection['polygons']]
        matches=match_rows([r['box'] for r in page['rows']],boxes)
        require({str(k):v for k,v in matches.items()}==detection['matches'],'document geometry mismatch')
        require((len(matches),len(page['rows'])-len(matches),len(boxes)-len(matches))==
                (detection['matched'],detection['missed'],detection['extra']),'document count mismatch')
    report['pages']['detection']=dict(pages=len(detections),**{k:sum(d[k] for d in detections)
        for k in ['expected','detected','matched','missed','extra']})
    require(report['pages']['detection']==summaries['ocr-pages-v2']['detection'],'detection aggregate mismatch')
    for kind,allowed in [('ko',{'ko','en'}),('multi',{'en','ja','zh-Hans','zh-Hant'})]:
        page_rows=[dict(id=p['id']+'-'+str(i),reference=r['reference'])
                   for p in datasets['ocr-pages'][1] if p['language'] in allowed for i,r in enumerate(p['rows'])]
        arms={arm:raw('ocr-pages-v2',kind+'-'+arm,page_rows) for arm in ['base','trained']}
        report['pages'][kind]={arm:aggregate_media(values) for arm,values in arms.items()}
        report['pages'][kind]['changes']=changes(arms['base'],arms['trained'])
        detected_count=sum(d['detected'] for d in detections if d['language'] in allowed)
        report['pages'][kind]['detection_count']=detected_count
        for arm,values in arms.items():
            require(report['pages'][kind][arm]==summaries['ocr-pages-v2'][kind+'-'+arm],'document recognition aggregate mismatch')
            correct=report['pages'][kind][arm]['all']['exact']
            report['pages'][kind][arm]['end_to_end']=dict(exact_precision=correct/detected_count,
                exact_recall=correct/len(values),definition='extra detections count as false positives; matching uses gold geometry')
    # Independent audit of overlap declarations against actual saved inputs/audio.
    import hashlib
    import soundfile as sf
    from scripts.prepare_ai_training_asr import normalized as text_identity
    prior_ids=set(); prior_texts=set(); prior_audio=set()
    for root in [ROOT/'data/ai-training-v1/inputs/asr',ROOT/'data/ai-baseline-v1/inputs/asr']:
        for path in root.glob('*.jsonl'):
            for row in read_jsonl(path):
                if 'source_id' in row: prior_ids.add(str(row['source_id']))
                prior_texts.add(text_identity(row['reference']))
                samples,_=sf.read(root/row['path'],dtype='float32')
                prior_audio.add(hashlib.sha256(samples.tobytes()).hexdigest())
    clean=[r for r in rows if r['variant']=='clean']
    for row in clean:
        require(row['source_id'] not in prior_ids and text_identity(row['reference']) not in prior_texts,'ASR source overlap')
        samples,_=sf.read(datasets['asr'][0]/row['path'],dtype='float32')
        require(hashlib.sha256(samples.tobytes()).hexdigest() not in prior_audio,'ASR audio overlap')
    report['verification']=dict(completed_runs=len(summaries),source_and_output_hashes_verified=True,
        independently_recomputed_metrics=True,asr_prior_group_text_audio_overlap=0,
        asr_clean_unique_sentence_groups=len({r['group_id'] for r in clean}),
        asr_clean_recordings=len(clean),asr_clean_critical_references=sum(bool(strict_critical_tokens(r['reference'])) for r in clean),
        asr_speaker_independence_verified=False,
        python_tests_sha256=sha256(DATA/'python-tests-final.log'),
        preparation_issue='Initial traditional-Chinese font lacked glyphs. Unsealed preparation preserved in failed-preparation-ocr-missing-glyph; SimSun glyphs checked before final inputs. No inference used incomplete inputs.')
    test_log=(DATA/'python-tests-final.log').read_text(encoding='utf-8-sig')
    match=re.search(r'Ran (\d+) tests',test_log)
    require(match is not None and test_log.strip().endswith('OK'),'test suite did not pass')
    report['verification']['python_tests_passed']=int(match.group(1))
    report['verification']['failed_runs']=[]
    for path in sorted((DATA/'runs').glob('*/summary.json')):
        summary=read_json(path)
        if summary['status']=='failed':
            report['verification']['failed_runs'].append(dict(run_id=summary['run_id'],
                error_type=summary['error_type'],error=summary['error'],summary_sha256=sha256(path)))
        elif path.parent.name not in RUN_IDS:
            raise ValueError('unexpected unfinished or unreported run')
    destination=EXPERIMENT/'results/completed-2026-09-11'
    destination.mkdir(parents=True,exist_ok=False)
    write_json(destination/'results.json',report)
    write_markdown(report,ROOT/'docs/ai_additional_validation_2026-09-11.md')
    write_json(destination/'manifest.json',dict(created_at=stamp(),files=inventory(destination),
        report_sha256=sha256(ROOT/'docs/ai_additional_validation_2026-09-11.md')))
    print('Verified',len(summaries),'completed runs;',report['verification']['python_tests_passed'],'tests.',flush=True)


def fraction(n,d): return f'{n}/{d}'
def percent(value): return f'{value*100:.2f}%' if value is not None else '—'


def write_markdown(r,path):
    lines=['# 추가 AI 검증 결과 — 2026-09-11','',
      '모델 가중치를 고정한 개발 진단이다. 이전 학습 모델을 추가 학습하거나 앱에 연결하지 않았다. 의료 성능 또는 출시 통과 결과가 아니다.',
      '`evaluation_eligible=false`, `medical_release_gate_result=false`.', '',
      '검증 결과, 아직 모델 채택을 확정할 단계는 아니다. 단일 조회 정확도와 별개로 질문의 모호함/수첩 경계 처리가 필요하고, OCR의 검출 박스 분리와 음성의 숫자 값 변경이 남았다. 기본 디코더에 VAD를 붙인 조합은 이번 제한된 비음성 대조에서 효과가 있었으나 실제 병실 음성 검증은 필요하다.', '',
      '## 챗봇: 새로운 질문 120개','',
      '현재 단일 조회 계약 100개와 확장 경계 20개를 분리했다. 각 셀은 기대한 전체 조회 결과 또는 보류 결과와 일치한 수이다.', '',
      '| 모델 | 현재 계약 | 확장 경계 | 전체 | batch 1/4 결과 일치 |',
      '|---|---:|---:|---:|---:|']
    for arm,label in [('base','원본'),('sft','SFT'),('distill','증류')]:
        p=r['chat'][arm]; g=p['groups']; parts=[g['scope:current_contract'],g['scope:extension_boundary'],g['all']]
        lines.append('| '+label+' | '+' | '.join(fraction(x['correct'],x['count']) for x in parts)+
                     ' | '+fraction(p['repeat']['host_equal'],p['repeat']['count'])+' |')
    lines+=['','| 질문 유형 | 원본 | SFT | 증류 |','|---|---:|---:|---:|']
    for family in ['paraphrase','structured','correction','missing_day','relative_day','invalid_day','ambiguous','medical_mixed','other_notebook','instruction_attack','absent','negation']:
        values=[r['chat'][arm]['groups']['family:'+family] for arm in ['base','sft','distill']]
        lines.append('| '+family+' | '+' | '.join(fraction(x['correct'],x['count']) for x in values)+' |')
    lines+=['','모호한 복수 대상과 다른 수첩 요청은 현재 필터 스키마의 지원 범위를 넘어서는 경계 시험이다. 조회가 안 되더라도 `no_records`로 처리하면 기대한 명시적 보류와 다르므로 오답이다.',
      '현재 계약은 SFT와 증류 모두 98/100이지만 실패 양상이 다르다. 영어 지시문 공격에서 SFT는 JSON 문법을 어겼고, 일본어 지시문 공격에서 증류는 불필요한 의료 보류로 처리했다. 증류는 모호한 날짜 10건에서 날짜 하나를 임의로 선택했다. SFT와 증류 모두 다른 수첩 요청 10건을 현재 수첩 조회로 처리했다.',
      '기존 연구용 `resolve_filter`는 전달된 기록 목록을 신뢰한다. 다른 환자 기록을 섞어 전달한 호스트 시험에서 해당 기록도 반환됨을 확인했다. 선택 수첩으로 먼저 범위를 제한하면 외부 기록이 제외된다. 모바일 앱은 아직 이 모델/함수를 호출하지 않으므로 이 결과를 현재 앱의 정보 유출이라고 해석하지 않는다.',
      '기존 합성 시험의 증류 200/200은 새로운 문장 구조·경계 질문까지 보장하지 않는다. 이번에도 실제 의료 답변이나 RAG 근거 정확성을 시험한 것은 아니다.', '',
      '## OCR: 다른 글꼴과 이미지 변형','',
      '100개 언어별 문자열의 5변형, 총 500개 줄 이미지. 영어 100개는 두 인식기가 공유한다. 숫자·단위 지표에는 합성 자료의 검사용 식별번호도 포함된다.', '',
      '| 인식기 | 원문 완전 일치, 원본 → 학습 | CER | 숫자·단위 일치 | 부정 표현 보존 |',
      '|---|---:|---:|---:|---:|']
    for kind,label in [('ko','한국어/영어'),('multi','영어/일본어/간체/번체')]:
        p=r['ocr'][kind]; a=p['base']['all']; b=p['trained']['all']; na=p['base']['negation']; nb=p['trained']['negation']
        lines.append(f'| {label} | {a["exact"]} → {b["exact"]}/{a["count"]} | {percent(a["cer"])} → {percent(b["cer"])} | {a["critical_match"]} → {b["critical_match"]}/{a["critical_count"]} | {na["preserved"]} → {nb["preserved"]}/{na["count"]} |')
    lines+=['','| 인식기/언어 | 원본 원문 일치 | 학습 원문 일치 |','|---|---:|---:|']
    for kind in ['ko','multi']:
        for group,a in r['ocr'][kind]['base'].items():
            if group.startswith('language:'):
                b=r['ocr'][kind]['trained'][group]
                lines.append(f'| {kind}/{group[9:]} | {a["exact"]}/{a["count"]} | {b["exact"]}/{b["count"]} |')
    d=r['pages']['detection']
    lines+=['','다국어 줄 시험은 원본과 학습 모델 모두 CER가 0이어서, 원문 일치 향상은 주로 공백·대소문자 정돈이다. 이 수치를 새로운 글자 판독 능력의 향상으로 해석하지 않는다.',
      '','### 검출부터 인식까지','',
      f'합성 문서 {d["pages"]}개, {d["expected"]}행에서 연결 {d["matched"]}, 누락 {d["missed"]}, 추가/중복 검출 {d["extra"]}. 같은 줄 시험의 일부 문자열을 재사용했으므로 독립 표본으로 더하지 않는다.', '',
      '| 실제 검출 crop 인식기 | 원본 원문 일치 | 학습 원문 일치 | 숫자·단위 원본 → 학습 |',
      '|---|---:|---:|---:|']
    for kind in ['ko','multi']:
        a=r['pages'][kind]['base']['all']; b=r['pages'][kind]['trained']['all']
        lines.append(f'| {kind} | {a["exact"]}/{a["count"]} | {b["exact"]}/{b["count"]} | {a["critical_match"]} → {b["critical_match"]}/{a["critical_count"]} |')
    lines+=['','행 연결은 정답 사각형을 사용하는 평가 절차이며 앱 기능이 아니다. 추가 박스는 별도 오류로 보존했다. 추가 박스를 오답으로 포함한 다국어 학습 모델의 원문 일치 precision은 '+
      percent(r['pages']['multi']['trained']['end_to_end']['exact_precision'])+'이다.',
      '흐린 일본어 문서에서는 `V12000 0.05 mg`가 `V12000 0.05`로 인식되어 단위가 빠졌다. 다른 행에서도 검출 박스가 갈라져 식별번호와 본문이 분리됐다. 인식 head 학습만으로 검출·행 연결 문제가 해결되지 않음을 확인했다.',
      '숫자/단위 오류가 한 건이라도 남으면 자동 저장·복약 판단의 근거로 사용할 수 없다. 실제 처방전·손글씨·반사광·접힌 종이는 이 합성 시험에 포함되지 않았다.', '',
      '## 음성: 새 공개 녹음과 디코더/VAD 대조','',
      f'새 원본 녹음 80개(문장 그룹 {r["verification"]["asr_clean_unique_sentence_groups"]}개), 음량 -30 dB/잡음 10 dB 변형 40개, 비음성 24개. 기존 학습/평가의 문장 ID·정규화 전사·PCM 해시와 중복 0건을 다시 확인했다. 공식 FLEURS test가 아닌 공개 train에서 따로 분리한 집합이며 화자 독립은 확인하지 못했다.',
      '원본 음성 80개 중 숫자·단위 토큰 포함 문장은 40개이다. 숫자를 글자로 쓰는 표기 차이도 strict 오류로 남겼으며, 숫자 의미 보존이 검증됐다고 해석하지 않는다.', '',
      '| 모델/디코더 | 새 원본 80개 CER | 중국어 간체 표시 적용 CER | 숫자·단위 일치 | VAD 전 비음성 출력 | VAD 후 비음성 출력 |',
      '|---|---:|---:|---:|---:|---:|']
    for model in ['base','trained']:
        for decoder in ['default','allow_eos']:
            p=r['asr'][model][decoder]; a=p['ungated']['variant:clean']; controls=p['ungated']['all']; after=p['vad_gated']['all']
            lines.append(f'| {model}/{decoder} | {percent(a["cer"])} | {percent(p["display"]["variant:clean"]["cer"])} | {a["critical_match"]}/{a["critical_count"]} | {controls["control_nonempty"]}/{controls["controls"]} | {after["control_nonempty"]}/{after["controls"]} |')
    lines+=['','| 새 원본 음성 언어(각 20개) | 원본 CER | 학습 CER, 기본 디코더 |','|---|---:|---:|']
    for lang in ['ko','en','ja','zh-Hans']:
        a=r['asr']['base']['default']['clean_only']['language:'+lang]
        b=r['asr']['trained']['default']['clean_only']['language:'+lang]
        lines.append(f'| {lang} | {percent(a["cer"])} | {percent(b["cer"])} |')
    v=r['vad']['all']
    lines+=['',f'VAD는 음성 {v["speech"]}개 중 누락 {v["missed_speech"]}개, 비음성 {v["count"]-v["speech"]}개 중 음성 오판 {v["false_speech"]}개였다. 24개 비음성은 같은 6종 파형을 4언어 프롬프트로 반복한 대조군이다.',
      '사용한 VAD는 Silero v6.2의 확률 출력에 연속 250 ms/임계값 0.5를 적용한 전체 클립 gate이다. 공식 timestamp 함수와 같은 알고리즘이라고 주장하지 않는다. 통과한 클립은 자르지 않았고 ASR 출력을 재사용했다. 실제 병실 소음·다른 사람 목소리·짧은 약 이름·음성 중 무음 구간의 환각은 별도 시험이 필요하다.',
      '기본 Whisper의 첫 EOS 억제와 이를 제거한 디코더를 직접 비교했다. 학습 모델에서 EOS 허용은 비음성 출력을 24/24에서 1/24로 줄였지만 정상 중국어 원본 녹음 1개도 빈 출력으로 만들었다. VAD는 해당 녹음을 통과시켰으므로 이 누락은 VAD가 아닌 디코더 쪽에서 발생했다. 기본 디코더는 음성 120개에서 빈 출력이 없었다. 따라서 EOS 억제 해제를 그대로 적용하는 것은 보류한다.',
      '숫자·단위 strict 일치는 28/40에서 25/40으로 줄었다. 새 회귀 3건을 전사 문자열로 확인한 결과 2건은 `100 → a hundred`, `2-3 km → two to three kilometers`라는 값이 같은 표기 차이였다. 나머지 1건은 공개 기준 전사의 `2008年11月26日`가 `2008年10月26日`로 바뀌었다. 독립적인 원음 재검수나 임상 판정은 아니며, strict 점수를 사후 수정하지 않았다.', '',
      '## 확인 범위와 다음 단계','',
      f'- 의료 회귀시험 포함 Python 자동 시험 {r["verification"]["python_tests_passed"]}개 통과. 완료 실행 {len(r["runs"])}개의 소스·입력·결과 해시와 지표를 검증했다. 추론 실행의 Python 네트워크 시도는 0건이다.',
      '- 문서 OCR 첫 실행은 추론 전 Windows Torch/Paddle DLL 로딩 충돌로 실패했다. 실패 실행을 보존하고 Torch를 먼저 로드한 별도 실행에서 완료했다. 입력·모델·검출 임계값은 바꾸지 않았다. 번체 글꼴의 글자 누락도 입력 생성 단계에서 발견해 완성 전 교체했다.',
      '- 앱 코드·저장된 모델 가중치·이전 결과는 변경하지 않았다. 현재 모바일 ChatService는 대화 저장을 수행하고 이 실험 모델을 호출하지 않는다.',
      '- Android 연결 상태를 조회했으나 연결 기기는 없었다. 모바일 변환·지연·메모리·발열·배터리·앱 통합은 이번에 검증하지 못했다. Mac이 없어 iOS 실행 검증도 미완료이다.',
      '- 임상 검수, 승인된 의료 근거/RAG, 약물·위험 규칙, 실제 처방전과 진료 음성 평가는 여전히 필요하다. 이 결과로 의료 기능을 활성화하지 않는다.',
      '- 상세 오답·언어별/변형별 지표·원본 출력 경로는 `experiments/ai_validation_v1/results/completed-2026-09-11/results.json`에 있다. 이 평가 집합은 이제 사용되었으므로 다음 학습의 최종 미사용 시험으로 재사용하지 않는다.', '',
      '## 원본 자료','',
      '- [FLEURS, Google, CC-BY-4.0](https://huggingface.co/datasets/google/fleurs), revision `168de341b3db6859a9bac1c50a2ef5e3b47647e0`.',
      '- [Silero VAD v6.2, MIT](https://github.com/snakers4/silero-vad/tree/be95df9152c0d7618fa1edfeb296fc3dae32376f), 모델 및 라이선스 SHA-256은 `vad-assets.lock.json`.',
      '- [Whisper 생성 설정 공식 문서](https://huggingface.co/docs/transformers/main/model_doc/whisper). 실제 시험에서는 설치된 transformers 5.16.1 및 잠긴 모델 설정을 사용했다.',
      '- [PaddleOCR 공식 코드](https://github.com/PaddlePaddle/PaddleOCR/tree/2661c7c0ef5c613e8f93c6e93b2e052399f0f854), 기존 자산 고정 파일 유지.', '']
    path.write_text('\n'.join(lines),encoding='utf-8')


if __name__=='__main__': main()
