"""Download official CPU conversion tools and pinned Silero ONNX, with hashes."""
from pathlib import Path
import zipfile
import requests
from scripts.ai_training_common import ROOT, sha256, write_json

def main():
    root = ROOT/'data/mobile-ai/sources'
    records=[]
    urls = {
      'llama-b10903-bin-win-cpu-x64.zip': 'https://github.com/ggml-org/llama.cpp/releases/download/b10903/llama-b10903-bin-win-cpu-x64.zip',
      'silero-v6.2.onnx': 'https://raw.githubusercontent.com/snakers4/silero-vad/be95df9152c0d7618fa1edfeb296fc3dae32376f/src/silero_vad/data/silero_vad.onnx',
    }
    for name,url in urls.items():
        path=root/name
        if not path.exists():
            with requests.get(url,stream=True,timeout=90) as response:
                response.raise_for_status()
                with path.open('xb') as file:
                    for block in response.iter_content(1024*1024): file.write(block)
        records.append(dict(path=str(path),url=url,bytes=path.stat().st_size,sha256=sha256(path)))
    target=root/'llama-windows-b10903'
    target.mkdir(exist_ok=True)
    with zipfile.ZipFile(root/'llama-b10903-bin-win-cpu-x64.zip') as archive:
        for member in archive.infolist():
            path=(target/member.filename).resolve()
            if not path.is_relative_to(target.resolve()): raise ValueError('unsafe archive path')
        archive.extractall(target)
    write_json(ROOT/'experiments/mobile_ai_v1/native-sources.lock.json',records)
    print('Native CPU tools and VAD downloaded')

if __name__=='__main__': main()
