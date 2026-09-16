"""Download pinned public conversion sources, separately from offline model export."""
import io
from pathlib import Path
import zipfile
import requests

from scripts.ai_training_common import ROOT, inventory, stamp, write_json


def download(url,limit):
    with requests.get(url,stream=True,timeout=60) as response:
        response.raise_for_status(); result=bytearray()
        for chunk in response.iter_content(65536):
            result.extend(chunk)
            if len(result)>limit: raise ValueError('source size limit')
    return bytes(result)


def main():
    root=ROOT/'data/mobile-ai/sources'; root.mkdir(parents=True,exist_ok=True)
    revision='afeebe103bd99cda8f5dfaefcabadf890db7fda7'
    target=root/'llama.cpp'; target.mkdir(exist_ok=False)
    archive=zipfile.ZipFile(io.BytesIO(download(f'https://codeload.github.com/ggml-org/llama.cpp/zip/{revision}',150_000_000)))
    for entry in archive.infolist():
        relative=Path(*Path(entry.filename).parts[1:])
        path=(target/relative).resolve()
        if not path.is_relative_to(target.resolve()): raise ValueError('source path escape')
        if entry.is_dir(): path.mkdir(parents=True,exist_ok=True)
        else:
            path.parent.mkdir(parents=True,exist_ok=True); path.write_bytes(archive.read(entry))
    tag=requests.get('https://api.github.com/repos/k2-fsa/sherpa-onnx/git/ref/tags/v1.13.8',timeout=30)
    tag.raise_for_status(); obj=tag.json()['object']
    if obj['type']=='tag':
        response=requests.get(obj['url'],timeout=30); response.raise_for_status(); obj=response.json()['object']
    sherpa_revision=obj['sha']
    sherpa=root/'sherpa-export'; sherpa.mkdir(exist_ok=False)
    tree=requests.get(f'https://api.github.com/repos/k2-fsa/sherpa-onnx/git/trees/{sherpa_revision}?recursive=1',timeout=60)
    tree.raise_for_status()
    names=[r['path'] for r in tree.json()['tree'] if r['type']=='blob' and
           (r['path'].startswith('scripts/whisper/') or r['path']=='LICENSE')]
    for name in names:
        path=sherpa/name; path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(download(f'https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/{sherpa_revision}/{name}',5_000_000))
    write_json(ROOT/'experiments/mobile_ai_v1/sources.lock.json',dict(created_at=stamp(),
        llama=dict(revision=revision,path=str(target),files=inventory(target)),
        sherpa=dict(revision=sherpa_revision,path=str(sherpa),files=inventory(sherpa))))
    print('Pinned llama.cpp and sherpa Whisper conversion sources downloaded.',flush=True)


if __name__=='__main__': main()
