"""CPU-only supervised adaptation of PP-OCRv5 CTC recognition head."""
from __future__ import annotations
import argparse
import json
import math
import os
from pathlib import Path
import random
import sys
import time
import traceback

from scripts.ai_training_common import (DATA,EXPERIMENT,dataset,inventory,new_run,offline,
    read_json,read_jsonl,sha256,stamp,verify_files,write_json)
from scripts.ai_baseline_metrics import transcript_score, strict_critical_tokens


def decode_ctc(indices,characters):
    result=[];previous=None
    for index in indices:
        index=int(index)
        if index and index!=previous:result.append(characters[index])
        previous=index
    return ''.join(result)


def image_array(path):
    import cv2
    import numpy as np
    image=cv2.imread(str(path))
    if image is None:raise ValueError('unreadable OCR image')
    height,width=image.shape[:2]
    target_width=min(320,math.ceil(48*width/height))
    resized=cv2.resize(image,(target_width,48)).astype('float32').transpose(2,0,1)/255.0
    padded=np.zeros((3,48,320),dtype='float32')
    padded[:,:,:target_width]=(resized-0.5)/0.5
    return padded


def scores(predictions):
    groups={'all':predictions}
    groups.update({lang:[r for r in predictions if r['language']==lang]
                   for lang in sorted({r['language'] for r in predictions})})
    output={}
    for key,rows in groups.items():
        characters=sum(r['score']['reference_characters'] for r in rows)
        output[key]={'count':len(rows),'cer':sum(r['score']['character_edits'] for r in rows)/characters,
            'exact':sum(r['text']==r['reference'] for r in rows),
            'strict_numeric_unit_match':sum(r['strict_numeric_unit_match'] for r in rows)}
    return output


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--model',choices=['ko','multi'],required=True)
    parser.add_argument('--run-id',required=True);parser.add_argument('--epochs',type=int,default=3)
    args=parser.parse_args()
    if args.epochs<1:parser.error('epochs must be positive')
    os.environ['OMP_NUM_THREADS']='2';os.environ['MKL_NUM_THREADS']='2'
    attempts=offline();directory,summary=new_run(args.run_id,vars(args))
    try:
        import numpy as np
        import paddle
        import yaml
        paddle.set_device('cpu');paddle.seed(42)
        source=read_json(EXPERIMENT/'ocr-assets.lock.json')
        asset_root=Path(source['directory'])
        bytecode=tuple(p.relative_to(asset_root).as_posix() for p in asset_root.rglob('*.pyc')
                       if '__pycache__' in p.relative_to(asset_root).parts)
        verify_files(asset_root,source['files'],allow_extra=bytecode)
        sys.dont_write_bytecode=True
        code=Path(source['source']['directory']);sys.path.insert(0,str(code))
        from ppocr.modeling.architectures import build_model
        from ppocr.losses.rec_ctc_loss import CTCLoss
        name='korean_PP-OCRv5_mobile_rec' if args.model=='ko' else 'PP-OCRv5_mobile_rec'
        relative='multi_language/'+name+'.yml' if args.model=='ko' else name+'.yml'
        config=yaml.safe_load((code/'configs/rec/PP-OCRv5'/relative).read_text(encoding='utf-8'))
        dictionary=code/config['Global']['character_dict_path']
        characters=['blank']+dictionary.read_text(encoding='utf-8').splitlines()+[' ']
        if len(set(characters))!=len(characters):raise ValueError('ambiguous recognition alphabet')
        alphabet={c:i for i,c in enumerate(characters)}
        config['Architecture']['Head']['out_channels_list']={
            'CTCLabelDecode':len(characters),'NRTRLabelDecode':len(characters)+3}
        model=build_model(config['Architecture'])
        base=Path(source['directory'])/(name+'_pretrained.pdparams')
        state=paddle.load(str(base))
        if set(state)!=set(model.state_dict()):
            raise ValueError('pretrained parameter names do not match official architecture')
        if any(list(state[k].shape)!=list(v.shape) for k,v in model.state_dict().items()):
            raise ValueError('pretrained parameter shapes do not match dictionary/config')
        model.set_state_dict(state);model.eval()
        for parameter in model.parameters():parameter.stop_gradient=True
        head=model.head.ctc_head
        for parameter in head.parameters():parameter.stop_gradient=False
        inputs,manifest=dataset('ocr')
        allowed={'ko','en'} if args.model=='ko' else {'en','ja','zh-Hans','zh-Hant'}
        rows={split:[r for r in read_jsonl(inputs/f'{split}.jsonl') if r['language'] in allowed]
              for split in ['train','validation','test']}
        for split in rows:
            for row in rows[split]:
                if any(char not in alphabet for char in row['reference']):
                    raise ValueError('reference includes characters outside model vocabulary')
        summary.update(model=name,base_sha256=sha256(base),dictionary_sha256=sha256(dictionary),
            input_manifest_sha256=sha256(inputs/'manifest.json'),train_examples=len(rows['train']),
            trainable_parameters=sum(np.prod(p.shape) for p in head.parameters()),
            scope='CTC final classification head only; frozen backbone and CTC encoder',
            cpu_threads=2,learning_rate=0.0001,batch_size=8,epochs=args.epochs,
            transcript_metric_version='reference-first-v2')
        summary['trainable_parameters']=int(summary['trainable_parameters'])
        write_json(directory/'summary.json',summary)
        features={}
        for split in ['train','validation','test']:
            for i,row in enumerate(rows[split]):
                with paddle.no_grad():
                    image=paddle.to_tensor(image_array(inputs/row['path'])[None,:,:,:])
                    features[row['id']]=model.head.ctc_encoder(model.backbone(image)).detach()
                if (i+1)%40==0:print(f'{split} features {i+1}/{len(rows[split])}',flush=True)

        def evaluate(split,label):
            predictions=[];head.eval()
            for row in rows[split]:
                with paddle.no_grad():indices=head(features[row['id']]).argmax(axis=-1).numpy()[0]
                text=decode_ctc(indices,characters)
                predictions.append({'id':row['id'],'language':row['language'],'reference':row['reference'],
                    'text':text,'score':transcript_score(reference=row['reference'],prediction=text),
                    'strict_numeric_unit_match':strict_critical_tokens(text)==strict_critical_tokens(row['reference'])})
            from scripts.ai_training_common import write_jsonl
            write_jsonl(directory/f'{label}.jsonl',predictions)
            result=scores(predictions);print(label,json.dumps(result),flush=True)
            return result

        summary['baseline_validation']=evaluate('validation','baseline-validation')
        # Test is scored only for fixed before/after comparison, never for optimization/selection.
        # Fixed epochs and LR were declared before opening any OCR test predictions.
        summary['baseline_test']=evaluate('test','baseline-test')
        initial={k:v.numpy().copy() for k,v in head.state_dict().items()}
        optimizer=paddle.optimizer.Adam(learning_rate=0.0001,parameters=head.parameters(),
                                        grad_clip=paddle.nn.ClipGradByGlobalNorm(1.0))
        criterion=CTCLoss();started=time.perf_counter();step=0
        with (directory/'loss.jsonl').open('x',encoding='utf-8') as log:
            for epoch in range(args.epochs):
                head.train();order=list(rows['train']);random.Random(42+epoch).shuffle(order)
                for offset in range(0,len(order),8):
                    batch=order[offset:offset+8]
                    encoded=[[alphabet[c] for c in r['reference']] for r in batch]
                    labels=np.zeros((len(batch),max(map(len,encoded))),dtype='int32')
                    for i,target in enumerate(encoded):labels[i,:len(target)]=target
                    x=paddle.concat([features[r['id']] for r in batch],axis=0)
                    prediction=head(x)
                    loss=criterion(prediction,[None,paddle.to_tensor(labels),
                        paddle.to_tensor([len(t) for t in encoded],dtype='int64')])['loss']
                    value=float(loss)
                    if not math.isfinite(value):raise FloatingPointError('nonfinite CTC loss')
                    loss.backward()
                    grad=sum(float(paddle.sum(paddle.abs(p.grad))) for p in head.parameters() if p.grad is not None)
                    if not math.isfinite(grad) or grad<=0:raise FloatingPointError('invalid CTC gradient')
                    optimizer.step();optimizer.clear_grad();step+=1
                    item={'epoch':epoch+1,'step':step,'loss':value,'gradient_l1':grad,
                          'elapsed_seconds':time.perf_counter()-started}
                    log.write(json.dumps(item)+'\n');log.flush()
                    if step%5==0:print(json.dumps(item),flush=True)
        delta=sum(float(np.abs(v.numpy()-initial[k]).sum()) for k,v in head.state_dict().items())
        if not math.isfinite(delta) or delta<=0:raise ValueError('recognition head did not change')
        checkpoint=directory/'ctc-head.pdparams';paddle.save(head.state_dict(),str(checkpoint))
        # Reload the persisted artifact before all after-training measurements.
        head.set_state_dict(paddle.load(str(checkpoint)))
        summary.update(head_delta_l1=delta,checkpoint_sha256=sha256(checkpoint),
            training_seconds=time.perf_counter()-started,optimizer_steps=step,
            trained_validation=evaluate('validation','trained-validation'),
            trained_test=evaluate('test','trained-test'),status='completed')
    except BaseException as exc:
        summary.update(status='failed',error_type=type(exc).__name__,error=str(exc))
        (directory/'failure.txt').write_text(traceback.format_exc(),encoding='utf-8');raise
    finally:
        summary.update(finished_at=stamp(),python_network_attempts=attempts)
        write_json(directory/'summary.json',summary)


if __name__=='__main__':main()
