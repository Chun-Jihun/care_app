"""Seal a streamable local model pack and the app's trusted manifest.

No arbitrary model URL, path, Python code or model repository is consumed by the app.
"""
import json
import shutil
import struct
from scripts.ai_training_common import ROOT, read_json, sha256, write_json

def main():
    exports=ROOT/'data/mobile-ai/exports'
    for name in ['chat','asr','ocr-ko-v9','ocr-multi-v1','ocr-det']:
        if read_json(exports/name/'summary.json')['status'] != 'completed':
            raise ValueError('incomplete export: '+name)
    files={
        'chat/model.gguf':exports/'chat/chat-q4km-text.gguf',
        'chat/prompt.json':exports/'chat/prompt.json',
        'ocr/detector.onnx':exports/'ocr-det/detector.onnx',
        'ocr/ko.onnx':exports/'ocr-ko-v9/recognizer.onnx',
        'ocr/ko.json':exports/'ocr-ko-v9/characters.json',
        'ocr/multi.onnx':exports/'ocr-multi-v1/recognizer.onnx',
        'ocr/multi.json':exports/'ocr-multi-v1/characters.json',
        'speech/encoder.onnx':exports/'asr/small-encoder.int8.onnx',
        'speech/decoder.onnx':exports/'asr/small-decoder.int8.onnx',
        'speech/tokens.txt':exports/'asr/small-tokens.txt',
        'speech/vad.onnx':ROOT/'data/mobile-ai/sources/silero-v6.2.onnx',
    }
    manifest=dict(format=1,version='care-ai-dev-2026-09-11-v2',medical_release_gate_result=False,
        models={'chat':'Qwen3.5-2B SFT BF16 merge + Q4_K_M','ocr':'PP-OCRv5 trained CTC heads',
                'speech':'Whisper small LoRA merge + INT8','vad':'Silero v6.2'},
        files=[dict(path=name,bytes=path.stat().st_size,sha256=sha256(path)) for name,path in files.items()])
    data=(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode('utf-8')
    asset=ROOT/'mobile/assets/ai/manifest.json'
    asset.parent.mkdir(parents=True,exist_ok=True)
    pack=ROOT/'data/mobile-ai/care-ai-dev-2026-09-11-v2.careai'
    if pack.exists(): raise FileExistsError(pack)
    with pack.open('xb') as output:
        output.write(b'CAREAI01'+struct.pack('<I',len(data))+data)
        for path in files.values():
            with path.open('rb') as source: shutil.copyfileobj(source,output,1024*1024)
    asset.write_bytes(data)
    write_json(ROOT/'experiments/mobile_ai_v1/model-pack.lock.json',dict(manifest=manifest,
        pack=dict(path=str(pack.relative_to(ROOT)),bytes=pack.stat().st_size,sha256=sha256(pack)),
        manifest_sha256=sha256(asset)))
    print(pack,pack.stat().st_size,flush=True)

if __name__=='__main__':main()
