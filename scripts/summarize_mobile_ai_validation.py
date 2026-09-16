"""Score saved native outputs; never turn an execution smoke into a quality gate."""
import json
import re
import struct
import zipfile
from scripts.ai_training_common import ROOT, read_json, sha256, write_json

def normalized(text): return ''.join(text.casefold().split())
def distance(left,right):
    row=list(range(len(right)+1))
    for i,a in enumerate(left,1):
        nxt=[i]
        for j,b in enumerate(right,1):
            nxt.append(min(nxt[-1]+1,row[j]+1,row[j-1]+(a!=b)))
        row=nxt
    return row[-1]
def main():
    result=read_json(ROOT/'experiments/mobile_ai_v1/android-native-smoke.json')
    if result['status']!='completed': raise ValueError('incomplete native run')
    groups={}
    for task in ['chat','ocr','speech','silence','control']:
        rows=[r for r in result['checks'] if r['task']==task]
        group=dict(cases=len(rows),native_errors=sum('error' in r for r in rows),
                   criterion_passes=sum(r['passed'] for r in rows))
        durations=[r['milliseconds'] for r in rows if 'milliseconds' in r]
        if durations:group['milliseconds_range']=[min(durations),max(durations)]
        if task in ['ocr','speech']:
            samples=[]
            for r in rows:
                reference=normalized(r['reference']); prediction=normalized(r.get('output',''))
                samples.append(dict(id=r['id'],normalized_exact=reference==prediction,
                    errors=distance(reference,prediction),characters=len(reference)))
            group['normalized_exact']=sum(s['normalized_exact'] for s in samples)
            group['cer']=sum(s['errors'] for s in samples)/sum(s['characters'] for s in samples)
            group['per_case']=samples
        groups[task]=group
    apk=ROOT/'mobile/build/app/outputs/flutter-apk/app-release.apk'
    libraries=[]
    with zipfile.ZipFile(apk) as archive:
        for name in archive.namelist():
            if not name.startswith('lib/') or not name.endswith('.so'):continue
            data=archive.read(name)
            if name.split('/')[1]!='arm64-v8a':raise ValueError('unexpected release ABI')
            machine=struct.unpack_from('<H',data,18)[0]
            if machine!=183:
                raise ValueError('unexpected non-arm64 library')
            if data[:6]!=b'\x7fELF\x02\x01':raise ValueError('expected little-endian ELF64')
            offset=struct.unpack_from('<Q',data,32)[0]
            size,count=struct.unpack_from('<HH',data,54)
            aligns=[struct.unpack_from('<Q',data,offset+i*size+48)[0] for i in range(count)
                    if struct.unpack_from('<I',data,offset+i*size)[0]==1]
            libraries.append(dict(name=name,machine=machine,cpu_library=True,load_alignments=aligns,aligned_16k=all(a>=16384 for a in aligns)))
    output=dict(medical_release_gate_result=False,quality_gate_result=False,
        normalization='Unicode casefold and whitespace removal only',groups=groups,
        apk=dict(bytes=apk.stat().st_size,sha256=sha256(apk),libraries=libraries),
        manifest_sha256=sha256(ROOT/'mobile/assets/ai/manifest.json'),
        native_report_sha256=sha256(ROOT/'experiments/mobile_ai_v1/android-native-smoke.json'))
    write_json(ROOT/'experiments/mobile_ai_v1/validation-summary.json',output)
    print(json.dumps({k:{a:b for a,b in v.items() if a!='per_case'} for k,v in groups.items()},ensure_ascii=False,indent=2))
    print('CPU ELF 16K alignments',all(r['aligned_16k'] for r in libraries if r['cpu_library']))

if __name__=='__main__':main()
