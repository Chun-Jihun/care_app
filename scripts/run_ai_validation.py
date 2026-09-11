"""Frozen-weight chatbot, OCR and ASR diagnostics; one GPU backend per process."""
import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import sys
import time

from scripts.ai_validation_common import (DATA, EXPERIMENT, ROOT, aggregate_media, inputs,
    media_score, read_json, run, sha256, speech_intervals, verify_files, write_jsonl)


def chat(args):
    from scripts.run_ai_training_chat import load_backend, evaluate, predict
    from scripts.ai_baseline_filtering import FILTER_PROMPT, resolve_filter_with_boundary_trim
    adapters={'base':None,'sft':'chat-2b-sft-v1','distill':'chat-2b-distill-v1'}
    with run(args.run_id,vars(args)) as (directory,summary):
        input_dir,rows,_=inputs('chat')
        backend,asset=load_backend('qwen35_2b',adapter=adapters[args.model])
        summary.update(base_asset=asset,input_manifest_sha256=sha256(input_dir/'manifest.json'),
            prompt=FILTER_PROMPT,batch_size=4,max_new_tokens=160,adapter_run=adapters[args.model])
        summary['legacy_evaluator'],predictions=evaluate(backend,rows,directory/'predictions.jsonl',batch_size=4)
        groups=defaultdict(list)
        for row,prediction in zip(rows,predictions):
            for label in ['all','scope:'+row['scope'],'language:'+row['language'],'family:'+row['family']]:
                groups[label].append(prediction)
        summary['groups']={k:dict(count=len(v),host_exact=sum(p['score']['host_exact'] for p in v),
            schema_valid=sum(p['score']['schema_valid'] for p in v),
            record_answer=sum((p['resolved'] or {}).get('status')=='record_answer' for p in v))
            for k,v in groups.items()}
        repeated=[]
        for i in [0,17,24,41,48,65,72,89,96,113]:
            row=rows[i]; prediction=predict(backend,row['question'])
            try: resolved=resolve_filter_with_boundary_trim(prediction['text'],row['question'],row['records'])
            except (ValueError,TypeError): resolved=None
            repeated.append(dict(id=row['id'],prediction=prediction,resolved=resolved,
                raw_equal=prediction['text']==predictions[i]['prediction']['text'],
                host_equal=resolved==predictions[i]['resolved']))
        write_jsonl(directory/'batch1-repeat.jsonl',repeated)
        summary['batch1_repeat']=dict(count=len(repeated),raw_equal=sum(r['raw_equal'] for r in repeated),
                                    host_equal=sum(r['host_equal'] for r in repeated))


def ocr_model(kind):
    import paddle
    import yaml
    source=read_json(ROOT/'experiments/ai_training_v1/ocr-assets.lock.json')
    asset_root=Path(source['directory'])
    bytecode=tuple(p.relative_to(asset_root).as_posix() for p in asset_root.rglob('*.pyc')
                   if '__pycache__' in p.relative_to(asset_root).parts)
    verify_files(asset_root,source['files'],allow_extra=bytecode)
    sys.dont_write_bytecode=True
    code=Path(source['source']['directory']); sys.path.insert(0,str(code))
    from ppocr.modeling.architectures import build_model
    name='korean_PP-OCRv5_mobile_rec' if kind=='ko' else 'PP-OCRv5_mobile_rec'
    relative='multi_language/'+name+'.yml' if kind=='ko' else name+'.yml'
    config=yaml.safe_load((code/'configs/rec/PP-OCRv5'/relative).read_text(encoding='utf-8'))
    dictionary=code/config['Global']['character_dict_path']
    characters=['blank']+dictionary.read_text(encoding='utf-8').splitlines()+[' ']
    config['Architecture']['Head']['out_channels_list']={'CTCLabelDecode':len(characters),'NRTRLabelDecode':len(characters)+3}
    model=build_model(config['Architecture'])
    base=asset_root/(name+'_pretrained.pdparams'); state=paddle.load(str(base))
    if set(state)!=set(model.state_dict()) or any(list(state[k].shape)!=list(v.shape) for k,v in model.state_dict().items()):
        raise ValueError('OCR base architecture mismatch')
    model.set_state_dict(state); model.eval()
    trained=ROOT/'data/ai-training-v1/runs'/('ocr-ko-head-sft-v2' if kind=='ko' else 'ocr-multi-head-sft-v1')
    previous=read_json(trained/'summary.json'); checkpoint=trained/'ctc-head.pdparams'
    if previous['status']!='completed' or sha256(checkpoint)!=previous['checkpoint_sha256']:
        raise ValueError('unsealed OCR checkpoint')
    return model,characters,checkpoint,dict(base_sha256=sha256(base),dictionary_sha256=sha256(dictionary),
        checkpoint_sha256=sha256(checkpoint),training_run=trained.name)


