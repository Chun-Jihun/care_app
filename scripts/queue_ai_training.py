"""Sequential foreground batch; each child gets a new immutable run ID."""
import argparse
import subprocess
import sys

from scripts.ai_training_common import DATA,ROOT,read_json


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--phase',choices=['chat-train','chat-evaluate','asr'],required=True)
    parser.add_argument('--teacher',default='chat-teacher4b-train300-v3')
    args=parser.parse_args()
    commands=[]
    chat=['-m','scripts.run_ai_training_chat']
    if args.phase=='chat-train':
        if read_json(DATA/'runs'/args.teacher/'summary.json')['status']!='completed':
            raise ValueError('teacher must finish before the training batch')
        commands=[chat+['--action','train','--split','train','--run-id','chat-2b-sft-v1'],
                  chat+['--action','train','--split','train','--teacher',args.teacher,'--run-id','chat-2b-distill-v1']]
    elif args.phase=='chat-evaluate':
        for split in ['validation','test','baseline-heldout']:
            for model,adapter in [('base',None),('sft','chat-2b-sft-v1'),('distill','chat-2b-distill-v1')]:
                command=chat+['--action','evaluate','--split',split,'--batch-size','4','--run-id',f'chat-{model}-{split}-v1']
                if adapter:command+=['--adapter',adapter]
                commands.append(command)
    else:
        commands=[['-m','scripts.run_ai_training_asr','--run-id','asr-small-lora-v1']]
    for command in commands:
        print('START',' '.join(command),flush=True)
        result=subprocess.run([sys.executable,*command],cwd=ROOT)
        if result.returncode:raise SystemExit(result.returncode)
        print('DONE',' '.join(command),flush=True)


if __name__=='__main__':main()
