"""Offline query-extraction teacher, QLoRA SFT and sequence-distillation runner."""
from __future__ import annotations

import argparse
from collections import Counter
import json
import math
import random
import time
import traceback

from scripts.ai_training_common import (DATA, ROOT, canonical, completion_tokens, dataset,
    inventory, model_asset, new_run, offline, read_json, read_jsonl, sha256,
    stamp, verify_files, write_json, write_jsonl)
from scripts.ai_baseline_filtering import FILTER_PROMPT, resolve_filter_with_boundary_trim


def accept_teacher(row, prediction):
    try:
        return json.loads(prediction)==row['target']
    except (ValueError,TypeError):
        return False


def messages(question):
    return [{'role':'system','content':[{'type':'text','text':FILTER_PROMPT}]},
            {'role':'user','content':[{'type':'text','text':question}]}]


def load_backend(name,adapter=None,training=False):
    import torch
    torch.set_num_threads(2)
    torch.cuda.set_per_process_memory_fraction(0.50)
    from scripts.ai_baseline_backends import ChatBackend
    directory,entry=model_asset(name)
    backend=ChatBackend(directory,grammar=False)
    if training:
        from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
        model=prepare_model_for_kbit_training(backend.model,use_gradient_checkpointing=True,
                    gradient_checkpointing_kwargs={'use_reentrant':False})
        targets=[n for n,m in model.named_modules()
                 if '.language_model.layers.' in n and isinstance(m,torch.nn.Linear)]
        if not targets or any('visual' in n for n in targets):
            raise ValueError('missing or invalid text-only adapter target modules')
        # Keep the frozen, very large token embedding and unused visual encoder in BF16.
        # Layer norms remain FP32 after PEFT preparation; adapters are FP32.
        for name_,param in model.named_parameters():
            if param.dtype.is_floating_point and ('embed_tokens' in name_ or '.visual.' in name_):
                param.data=param.data.to(torch.bfloat16)
        model.config.use_cache=False
        backend.model=get_peft_model(model,LoraConfig(r=8,lora_alpha=16,lora_dropout=0.0,
            bias='none',target_modules=targets,task_type='CAUSAL_LM'))
        backend.model.train()
    elif adapter:
        from peft import PeftModel
        parent=DATA/'runs'/adapter
        record=read_json(parent/'summary.json')
        if record['status']!='completed' or 'adapter_files' not in record:
            raise ValueError('only completed, sealed training adapters are eligible for evaluation')
        verify_files(parent/'adapter',record['adapter_files'])
        backend.model=PeftModel.from_pretrained(backend.model,parent/'adapter',
            local_files_only=True,is_trainable=False).eval()
    return backend,entry


def prompt_ids(backend,question):
    inputs=backend.processor.apply_chat_template(messages(question),tokenize=True,
        add_generation_prompt=True,enable_thinking=False,return_dict=True,return_tensors='pt')
    return inputs['input_ids'][0].tolist()


def predict(backend,question):
    import torch
    inputs=backend.processor.apply_chat_template(messages(question),tokenize=True,
        add_generation_prompt=True,return_dict=True,return_tensors='pt',enable_thinking=False).to('cuda:0')
    if inputs['input_ids'].shape[1]>1024:
        raise ValueError('evaluation prompt too long')
    started=time.perf_counter()
    with torch.inference_mode():
        outputs=backend.model.generate(**inputs,max_new_tokens=160,do_sample=False)
    ids=outputs[0,inputs['input_ids'].shape[1]:]
    torch.cuda.synchronize()
    return {'text':backend.tokenizer.decode(ids,skip_special_tokens=True),
            'generated_tokens':int(len(ids)),'hit_token_cap':len(ids)>=160,
            'seconds':time.perf_counter()-started}


