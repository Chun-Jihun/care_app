"""Bounded public downloads; no inference/training and no private inputs."""
import argparse
from pathlib import Path
import urllib.request
import zipfile

from scripts.ai_training_common import DATA, EXPERIMENT, inventory, read_json, sha256, write_json, stamp
from scripts.ai_baseline_common import configure_cache, inside

PADDLE_REV='2661c7c0ef5c613e8f93c6e93b2e052399f0f854'
FLEURS_REV='168de341b3db6859a9bac1c50a2ef5e3b47647e0'


def download(url,path,cap):
    if path.exists():
        raise ValueError('refuse to replace a downloaded file')
    path.parent.mkdir(parents=True,exist_ok=True)
    temporary=path.with_suffix(path.suffix+'.part')
    total=0
    with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'care-app-local-training'}),timeout=60) as source:
        with temporary.open('xb') as target:
            while block:=source.read(1024*1024):
                total+=len(block)
                if total>cap:raise ValueError('download cap exceeded')
                target.write(block)
    temporary.rename(path)
    return {'url':url,'bytes':total,'sha256':sha256(path),'downloaded_at':stamp()}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--task',choices=['ocr','asr'],required=True)
    args=parser.parse_args();configure_cache()
    lock_path=EXPERIMENT/f'{args.task}-assets.lock.json'
    if lock_path.exists():raise ValueError('asset lock already exists')
    lock={'task':args.task,'evaluation_eligible':False,'assets':[]}
    if args.task=='asr':
        from huggingface_hub import HfApi,hf_hub_download
        info=HfApi(token=False).dataset_info('google/fleurs',revision=FLEURS_REV,files_metadata=True)
        selected=[f for f in info.siblings if '/train/' in f.rfilename
            and f.rfilename.split('/')[0] in ['ko_kr','en_us','ja_jp','cmn_hans_cn'] and f.rfilename.endswith('.parquet')]
        if len(selected)!=4 or sum(f.size for f in selected)>8*1024**3:
            raise ValueError('unexpected public corpus size')
        directory=DATA/'sources/fleurs-train'
        for f in selected:
            path=hf_hub_download('google/fleurs',f.rfilename,repo_type='dataset',revision=info.sha,
                                 local_dir=directory,token=False)
            print('Downloaded',f.rfilename,flush=True)
        lock.update(repository='google/fleurs',revision=info.sha,source_split='train',
            license='CC-BY-4.0',license_source='https://huggingface.co/datasets/google/fleurs',
            directory=directory.as_posix(),files=inventory(directory))
    else:
        directory=DATA/'sources/paddleocr'
        for name in ['korean_PP-OCRv5_mobile_rec','PP-OCRv5_mobile_rec']:
            path=directory/(name+'_pretrained.pdparams')
            url=f'https://paddle-model-ecology.bj.bcebos.com/paddlex/official_pretrained_model/{name}_pretrained.pdparams'
            entry=download(url,path,256*1024**2);entry.update(name=name,path=path.as_posix())
            lock['assets'].append(entry);print('Downloaded',name,flush=True)
            write_json(lock_path.with_suffix('.pending.json'),lock)
        archive=directory/'source.zip'
        entry=download(f'https://codeload.github.com/PaddlePaddle/PaddleOCR/zip/{PADDLE_REV}',archive,512*1024**2)
        source=directory/'code';source.mkdir(exist_ok=False)
        prefix=f'PaddleOCR-{PADDLE_REV}/'
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.infolist():
                if member.is_dir() or not member.filename.startswith(prefix):continue
                relative=member.filename[len(prefix):]
                if not (relative.startswith(('ppocr/','configs/rec/PP-OCRv5/')) or relative in ['LICENSE','requirements.txt']):continue
                if ((member.external_attr>>16)&0o170000)==0o120000:raise ValueError('symlink forbidden')
                path=inside(source,relative);path.parent.mkdir(parents=True,exist_ok=True)
                path.write_bytes(bundle.read(member))
        lock['source']={**entry,'revision':PADDLE_REV,'directory':source.as_posix(),'files':inventory(source)}
        lock.update(license='Apache-2.0',license_evidence=(source/'LICENSE').as_posix(),
            directory=directory.as_posix(),files=inventory(directory))
    lock['completed_at']=stamp();write_json(lock_path,lock)
    print('Sealed',lock_path,flush=True)


if __name__=='__main__':main()
