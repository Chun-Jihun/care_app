"""Prepare verified Whisper features on CPU, independently of GPU training."""
from __future__ import annotations
import hashlib
from pathlib import Path
import tempfile

from scripts.ai_training_common import (DATA,dataset,model_asset,offline,read_json,read_jsonl,
    seal_inputs,sha256,write_json)


def decoder_supervision(tokens,prefix_length=4):
    if len(tokens)<prefix_length+1:raise ValueError('missing transcription EOS')
    inputs=list(tokens[:-1]);labels=list(tokens[1:])
    labels[:prefix_length-1]=[-100]*(prefix_length-1)
    return inputs,labels


def load_features(rows):
    from safetensors.torch import load_file
    inputs,_=dataset('asr')
    cache,manifest=dataset('asr-features')
    if manifest['asr_input_manifest_sha256']!=sha256(inputs/'manifest.json'):
        raise ValueError('feature cache belongs to different audio inputs')
    tensors=load_file(cache/'features.safetensors',device='cpu')
    targets=read_json(cache/'targets.json')
    expected={r['id'] for split in rows.values() for r in split}
    if set(tensors)!={prefix+key for key in expected for prefix in ['features.','mask.']}:
        raise ValueError('feature IDs do not match audio corpus')
    if set(targets)!={r['id'] for r in rows['train']}:
        raise ValueError('only train rows may have teacher-forced targets')
    return ({key:tensors['features.'+key] for key in expected},
            {key:tensors['mask.'+key] for key in expected},targets,manifest)


def main():
    attempts=offline()
    import numpy as np
    import soundfile as sf
    import torch
    from safetensors.torch import save_file
    from transformers import AutoProcessor
    torch.set_num_threads(2)
    inputs,_=dataset('asr');base,asset=model_asset('whisper_small')
    processor=AutoProcessor.from_pretrained(base,local_files_only=True,trust_remote_code=False)
    destination=DATA/'inputs/asr-features'
    if destination.exists():raise ValueError('feature cache already sealed')
    directory=Path(tempfile.mkdtemp(prefix='asr-features-preparing-',dir=destination.parent))
    rows={split:read_jsonl(inputs/f'{split}.jsonl') for split in ['train','validation','test']}
    tensors={};targets={};origins={};overlaps=[]
    for split in rows:
        for i,row in enumerate(rows[split]):
            samples,sr=sf.read(inputs/row['path'],dtype='float32')
            if (sr!=16000 or samples.ndim!=1 or not 0<len(samples)<=480000
                or not np.isfinite(samples).all()):raise ValueError('invalid audio fixture')
            extracted=processor.feature_extractor(samples,sampling_rate=sr,
                return_tensors='pt',return_attention_mask=True)
            features=extracted.input_features.contiguous()
            if not torch.isfinite(features).all():raise ValueError('nonfinite audio features')
            tensors['features.'+row['id']]=features
            tensors['mask.'+row['id']]=extracted.attention_mask.contiguous()
            signature=hashlib.sha256(features.numpy().tobytes()).hexdigest()
            for prior in origins.get(signature,[]):
                if prior['split']!=split:
                    if prior['reference'] or row['reference']:
                        raise ValueError('speech feature overlap across splits')
                    overlaps.append({'prior_id':prior['id'],'id':row['id'],'feature_sha256':signature})
            origins.setdefault(signature,[]).append(row)
            if split=='train':
                lang='zh' if row['language'].startswith('zh') else row['language']
                processor.tokenizer.set_prefix_tokens(language=lang,task='transcribe',predict_timestamps=False)
                ids=processor.tokenizer(row['reference']).input_ids
                if len(ids)>448:raise ValueError('transcription exceeds decoder capacity')
                targets[row['id']]=decoder_supervision(ids)
            if (i+1)%50==0:print(f'{split} features {i+1}/{len(rows[split])}',flush=True)
    save_file(tensors,str(directory/'features.safetensors'))
    write_json(directory/'targets.json',targets)
    seal_inputs(directory,{'task':'Whisper_small_features','asr_input_manifest_sha256':sha256(inputs/'manifest.json'),
        'base_asset':asset,'generator_sha256':sha256(Path(__file__)),
        'feature_dtype':'float32','padding':'30 seconds with explicit attention mask',
        'silence_feature_overlap':overlaps,'python_network_attempts':attempts,
        'counts':{split:len(value) for split,value in rows.items()}})
    if not all(p.resolve().is_relative_to(DATA.resolve()) for p in [directory,destination]):
        raise ValueError('feature preparation path escaped task root')
    directory.rename(destination)
    print('Sealed CPU feature cache; silence feature overlaps:',len(overlaps),flush=True)


if __name__=='__main__':main()