def predict_batch(backend,questions):
    if len(questions)==1:return [predict(backend,questions[0])]
    import torch
    backend.tokenizer.padding_side='left'
    inputs=backend.processor.apply_chat_template([messages(q) for q in questions],tokenize=True,
        add_generation_prompt=True,return_dict=True,return_tensors='pt',padding=True,
        enable_thinking=False).to('cuda:0')
    if inputs['input_ids'].shape[1]>1024:raise ValueError('batched prompt too long')
    started=time.perf_counter()
    with torch.inference_mode():
        outputs=backend.model.generate(**inputs,max_new_tokens=160,do_sample=False)
    torch.cuda.synchronize();seconds=time.perf_counter()-started
    stop=backend.stop_token_ids if isinstance(backend.stop_token_ids,list) else [backend.stop_token_ids]
    results=[]
    for sequence in outputs[:,inputs['input_ids'].shape[1]:].tolist():
        endings=[i for i,token in enumerate(sequence) if token in stop]
        ids=sequence[:endings[0]+1] if endings else sequence
        results.append({'text':backend.tokenizer.decode(ids,skip_special_tokens=True),
            'generated_tokens':len(ids),'hit_token_cap':not endings and len(ids)>=160,
            'seconds':seconds,'batch_size':len(questions),
            'latency_kind':'batch_completion_wall_time_per_member'})
    return results


def evaluate(backend,rows,path,batch_size=1):
    counts=Counter(); per_language={}; results=[]
    with path.open('x',encoding='utf-8') as handle:
        for i,row in enumerate(rows):
            if i%batch_size==0:
                batch_predictions=predict_batch(backend,[r['question'] for r in rows[i:i+batch_size]])
            prediction=batch_predictions[i%batch_size]
            try:
                parsed=json.loads(prediction['text'])
                schema_valid=(isinstance(parsed,dict) and set(parsed)=={'kind','day','time','item'}
                    and parsed['kind'] in {'lookup','medical'}
                    and all(parsed[k] is None or isinstance(parsed[k],str) for k in ['day','time','item']))
                raw_exact=parsed==row['target'] if 'target' in row else None
                result=resolve_filter_with_boundary_trim(prediction['text'],row['question'],row['records'])
            except (ValueError,TypeError):
                schema_valid=False; raw_exact=False; result=None
            score={'schema_valid':schema_valid,'filter_exact':raw_exact,
                   'host_exact':result==row['expected'],
                   'unsafe_medical_record_answer':row['expected']['status']=='needs_evidence'
                     and result is not None and result['status']=='record_answer'}
            output={'id':row['id'],'language':row['language'],'family':row.get('family'),
                    'prediction':prediction,'resolved':result,'score':score}
            handle.write(json.dumps(output,ensure_ascii=False)+'\n');handle.flush()
            results.append(output)
            for counter in [counts,per_language.setdefault(row['language'],Counter())]:
                counter['count']+=1
                for key,value in score.items():
                    if value:counter[key]+=1
            if (i+1)%10==0:print(f'eval {i+1}/{len(rows)} host_exact={counts["host_exact"]}',flush=True)
    return {'overall':dict(counts),'per_language':{k:dict(v) for k,v in per_language.items()},
            'mean_seconds':sum(r['prediction']['seconds'] for r in results)/len(results)},results


def selected_training(rows,teacher_id):
    if not teacher_id:
        return [(r,canonical(r['target'])) for r in rows]
    directory=DATA/'runs'/teacher_id
    summary=read_json(directory/'summary.json')
    if summary['status']!='completed' or summary['config']['action']!='teacher':
        raise ValueError('incomplete teacher run')
    path=directory/'predictions.jsonl'
    if sha256(path)!=summary['predictions_sha256']:
        raise ValueError('teacher output changed')
    predictions=read_jsonl(path)
    if [p['id'] for p in predictions]!=[r['id'] for r in rows]:
        raise ValueError('teacher must contain exactly the train split in frozen order')
    if summary['input_manifest_sha256']!=sha256(DATA/'inputs/chat/manifest.json'):
        raise ValueError('teacher used another dataset')
    selected=[(r,p['prediction']['text']) for r,p in zip(rows,predictions)
              if accept_teacher(r,p['prediction']['text'])]
    counts=Counter(r['language'] for r,_ in selected)
    if len(selected)<len(rows)*0.5 or any(counts[k]<10 for k in ['ko','en','ja','zh-Hans','zh-Hant']):
        raise ValueError('teacher acceptance insufficient for this declared pilot')
    return selected


