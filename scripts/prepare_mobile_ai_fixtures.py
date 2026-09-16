"""Extend native smoke fixtures with fixed multilingual text and page cases."""
import json
import shutil
from scripts.ai_training_common import ROOT, read_json, write_json, sha256

def main():
    target=ROOT/'data/mobile-ai/smoke-fixtures'
    manifest=read_json(target/'fixtures.json')
    cases=[r for r in manifest['cases'] if not r['id'].startswith(('ocr-text-','ocr-page-'))]
    for task in ['ocr','ocr-pages']:
        source=ROOT/'data/ai-validation-v1/inputs'/task
        rows=[json.loads(line) for line in (source/'test.jsonl').read_text(encoding='utf-8').splitlines()]
        for row in rows:
            if row['variant']!='clean':continue
            if task=='ocr' and not any(row['id'].endswith(f'-{index}-clean') for index in ['16','19']):continue
            name=('ocr-text-' if task=='ocr' else 'ocr-page-')+row['id']
            shutil.copyfile(source/row['path'],target/(name+'.png'))
            cases.append(dict(id=name,task='ocr',language=row['language'],file=name+'.png',
                reference=row['reference'] if task=='ocr' else '\n'.join(r['reference'] for r in row['rows'])))
    write_json(target/'fixtures.json',dict(cases=cases))
    write_json(ROOT/'experiments/mobile_ai_v1/fixtures.lock.json',dict(cases=cases,
        files=[dict(name=p.name,sha256=sha256(p)) for p in sorted(target.iterdir()) if p.is_file()]))
    print(len(cases),'public/synthetic cases')

if __name__=='__main__':main()
