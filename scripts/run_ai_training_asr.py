"""Offline Whisper-small LoRA pilot on disjoint public speech and silence controls."""
from __future__ import annotations
import argparse
from collections import defaultdict
import json
import math
import random
import time
import traceback

from scripts.ai_training_common import (dataset,inventory,model_asset,new_run,offline,
    read_jsonl,sha256,stamp,write_json,write_jsonl)
from scripts.ai_baseline_metrics import transcript_score,strict_critical_tokens
from scripts.ai_training_asr_features import load_features


def aggregate(rows):
    groups=defaultdict(list)
    for row in rows:
        groups['all'].append(row);groups[row['language']].append(row)
    result={}
    for lang,items in groups.items():
        speech=[r for r in items if r['reference']]
        controls=[r for r in items if not r['reference']]
        n=sum(r['score']['reference_characters'] for r in speech)
        result[lang]={'speech_count':len(speech),
            'cer':sum(r['score']['character_edits'] for r in speech)/n if n else None,
            'display_normalized_cer':sum(r['display_score']['character_edits'] for r in speech)/n if n else None,
            'exact':sum(r['text']==r['reference'] for r in speech),
            'strict_numeric_unit_match':sum(r['strict_numeric_unit_match'] for r in speech),
            'silence_controls':len(controls),'silence_nonempty':sum(bool(r['text'].strip()) for r in controls)}
    return result


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--run-id',required=True)
    parser.add_argument('--epochs',type=int,default=2)
    args=parser.parse_args()
    if args.epochs<1:parser.error('epochs must be positive')
    attempts=offline();directory,summary=new_run(args.run_id,vars(args))
    try:
        import torch
        from peft import LoraConfig,get_peft_model,PeftModel
        from transformers import AutoModelForSpeechSeq2Seq,AutoProcessor
        torch.set_num_threads(2);torch.manual_seed(42)
        torch.cuda.set_per_process_memory_fraction(0.50)
        base,asset=model_asset('whisper_small')
        processor=AutoProcessor.from_pretrained(base,local_files_only=True,trust_remote_code=False)
        model=AutoModelForSpeechSeq2Seq.from_pretrained(base,local_files_only=True,
            use_safetensors=True,trust_remote_code=False,dtype=torch.float16,
            device_map='cuda:0',attn_implementation='sdpa').eval()
        inputs,_=dataset('asr')
        rows={split:read_jsonl(inputs/f'{split}.jsonl') for split in ['train','validation','test']}
        summary.update(base_asset=asset,input_manifest_sha256=sha256(inputs/'manifest.json'),
            train_examples=len(rows['train']),epochs=args.epochs,learning_rate=0.00005,
            batch_size=1,gradient_accumulation=4,adapter_rank=8,lora_alpha=16,
            targets=['q_proj','v_proj'],cpu_threads=2,gpu_memory_fraction=0.5,
            transcript_metric_version='reference-first-v2',
            selection='fixed final epoch, no tuning on test',
            task='general multilingual read-speech pilot, not clinic/medical training')
        write_json(directory/'summary.json',summary)
        features,feature_masks,targets,feature_manifest=load_features(rows)
        if feature_manifest['base_asset']!=asset:raise ValueError('feature cache used another base model')
        summary['feature_manifest_sha256']=sha256(inputs.parent/'asr-features/manifest.json')
        summary['silence_feature_overlap']=feature_manifest['silence_feature_overlap']
        summary['silence_interpretation']='synthetic controls can have identical padded mel features across durations; this is a learned-control check, not held-out silence generalization'
        write_json(directory/'summary.json',summary)
        from opencc import OpenCC
        simplified=OpenCC('t2s')

        def evaluate(split,label):
            predictions=[];model.eval()
            for i,row in enumerate(rows[split]):
                language='zh' if row['language'].startswith('zh') else row['language']
                with torch.inference_mode():
                    ids=model.generate(input_features=features[row['id']].to('cuda:0',torch.float16),
                        attention_mask=feature_masks[row['id']].to('cuda:0'),
                        language=language,task='transcribe',max_new_tokens=256,do_sample=False)
                text=processor.batch_decode(ids,skip_special_tokens=True)[0]
                display_text=simplified.convert(text) if row['language'].startswith('zh') else text
                predictions.append({'id':row['id'],'language':row['language'],'reference':row['reference'],
                    'text':text,'score':transcript_score(reference=row['reference'],prediction=text),
                    'display_text':display_text,'display_score':transcript_score(reference=row['reference'],prediction=display_text),
                    'strict_numeric_unit_match':strict_critical_tokens(text)==strict_critical_tokens(row['reference']),
                    'hit_token_cap':ids.shape[-1]>=260})
                if (i+1)%20==0:print(label,i+1,len(rows[split]),flush=True)
            write_jsonl(directory/(label+'.jsonl'),predictions)
            artifact=directory/(label+'.jsonl')
            summary.setdefault('prediction_artifacts',[]).append({'path':artifact.name,'sha256':sha256(artifact)})
            result=aggregate(predictions);print(label,json.dumps(result),flush=True)
            return result

        summary['baseline_validation']=evaluate('validation','baseline-validation')
        summary['baseline_test']=evaluate('test','baseline-test')
        model=get_peft_model(model,LoraConfig(r=8,lora_alpha=16,lora_dropout=0.0,
            target_modules=['q_proj','v_proj'],bias='none'))
        model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={'use_reentrant':False})
        model.config.use_cache=False;model.train()
        params=[p for p in model.parameters() if p.requires_grad]
        initial={n:p.detach().cpu().clone() for n,p in model.named_parameters() if p.requires_grad}
        summary['trainable_parameters']=sum(p.numel() for p in params)
        optimizer=torch.optim.AdamW(params,lr=0.00005,weight_decay=0.01)
        optimizer.zero_grad(set_to_none=True);step=0;started=time.perf_counter()
        torch.cuda.reset_peak_memory_stats()
        with (directory/'loss.jsonl').open('x',encoding='utf-8') as log:
            for epoch in range(args.epochs):
                order=list(rows['train']);random.Random(42+epoch).shuffle(order)
                for offset in range(0,len(order),4):
                    batch=order[offset:offset+4];loss_sum=0.0
                    for row in batch:
                        decoder,labels=targets[row['id']]
                        with torch.autocast('cuda',dtype=torch.bfloat16):
                            output=model(input_features=features[row['id']].to('cuda:0',torch.float16),
                                attention_mask=feature_masks[row['id']].to('cuda:0'),
                                decoder_input_ids=torch.tensor([decoder],device='cuda:0'),
                                labels=torch.tensor([labels],device='cuda:0'),use_cache=False)
                            loss=output.loss
                        if not torch.isfinite(loss):raise FloatingPointError('nonfinite ASR loss')
                        loss_sum+=float(loss.detach());(loss/len(batch)).backward()
                        del output,loss
                    norm=torch.nn.utils.clip_grad_norm_(params,1.0,error_if_nonfinite=True)
                    if not math.isfinite(float(norm)) or float(norm)<=0:raise FloatingPointError('invalid ASR gradient')
                    optimizer.step();optimizer.zero_grad(set_to_none=True);step+=1
                    item={'epoch':epoch+1,'step':step,'loss':loss_sum/len(batch),'gradient_norm':float(norm),
                        'elapsed_seconds':time.perf_counter()-started,
                        'gpu_allocated_gib':torch.cuda.max_memory_allocated()/1024**3}
                    log.write(json.dumps(item)+'\n');log.flush()
                    if step%5==0:print(json.dumps(item),flush=True)
        delta=sum(float((p.detach().cpu()-initial[n]).abs().sum()) for n,p in model.named_parameters() if p.requires_grad)
        if not math.isfinite(delta) or delta<=0:raise ValueError('ASR adapter did not change')
        model.save_pretrained(directory/'adapter',safe_serialization=True,save_embedding_layers=False)
        summary.update(adapter_delta_l1=delta,adapter_files=inventory(directory/'adapter'),
            training_seconds=time.perf_counter()-started,optimizer_steps=step,
            peak_gpu_allocated_gib=torch.cuda.max_memory_allocated()/1024**3)
        # Reconstruct on the same FP16 base and reload from disk for evaluation.
        del optimizer,params,initial,model
        import gc
        gc.collect();torch.cuda.empty_cache()
        base_model=AutoModelForSpeechSeq2Seq.from_pretrained(base,local_files_only=True,
            use_safetensors=True,trust_remote_code=False,dtype=torch.float16,
            device_map='cuda:0',attn_implementation='sdpa')
        model=PeftModel.from_pretrained(base_model,directory/'adapter',local_files_only=True,is_trainable=False)
        summary.update(trained_validation=evaluate('validation','trained-validation'),
            trained_test=evaluate('test','trained-test'),status='completed')
    except BaseException as exc:
        summary.update(status='failed',error_type=type(exc).__name__,error=str(exc))
        (directory/'failure.txt').write_text(traceback.format_exc(),encoding='utf-8');raise
    finally:
        summary.update(finished_at=stamp(),python_network_attempts=attempts)
        write_json(directory/'summary.json',summary)


if __name__=='__main__':main()