def ocr(args):
    os.environ.update(OMP_NUM_THREADS='2',MKL_NUM_THREADS='2')
    with run(args.run_id,vars(args)) as (directory,summary):
        import paddle
        from scripts.run_ai_training_ocr import image_array,decode_ctc
        paddle.set_device('cpu')
        input_dir,rows,_=inputs('ocr')
        allowed={'ko','en'} if args.model=='ko' else {'en','ja','zh-Hans','zh-Hant'}
        rows=[r for r in rows if r['language'] in allowed]
        model,characters,checkpoint,assets=ocr_model(args.model)
        summary.update(assets=assets,input_manifest_sha256=sha256(input_dir/'manifest.json'),cpu_threads=2)
        features=[]
        for i,row in enumerate(rows):
            with paddle.no_grad():
                x=paddle.to_tensor(image_array(input_dir/row['path'])[None,:,:,:])
                features.append(model.head.ctc_encoder(model.backbone(x)).detach())
            if (i+1)%50==0: print('OCR features',i+1,len(rows),flush=True)
        for arm in ['base','trained']:
            head=model.head.ctc_head
            if arm=='trained': head.set_state_dict(paddle.load(str(checkpoint)))
            head.eval(); predictions=[]
            for row,feature in zip(rows,features):
                with paddle.no_grad(): text=decode_ctc(head(feature).argmax(axis=-1).numpy()[0],characters)
                marker=row['negation_marker']
                predictions.append(dict(id=row['id'],language=row['language'],variant=row['variant'],
                    group_id=row['group_id'],reference=row['reference'],text=text,
                    negation_marker=marker,negation_preserved=marker in text if marker else None,
                    **media_score(row['reference'],text)))
            write_jsonl(directory/(arm+'.jsonl'),predictions)
            summary[arm]=aggregate_media(predictions)
            marked=[r for r in predictions if r['negation_marker']]
            summary[arm]['negation']=dict(count=len(marked),preserved=sum(r['negation_preserved'] for r in marked))
            print(arm,json.dumps(summary[arm]['all']),flush=True)


def vad(args):
    with run(args.run_id,vars(args)) as (directory,summary):
        import torch
        import soundfile as sf
        torch.set_num_threads(2)
        input_dir,rows,_=inputs('asr')
        lock=read_json(EXPERIMENT/'vad-assets.lock.json'); root=Path(lock['directory'])
        verify_files(root,lock['files'])
        model=torch.jit.load(str(root/'silero_vad.jit'),map_location='cpu').eval()
        summary.update(asset=lock,input_manifest_sha256=sha256(input_dir/'manifest.json'),
            gate='custom contiguous 512-sample windows p>=0.5 for at least250ms; whole clip; not official timestamp helper',
            cpu_threads=2)
        results=[]
        for i,row in enumerate(rows):
            samples,sr=sf.read(input_dir/row['path'],dtype='float32')
            if sr!=16000 or samples.ndim!=1: raise ValueError('unexpected VAD audio shape')
            model.reset_states(); probabilities=[]; started=time.perf_counter()
            for offset in range(0,len(samples),512):
                chunk=torch.from_numpy(samples[offset:offset+512])
                if len(chunk)<512: chunk=torch.nn.functional.pad(chunk,(0,512-len(chunk)))
                with torch.inference_mode(): probabilities.append(float(model(chunk,sr).item()))
            spans=speech_intervals(probabilities)
            results.append(dict(id=row['id'],language=row['language'],variant=row['variant'],
                expected_speech=bool(row['reference']),has_speech=bool(spans),intervals=spans,
                probabilities=probabilities,seconds=time.perf_counter()-started))
            if (i+1)%24==0: print('VAD',i+1,len(rows),flush=True)
        write_jsonl(directory/'predictions.jsonl',results)
        groups=defaultdict(list)
        for row in results:
            for label in ['all','variant:'+row['variant'],'language:'+row['language']]: groups[label].append(row)
        summary['groups']={k:dict(count=len(v),speech=sum(r['expected_speech'] for r in v),
            missed_speech=sum(r['expected_speech'] and not r['has_speech'] for r in v),
            false_speech=sum(not r['expected_speech'] and r['has_speech'] for r in v)) for k,v in groups.items()}


