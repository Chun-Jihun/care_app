"""Inspect/drive only the disposable care_validation AVD, never a physical phone.

Examples: python scripts/android_validation.py tree
          python scripts/android_validation.py tap "촬영"
This helper is deliberately separate from the production application.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8')
ADB = ROOT / '.tools/android-sdk/platform-tools/adb.exe'
SERIAL = 'emulator-5560'
OUT = ROOT / '.tools/native-validation'

def adb(*args, binary=False):
    env = dict(os.environ, ANDROID_USER_HOME=str(ROOT / '.tools/android-user'))
    result = subprocess.run([str(ADB), '-s', SERIAL, *args], env=env, capture_output=True, timeout=45, check=True)
    return result.stdout if binary else result.stdout.decode('utf-8', errors='replace').strip()

def tree():
    adb('shell', 'uiautomator', 'dump', '/data/local/tmp/care-window.xml')
    raw = adb('shell', 'cat', '/data/local/tmp/care-window.xml')
    return ET.fromstring(raw[raw.index('<?xml'):])

def nodes():
    return [{k:n.get(k,'') for k in ('text','content-desc','resource-id','bounds','class','checked','enabled')} for n in tree().iter('node') if n.get('text') or n.get('content-desc') or n.get('class') == 'android.widget.EditText']

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['tree','tap','text','key','swipe','shell','screenshot'])
    parser.add_argument('args', nargs=argparse.REMAINDER)
    options = parser.parse_args()
    if adb('emu','avd','name').splitlines()[0] != 'care_validation':
        raise SystemExit('Refusing to operate outside care_validation.')
    OUT.mkdir(parents=True, exist_ok=True)
    if options.action == 'tree': print(json.dumps(nodes(), ensure_ascii=False, indent=2))
    elif options.action == 'tap':
        pattern=options.args[0]
        deadline=time.monotonic()+12
        while True:
            current=nodes()
            candidates=[n for n in current if pattern in (n.get('text',''),n.get('content-desc',''),n.get('resource-id',''),n.get('class',''))]
            if not candidates:
                candidates=[n for n in current if pattern in (n.get('text','')+' '+n.get('content-desc','')+' '+n.get('resource-id','')+' '+n.get('class',''))]
            if candidates or time.monotonic() >= deadline: break
            time.sleep(.5)
        index=int(options.args[1]) if len(options.args)>1 else 0
        if not candidates: raise SystemExit('UI target not found: '+pattern)
        target=candidates[index]
        x1,y1,x2,y2=map(int,re.findall(r'\d+',target['bounds']))
        print(adb('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2)))
    elif options.action == 'text': print(adb('shell','input','text',options.args[0].replace(' ','%s')))
    elif options.action == 'key': print(adb('shell','input','keyevent',options.args[0]))
    elif options.action == 'swipe': print(adb('shell','input','swipe',*options.args))
    elif options.action == 'shell': print(adb('shell',*options.args))
    elif options.action == 'screenshot':
        name=options.args[0]
        if not re.fullmatch(r'[a-z0-9_-]+',name): raise SystemExit('Invalid artifact name')
        target=OUT/(name+'.png');target.write_bytes(adb('exec-out','screencap','-p',binary=True));print(target)

if __name__ == '__main__': main()
