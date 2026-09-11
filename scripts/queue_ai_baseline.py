"""Execute declared comparisons sequentially, one model process at a time."""
import argparse
import subprocess
import sys

from scripts.ai_baseline_common import ROOT

STAGES = {
    'ocr_retry': [('ocr','ppocr5_ko','plain',0,'ocr-ppocr5-ko-cache-fixed80'),
                  ('ocr','ppocr5_multi','plain',0,'ocr-ppocr5-multi-cache-fixed160')],
    'grammar_fixed': [('chat','qwen35_2b','grammar',8,'chat-qwen35-2b-grammar-eos-fixed40'),
                      ('chat','gemma4_e2b','grammar',8,'chat-gemma4-e2b-grammar-eos-fixed40')],
    'filter': [('chat','qwen35_2b','filter',0,'chat-qwen35-2b-filter200'),
               ('chat','qwen35_4b','filter',8,'chat-qwen35-4b-filter40')],
    'grammar': [('chat','qwen35_2b','grammar',8,'chat-qwen35-2b-grammar40'),
                ('chat','gemma4_e2b','grammar',8,'chat-gemma4-e2b-grammar40')],
    'screening': [('chat','qwen35_4b','plain',8,'chat-qwen35-4b-screen40'),
                  ('chat','gemma4_e2b','plain',8,'chat-gemma4-e2b-screen40')],
    'transcription': [('ocr','ppocr5_ko','plain',0,'ocr-ppocr5-ko-dev80'),
                      ('ocr','ppocr5_multi','plain',0,'ocr-ppocr5-multi-dev160'),
                      ('asr','whisper_base','plain',0,'asr-whisper-base-validation203'),
                      ('asr','whisper_small','plain',0,'asr-whisper-small-validation203'),
                      ('asr','qwen3_asr_06b','plain',0,'asr-qwen3-06b-validation203')],
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('stages',nargs='+',choices=list(STAGES))
    args = parser.parse_args()
    failures = []
    for task,model,mode,limit,run_id in [run for stage in args.stages for run in STAGES[stage]]:
        command = [sys.executable,'-m','scripts.run_ai_baseline','--task',task,'--model',model,
                   '--mode',mode,'--limit-per-language',str(limit),'--run-id',run_id]
        result = subprocess.run(command,cwd=ROOT,check=False)
        if result.returncode:
            failures.append(run_id)
    print('Failed runs (preserved for diagnosis):',failures,flush=True)
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()
