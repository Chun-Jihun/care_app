"""Seal a streamable local model pack and the app's trusted manifest.

No arbitrary model URL, path, Python code or model repository is consumed by the app.
"""
import json
import hashlib
import struct
from scripts.ai_training_common import ROOT, read_json, sha256
from scripts.artifact_publication import staged_release

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
    pack=ROOT/'data/mobile-ai/care-ai-dev-2026-09-11-v2.careai'
    lock=ROOT/'experiments/mobile_ai_v1/model-pack.lock.json'
    # Publish the complete pack and lock before activating the trusted manifest.
    with staged_release([pack,lock,asset],replace=[lock,asset]) as staged:
        with staged[pack].open('wb') as output:
            output.write(b'CAREAI01'+struct.pack('<I',len(data))+data)
            for path,expected in zip(files.values(),manifest['files']):
                digest=hashlib.sha256()
                copied=0
                with path.open('rb') as source:
                    while block:=source.read(1024*1024):
                        output.write(block)
                        digest.update(block)
                        copied+=len(block)
                if copied!=expected['bytes'] or digest.hexdigest()!=expected['sha256']:
                    raise ValueError('source changed during packaging')
        staged[asset].write_bytes(data)
        value=dict(manifest=manifest,
            pack=dict(path=str(pack.relative_to(ROOT)),bytes=staged[pack].stat().st_size,sha256=sha256(staged[pack])),
            manifest_sha256=hashlib.sha256(data).hexdigest())
        staged[lock].write_bytes((json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode('utf-8'))
    print(pack,pack.stat().st_size,flush=True)

if __name__=='__main__':main()