def asr(args):
    with run(args.run_id,vars(args)) as (directory,summary):
        import torch
        import soundfile as sf
        from peft import PeftModel
        from transformers import AutoModelForSpeechSeq2Seq,AutoProcessor
        from opencc import OpenCC
        from scripts.ai_training_common import model_asset
        torch.set_num_threads(2); torch.cuda.set_per_process_memory_fraction(0.5)
        input_dir,rows,_=inputs('asr'); base,asset=model_asset('whisper_small')
        processor=AutoProcessor.from_pretrained(base,local_files_only=True,trust_remote_code=False)
        model=AutoModelForSpeechSeq2Seq.from_pretrained(base,local_files_only=True,trust_remote_code=False,
            use_safetensors=True,dtype=torch.float16,device_map='cuda:0',attn_implementation='sdpa').eval()
        if args.model=='trained':
            trained=ROOT/'data/ai-training-v1/runs/asr-small-lora-v1'
            previous=read_json(trained/'summary.json')
            if previous['status']!='completed': raise ValueError('incomplete ASR adapter')
            verify_files(trained/'adapter',previous['adapter_files'])
            model=PeftModel.from_pretrained(model,trained/'adapter',local_files_only=True,is_trainable=False).eval()
            summary['adapter_files']=previous['adapter_files']
        summary.update(base_asset=asset,input_manifest_sha256=sha256(input_dir/'manifest.json'),
            default_begin_suppress_tokens=model.generation_config.begin_suppress_tokens,
            eos_token_id=model.generation_config.eos_token_id,max_new_tokens=256,
            gpu_memory_fraction=0.5,cpu_threads=2)
        simplify=OpenCC('t2s')
        handles={arm:(directory/(arm+'.jsonl')).open('x',encoding='utf-8') for arm in ['default','allow_eos']}
        predictions={arm:[] for arm in handles}
        try:
            for i,row in enumerate(rows):
                samples,sr=sf.read(input_dir/row['path'],dtype='float32')
                if sr!=16000 or samples.ndim!=1 or len(samples)>30*sr: raise ValueError('invalid ASR audio')
                feature=processor(samples,sampling_rate=sr,return_tensors='pt',return_attention_mask=True)
                language='zh' if row['language'].startswith('zh') else row['language']
                for arm in handles:
                    options={}
                    if arm=='allow_eos':
                        options['begin_suppress_tokens']=[t for t in model.generation_config.begin_suppress_tokens
                                                         if t!=model.generation_config.eos_token_id]
                    start=time.perf_counter()
                    with torch.inference_mode():
                        ids=model.generate(input_features=feature.input_features.to('cuda:0',torch.float16),
                            attention_mask=feature.attention_mask.to('cuda:0'),language=language,task='transcribe',
                            max_new_tokens=256,do_sample=False,**options)
                    text=processor.batch_decode(ids,skip_special_tokens=True)[0]
                    display=simplify.convert(text) if language=='zh' else text
                    output=dict(id=row['id'],language=row['language'],variant=row['variant'],group_id=row['group_id'],
                        reference=row['reference'],text=text,seconds=time.perf_counter()-start,
                        display_text=display,display_score=media_score(row['reference'],display),
                        hit_token_cap=ids.shape[-1]>=260,**media_score(row['reference'],text))
                    predictions[arm].append(output)
                    handles[arm].write(json.dumps(output,ensure_ascii=False)+'\n'); handles[arm].flush()
                if (i+1)%12==0: print('ASR',args.model,i+1,len(rows),flush=True)
        finally:
            for handle in handles.values(): handle.close()
        for arm,items in predictions.items(): summary[arm]=aggregate_media(items)


if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('task',choices=['chat','ocr','vad','asr'])
    parser.add_argument('--model',default='base'); parser.add_argument('--run-id',required=True)
    args=parser.parse_args()
    choices={'chat':['base','sft','distill'],'ocr':['ko','multi'],'asr':['base','trained'],'vad':['base']}
    if args.model not in choices[args.task]: parser.error('invalid model for task')
    globals()[args.task](args)
