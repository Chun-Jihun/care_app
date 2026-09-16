"""Repair only stale optional MTP metadata in the already-quantized candidate.

Transformers merged weights contain trunk layers 0..23, but the old config
advertised a discarded MTP layer. Tensor bytes must remain byte-for-byte equal.
"""
import hashlib
import shutil
import sys
from scripts.ai_training_common import ROOT, read_json, sha256, write_json

def tensor_hash(path, offset):
    digest=hashlib.sha256()
    with path.open('rb') as file:
        file.seek(offset)
        while chunk:=file.read(1024*1024): digest.update(chunk)
    return digest.hexdigest()

def main():
    sys.path.insert(0,str(ROOT/'data/mobile-ai/sources/llama.cpp/gguf-py'))
    from gguf import GGUFReader
    source=ROOT/'data/mobile-ai/exports/chat/chat-q4km.gguf'
    target=source.with_name('chat-q4km-text.gguf')
    expected='e867c7f15273c58ab3118f64c0943a111eaee575910b3e823e2b2bf9e2053425'
    if sha256(source)!=expected: raise ValueError('unsealed source')
    if target.exists(): raise FileExistsError(target)
    reader=GGUFReader(str(source))
    if set(int(t.name.split('.')[1]) for t in reader.tensors if t.name.startswith('blk.')) != set(range(24)):
        raise ValueError('unexpected layers')
    if any('nextn' in t.name for t in reader.tensors): raise ValueError('MTP tensor present')
    offset=reader.data_offset
    del reader
    shutil.copyfile(source,target)
    reader=GGUFReader(str(target),mode='r+')
    for key,old,new in [('qwen35.block_count',25,24),('qwen35.nextn_predict_layers',1,0)]:
        field=reader.fields[key]
        if field.contents()!=old: raise ValueError('unexpected metadata')
        field.parts[field.data[0]][0]=new
    reader.data.flush()
    del reader
    tensor_digest=tensor_hash(source,offset)
    if tensor_hash(target,offset)!=tensor_digest: raise ValueError('tensor bytes changed')
    write_json(ROOT/'experiments/mobile_ai_v1/chat-metadata-repair.json',dict(
        source_sha256=expected,output_sha256=sha256(target),
        tensor_data_sha256=tensor_digest,tensor_bytes_unchanged=True,
        fields={'qwen35.block_count':[25,24],'qwen35.nextn_predict_layers':[1,0]}))
    print(target,flush=True)

if __name__=='__main__':main()
