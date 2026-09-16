"""Install synthetic fixtures ONLY on the disposable care_ai_validation AVD."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
from scripts.android_validation import adb, ROOT, ADB, SERIAL

PACKAGE='org.carenotebook.care_notebook'
FILES=f'/data/user/0/{PACKAGE}/files'

def copy_private(source, destination):
    # Only fixed harness destinations; no user-supplied shell syntax.
    if not destination.startswith(FILES+'/') or any(c not in '/._-' and not c.isalnum() for c in destination):
        raise ValueError('unsafe destination')
    env=dict(os.environ,ANDROID_USER_HOME=str(ROOT/'.tools/android-user'))
    # adb shell may attach a PTY even with a file stdin and truncate binary at
    # control characters. Use adb sync; this temporary file is PUBLIC fixture data.
    temporary='/data/local/tmp/care-ai-public-fixture'
    subprocess.run([str(ADB),'-s',SERIAL,'push',str(source),temporary],
        stdout=subprocess.DEVNULL,check=True,env=env,timeout=300)
    try:
        adb('shell','chmod','644',temporary)
        adb('shell','run-as',PACKAGE,'cp',temporary,destination)
        if int(adb('shell','run-as',PACKAGE,'stat','-c','%s',destination)) != Path(source).stat().st_size:
            raise ValueError('fixture copy size mismatch')
    finally:
        adb('shell','rm',temporary)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['install','start','report']);args=parser.parse_args()
    if adb('emu','avd','name').splitlines()[0]!='care_ai_validation':raise ValueError('refusing other device')
    if args.action=='install':
        apk=ROOT/'mobile/build/app/outputs/flutter-apk/app-debug.apk'
        print(adb('install','-r','-t',str(apk)),flush=True)
        shutil.copyfile(apk,ROOT/'data/mobile-ai/native-ai-smoke.apk')
        adb('shell','run-as',PACKAGE,'mkdir','-p',FILES+'/smoke')
        print('Copying public model pack',flush=True)
        copy_private(ROOT/'data/mobile-ai/care-ai-dev-2026-09-11-v2.careai',FILES+'/smoke.careai')
        for path in (ROOT/'data/mobile-ai/smoke-fixtures').iterdir():
            if path.is_file():copy_private(path,FILES+'/smoke/'+path.name)
        print('Fixtures installed',flush=True)
    elif args.action=='start':
        adb('shell','am','force-stop',PACKAGE)
        print(adb('shell','am','start','-n',PACKAGE+'/.MainActivity'))
    else:
        raw=adb('shell','run-as',PACKAGE,'cat',FILES+'/native-ai-report.json')
        result=json.loads(raw)
        path=ROOT/'experiments/mobile_ai_v1/android-native-smoke.json'
        path.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
        print(json.dumps(result,ensure_ascii=False,indent=2))

if __name__=='__main__':main()