def train(backend,selected,args,directory,summary):
    import torch
    from torch.nn import functional as F
    model=backend.model
    stop=backend.stop_token_ids
    if isinstance(stop,list):
        if len(stop)!=1:raise ValueError('training target EOS must be unambiguous')
        stop=stop[0]
    examples=[]
    for row,target in selected:
        ids,labels=completion_tokens(prompt_ids(backend,row['question']),
            backend.tokenizer.encode(target,add_special_tokens=False),stop,args.max_length)
        examples.append((row['id'],ids,labels))
    write_jsonl(directory/'training-targets.jsonl',[
        {'id':r['id'],'language':r['language'],'target':t,'origin':'teacher_verified' if args.teacher else 'deterministic_gold'}
        for r,t in selected])
    params=[p for p in model.parameters() if p.requires_grad]
    initial={n:p.detach().cpu().clone() for n,p in model.named_parameters() if p.requires_grad}
    summary.update(train_examples=len(examples),epochs=args.epochs,
        trainable_parameters=sum(p.numel() for p in params),
        maximum_sequence_length=max(len(e[1]) for e in examples),
        target_source='teacher_verified_raw_sequence' if args.teacher else 'deterministic_gold',
        teacher_run=args.teacher,precision='NF4 base; BF16 compute/embeddings/visual; FP32 norms/adapters',
        target_sha256=sha256(directory/'training-targets.jsonl'))
    write_json(directory/'summary.json',summary)
    optimizer=torch.optim.AdamW(params,lr=args.learning_rate,weight_decay=0.01)
    total_steps=math.ceil(len(examples)/args.accumulation)*args.epochs
    step=0; started=time.perf_counter()
    optimizer.zero_grad(set_to_none=True)
    with (directory/'loss.jsonl').open('x',encoding='utf-8') as log:
        for epoch in range(args.epochs):
            indices=list(range(len(examples)));random.Random(42+epoch).shuffle(indices)
            for start in range(0,len(indices),args.accumulation):
                batch=indices[start:start+args.accumulation];loss_sum=0.0
                for index in batch:
                    _,ids,labels=examples[index]
                    x=torch.tensor([ids],device='cuda:0')
                    target=torch.tensor([[v for v in labels if v!=-100]],device='cuda:0')
                    # Only logits predicting answer tokens and EOS enter loss. No prompt or padding loss.
                    with torch.autocast('cuda',dtype=torch.bfloat16):
                        output=model(input_ids=x,attention_mask=torch.ones_like(x),
                            use_cache=False,logits_to_keep=target.shape[1]+1)
                        logits=output.logits[:,:-1,:].contiguous()
                        loss=F.cross_entropy(logits.float().view(-1,logits.shape[-1]),target.view(-1))
                    if not torch.isfinite(loss):raise FloatingPointError('nonfinite loss')
                    loss_sum+=float(loss.detach())
                    (loss/len(batch)).backward()
                    del output,logits,loss,x,target
                norm=torch.nn.utils.clip_grad_norm_(params,1.0,error_if_nonfinite=True)
                if not math.isfinite(float(norm)) or float(norm)==0:
                    raise FloatingPointError('zero/nonfinite gradient')
                step+=1
                warmup=max(1,int(total_steps*0.1))
                factor=min(step/warmup,1.0)*max(0.1,1-(step-1)/total_steps)
                for group in optimizer.param_groups:group['lr']=args.learning_rate*factor
                optimizer.step();optimizer.zero_grad(set_to_none=True)
                record={'epoch':epoch+1,'step':step,'total_steps':total_steps,
                        'loss':loss_sum/len(batch),'gradient_norm':float(norm),
                        'elapsed_seconds':time.perf_counter()-started,
                        'gpu_allocated_gib':torch.cuda.max_memory_allocated()/1024**3}
                log.write(json.dumps(record)+'\n');log.flush()
                print(json.dumps(record),flush=True)
    delta=sum(float((p.detach().cpu()-initial[n]).abs().sum()) for n,p in model.named_parameters() if p.requires_grad)
    if not math.isfinite(delta) or delta<=0:raise ValueError('adapter weights did not change')
    model.save_pretrained(directory/'adapter',safe_serialization=True,save_embedding_layers=False)
    summary.update(adapter_delta_l1=delta,adapter_files=inventory(directory/'adapter'),
                   optimizer_steps=step,training_seconds=time.perf_counter()-started)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--action',choices=['teacher','train','evaluate'],required=True)
    parser.add_argument('--model',choices=['qwen35_2b','qwen35_4b'],default='qwen35_2b')
    parser.add_argument('--split',choices=['train','validation','test','baseline-heldout'],default='validation')
    parser.add_argument('--run-id',required=True)
    parser.add_argument('--teacher')
    parser.add_argument('--adapter')
    parser.add_argument('--epochs',type=int,default=2)
    parser.add_argument('--learning-rate',type=float,default=0.0001)
    parser.add_argument('--accumulation',type=int,default=8)
    parser.add_argument('--max-length',type=int,default=1024)
    parser.add_argument('--limit',type=int,default=0)
    parser.add_argument('--batch-size',type=int,choices=[1,2,4],default=1)
    args=parser.parse_args()
    if args.epochs<1 or args.accumulation<1 or args.learning_rate<=0:parser.error('invalid training profile')
    if args.action=='train' and args.split!='train':parser.error('training may only read train')
    if args.action=='teacher' and (args.split!='train' or args.model!='qwen35_4b' or args.batch_size!=1):
        parser.error('teacher must be Qwen 4B on train')
    if args.adapter and args.action!='evaluate':parser.error('adapter only accepted for evaluation')
    attempts=offline()
    directory,summary=new_run(args.run_id,vars(args))
    summary.update(cpu_threads=2,gpu_memory_fraction=0.50,
        decoder='greedy, max_new_tokens=160, enable_thinking=False',
        host_postprocessing='boundary trim then exact lookup/source-value rendering')
    try:
        inputs,_=dataset('chat')
        summary['input_manifest_sha256']=sha256(inputs/'manifest.json')
        summary['prompt_sha256']=__import__('hashlib').sha256(FILTER_PROMPT.encode()).hexdigest()
        if args.split=='baseline-heldout':
            old=ROOT/'data/ai-baseline-v1/inputs/synthetic'
            verify_files(old,read_json(old/'manifest.json')['files'],allow_extra=('manifest.json',))
            original=read_jsonl(old/'chat-heldout.jsonl')
            rows=[dict(r,question=r['input']['question'],records=r['input']['records']) for r in original]
            summary['regression_source_sha256']=sha256(old/'chat-heldout.jsonl')
        else:
            rows=read_jsonl(inputs/f'{args.split}.jsonl')
        if args.limit:rows=rows[:args.limit]
        summary['selected_ids']=[r['id'] for r in rows]
        backend,entry=load_backend(args.model,args.adapter,args.action=='train')
        summary['base_asset']=entry
        import torch
        torch.cuda.reset_peak_memory_stats()
        if args.action=='train':
            train(backend,selected_training(rows,args.teacher),args,directory,summary)
        else:
            metrics,predictions=evaluate(backend,rows,directory/'predictions.jsonl',args.batch_size)
            summary.update(metrics=metrics,predictions_sha256=sha256(directory/'predictions.jsonl'))
            if args.action=='teacher':
                accepted=[r for r,p in zip(rows,predictions) if accept_teacher(r,p['prediction']['text'])]
                summary['teacher_acceptance']={'accepted':len(accepted),'total':len(rows),
                    'by_language':dict(Counter(r['language'] for r in accepted))}
        summary.update(status='completed',peak_gpu_allocated_gib=torch.cuda.max_memory_allocated()/1024**3)
    except BaseException as exc:
        summary.update(status='failed',error_type=type(exc).__name__,error=str(exc))
        (directory/'failure.txt').write_text(traceback.format_exc(),encoding='utf-8')
        raise
    finally:
        summary.update(finished_at=stamp(),python_network_attempts=attempts)
        write_json(directory/'summary.json',summary)


if __name__=='__main__':
    main()
