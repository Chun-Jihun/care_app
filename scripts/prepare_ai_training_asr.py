"""Prepare small public train/validation/test subsets with sentence-group exclusion."""
import hashlib
import io
import unicodedata

from scripts.ai_training_common import DATA, ROOT, EXPERIMENT, read_json, read_jsonl, seal_inputs, verify_files, write_jsonl

CONFIGS=[('ko_kr','ko'),('en_us','en'),('ja_jp','ja'),('cmn_hans_cn','zh-Hans')]


def normalized(text):
    return ''.join(unicodedata.normalize('NFC',text).lower().split())


def main():
    import numpy as np
    import pyarrow.parquet as pq
    import soundfile as sf
    train_lock=read_json(EXPERIMENT/'asr-assets.lock.json')
    from pathlib import Path
    train_source=Path(train_lock['directory'])
    verify_files(train_source,train_lock['files'])
    old_lock=read_json(ROOT/'experiments/ai_baseline_v1/assets.lock.json')['datasets']['fleurs']
    validation_source=ROOT/old_lock['local_path']
    verify_files(validation_source,old_lock['files'])
    old_rows=read_jsonl(ROOT/'data/ai-baseline-v1/inputs/asr/asr-public_validation.jsonl')
    used_ids={(r['language'],r['source_id']) for r in old_rows if 'source_id' in r}
    metadata={};all_validation_ids=set();all_validation_text=set()
    for config,language in CONFIGS:
        paths=sorted((validation_source/config/'validation').glob('*.parquet'))
        meta=[r for p in paths for r in pq.read_table(p,columns=['id','transcription']).to_pylist()]
        metadata[config]=meta
        all_validation_ids.update(str(r['id']) for r in meta)
        all_validation_text.update(normalized(r['transcription']) for r in meta)
    directory=DATA/'inputs/asr';directory.mkdir(parents=True,exist_ok=False)
    splits={s:[] for s in ['train','validation','test']}
    used_hashes={};used_groups={};used_texts={}

    def save(record,config,language,split):
        samples,sr=sf.read(io.BytesIO(record['audio']['bytes']),dtype='float32')
        if sr!=16000 or samples.ndim!=1 or len(samples)>30*sr:return False
        source_id=str(record['id']);group='sentence-'+source_id
        digest=hashlib.sha256(samples.tobytes()).hexdigest()
        reference=record['transcription'];ref=normalized(reference)
        for key,seen in [(digest,used_hashes),(group,used_groups),(ref,used_texts)]:
            if key in seen and seen[key]!=split:raise ValueError('cross-split audio/sentence/text overlap')
            seen[key]=split
        number=sum(r['language']==language for r in splits[split])
        relative=f'audio/{split}/{config}-{number:03}.wav'
        path=directory/relative;path.parent.mkdir(parents=True,exist_ok=True)
        sf.write(path,samples,sr,subtype='PCM_16')
        splits[split].append({'id':f'FT-ASR-{split}-{config}-{number:03}','split':split,
            'language':language,'group_id':group,'source_id':source_id,'path':relative,
            'reference':reference,'duration_seconds':len(samples)/sr,
            'source_split':'train' if split=='train' else 'validation',
            'reference_origin':'FLEURS_public_transcription','evaluation_eligible':False})
        return True

    for config,language in CONFIGS:
        selected={s:set() for s in ['train','validation','test']}
        for path in sorted((validation_source/config/'validation').glob('*.parquet')):
            for batch in pq.ParquetFile(path).iter_batches(batch_size=16):
                for record in batch.to_pylist():
                    source_id=str(record['id'])
                    if (language,source_id) in used_ids:continue
                    split='validation' if int(hashlib.sha256(source_id.encode()).hexdigest()[:8],16)%2==0 else 'test'
                    cap=20 if split=='validation' else 30
                    if source_id in selected[split] or len(selected[split])>=cap:continue
                    if save(record,config,language,split):selected[split].add(source_id)
        for path in sorted((train_source/config/'train').glob('*.parquet')):
            for batch in pq.ParquetFile(path).iter_batches(batch_size=16):
                for record in batch.to_pylist():
                    source_id=str(record['id'])
                    if (source_id in all_validation_ids or source_id in selected['train']
                        or normalized(record['transcription']) in all_validation_text):continue
                    if save(record,config,language,'train'):selected['train'].add(source_id)
                    if len(selected['train'])>=100:break
                if len(selected['train'])>=100:break
        if {s:len(v) for s,v in selected.items()}!={'train':100,'validation':20,'test':30}:
            raise ValueError(f'insufficient disjoint public rows: {config}')
        print(config,'prepared train100 validation20 test30',flush=True)
    # Silence is a labeled synthetic control, never represented as new independent speech.
    # Training and test durations differ; silence has no speaker/sentence provenance.
    for split,durations in [('train',[2,4,8]),('test',[1,3,10])]:
        for config,language in CONFIGS:
            for seconds in durations:
                relative=f'audio/{split}/silence-{language}-{seconds}.wav'
                sf.write(directory/relative,np.zeros(seconds*16000,dtype='float32'),16000,subtype='PCM_16')
                splits[split].append({'id':f'FT-ASR-{split}-silence-{language}-{seconds}',
                    'split':split,'language':language,'group_id':f'synthetic-silence-{seconds}',
                    'path':relative,'reference':'','duration_seconds':seconds,
                    'reference_origin':'synthetic_silence_control','evaluation_eligible':False})
    for split,rows in splits.items():write_jsonl(directory/f'{split}.jsonl',rows)
    seal_inputs(directory,{'task':'asr','repository':'google/fleurs','revision':train_lock['revision'],
        'counts':{s:len(v) for s,v in splits.items()},'license':'CC-BY-4.0',
        'attribution':'Google FLEURS, https://huggingface.co/datasets/google/fleurs',
        'split_rule':'train excludes all source-validation sentence IDs and normalized transcripts; local validation/test sentence IDs partitioned by SHA parity; within each language prior 50 evaluated sentence IDs excluded',
        'prior_exposure_limit':'a new evaluation sentence may have a parallel translation previously evaluated in another language; these are new recordings, not guaranteed unseen semantic content',
        'speaker_limit':'source train speakers differ from validation; speaker separation between local validation/test cannot be verified from available metadata',
        'controls':'12 synthetic silence training and 12 test controls; not independent speech or silence generalization evidence',
        'medical_scope':'general read speech, not medical terminology or clinic dialogue'})
    print('ASR inputs frozen',flush=True)


if __name__=='__main__':main()
