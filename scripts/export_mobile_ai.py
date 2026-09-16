"""CPU-only export of sealed training artifacts. Never reads the app vault.

Outputs are development candidates until native regression checks pass.
Run one task per process to bound RAM; no original checkpoint is modified.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from scripts.ai_training_common import (ROOT, model_asset, read_json, verify_files,
                                       inventory, write_json, sha256, offline)

OUT = ROOT / 'data/mobile-ai/exports'


def adapter(name):
    directory = ROOT / 'data/ai-training-v1/runs' / name
    summary = read_json(directory / 'summary.json')
    if summary['status'] != 'completed':
        raise ValueError('incomplete training')
    verify_files(directory / 'adapter', summary['adapter_files'])
    return directory / 'adapter'


def chat(directory):
    import torch
    from transformers import Qwen3_5ForConditionalGeneration, AutoProcessor
    from peft import PeftModel
    torch.set_num_threads(2)
    base, asset = model_asset('qwen35_2b')
    trained = adapter('chat-2b-sft-v1')
    print('Merging sealed chat adapter on CPU', flush=True)
    model = Qwen3_5ForConditionalGeneration.from_pretrained(
        base, local_files_only=True, dtype=torch.bfloat16, device_map='cpu')
    model = PeftModel.from_pretrained(model, trained, local_files_only=True).merge_and_unload(safe_merge=True)
    # Transformers does not retain the original optional MTP module. Advertising
    # it in GGUF makes llama.cpp request nonexistent layer-24 tensors.
    if any('mtp.' in key for key in model.state_dict()):
        raise ValueError('unexpected MTP tensors: review export configuration')
    model.config.text_config.mtp_num_hidden_layers = 0
    merged = directory / 'merged'
    model.save_pretrained(merged, safe_serialization=True, max_shard_size='2GB')
    processor = AutoProcessor.from_pretrained(base, local_files_only=True)
    processor.save_pretrained(merged)
    from scripts.ai_baseline_filtering import FILTER_PROMPT
    from scripts.run_ai_training_chat import messages
    marker = 'CARE_QUESTION_PLACEHOLDER_19'
    template = processor.apply_chat_template(messages(marker), tokenize=False,
                                             add_generation_prompt=True, enable_thinking=False)
    if template.count(marker) != 1:
        raise ValueError('ambiguous prompt marker')
    prefix, suffix = template.split(marker)
    write_json(directory / 'prompt.json', dict(prefix=prefix, suffix=suffix,
                                               source_sha256=sha256(ROOT/'scripts/ai_baseline_filtering.py')))
    del model, processor
    import gc
    gc.collect()
    source = ROOT / 'data/mobile-ai/sources/llama.cpp'
    print('Converting merged text weights to GGUF BF16, then Q4_K_M', flush=True)
    subprocess.run([sys.executable, str(source/'convert_hf_to_gguf.py'), str(merged),
                    '--outfile', str(directory/'chat-bf16.gguf'), '--outtype', 'bf16'], check=True)
    quantizer=ROOT/'data/mobile-ai/sources/llama-windows-b10903/llama-quantize.exe'
    subprocess.run([str(quantizer),str(directory/'chat-bf16.gguf'),
                    str(directory/'chat-q4km-text.gguf'),'Q4_K_M','2'],check=True)
    return dict(base=asset, adapter_files=inventory(trained), quantization='Q4_K_M',
                note='Full BF16 base merged with QLoRA adapter, then GGUF quantization; requires native evaluation.')


def asr(directory):
    import torch
    from transformers import WhisperForConditionalGeneration
    from peft import PeftModel
    from whisper.model import Whisper, ModelDimensions, disable_sdpa
    torch.set_num_threads(2)
    base, asset = model_asset('whisper_small')
    trained = adapter('asr-small-lora-v1')
    hf = WhisperForConditionalGeneration.from_pretrained(base, local_files_only=True,
                                                         dtype=torch.float16).float()
    hf = PeftModel.from_pretrained(hf, trained, local_files_only=True).merge_and_unload(safe_merge=True).eval()
    c = hf.config
    model = Whisper(ModelDimensions(n_mels=c.num_mel_bins, n_audio_ctx=c.max_source_positions,
        n_audio_state=c.d_model, n_audio_head=c.encoder_attention_heads, n_audio_layer=c.encoder_layers,
        n_vocab=c.vocab_size, n_text_ctx=c.max_target_positions, n_text_state=c.d_model,
        n_text_head=c.decoder_attention_heads, n_text_layer=c.decoder_layers)).eval()
    state = {}
    for original, tensor in hf.state_dict().items():
        if original == 'proj_out.weight':
            if not torch.equal(tensor, hf.model.decoder.embed_tokens.weight):
                raise ValueError('untied output embedding')
            continue
        key = original.removeprefix('model.')
        for before, after in [('.layers.', '.blocks.'), ('.self_attn_layer_norm.', '.attn_ln.'),
                ('.encoder_attn_layer_norm.', '.cross_attn_ln.'), ('.final_layer_norm.', '.mlp_ln.'),
                ('.self_attn.', '.attn.'), ('.encoder_attn.', '.cross_attn.'),
                ('.q_proj.', '.query.'), ('.k_proj.', '.key.'), ('.v_proj.', '.value.'),
                ('.out_proj.', '.out.'), ('.fc1.', '.mlp.0.'), ('.fc2.', '.mlp.2.'),
                ('encoder.layer_norm.', 'encoder.ln_post.'), ('decoder.layer_norm.', 'decoder.ln.'),
                ('.embed_positions.weight', '.positional_embedding'),
                ('decoder.embed_tokens.weight', 'decoder.token_embedding.weight')]:
            key = key.replace(before, after)
        if key in state:
            raise ValueError('duplicate mapped weight')
        state[key] = tensor
    model.load_state_dict(state, strict=True)
    # Independent implementation comparison before export, no speech input.
    torch.manual_seed(812)
    mel = torch.randn(1, 80, 3000)
    tokens = torch.tensor([[50258, 50264, 50359, 50363]])
    with torch.inference_mode(), disable_sdpa():
        left = hf(input_features=mel, decoder_input_ids=tokens).logits
        right = model(mel, tokens)
    error = (left - right).abs().max().item()
    if not torch.allclose(left, right, atol=0.003, rtol=0.001):
        raise ValueError(f'Whisper implementation mismatch: {error}')
    del hf, state, left, right, mel
    import gc
    gc.collect()
    source = ROOT / 'data/mobile-ai/sources/sherpa-export/scripts/whisper/export-onnx.py'
    sys.path.insert(0, str(source.parent))
    spec = importlib.util.spec_from_file_location('sherpa_export', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.load_model = lambda _: model
    original_export = torch.onnx.export
    def legacy_export(*args, **kwargs):
        return original_export(*args, **dict(kwargs, dynamo=False))
    torch.onnx.export = legacy_export
    sys.argv = [str(source), '--model', 'small']
    previous = Path.cwd()
    try:
        os.chdir(directory)
        with disable_sdpa(), torch.inference_mode():
            module.main()
    finally:
        os.chdir(previous)
        torch.onnx.export = original_export
    return dict(base=asset, adapter_files=inventory(trained), mapping_max_absolute_error=error,
                exporter_sha256=sha256(source), exporter_overrides=['load_model: sealed merged adapter', 'dynamo=False'])


def ocr(directory, kind):
    import torch  # Avoid Paddle/Torch Windows DLL load order conflict.
    torch.set_num_threads(2)
    import paddle
    from paddle.jit.dy2static import utils as static_utils
    temporary = directory/'paddle-tmp'
    temporary.mkdir()
    static_utils.get_temp_dir = lambda: str(temporary)
    from scripts.run_ai_validation import ocr_model
    paddle.set_device('cpu')
    model, characters, checkpoint, asset = ocr_model(kind)
    model.head.ctc_head.set_state_dict(paddle.load(str(checkpoint)))
    model.eval()
    class Recognition(paddle.nn.Layer):
        def __init__(self):
            super().__init__()
            self.backbone = model.backbone
            self.encoder = model.head.ctc_encoder
            self.head = model.head.ctc_head
        def forward(self, image):
            return self.head(self.encoder(self.backbone(image)))
    net = Recognition()
    net.eval()
    net = paddle.jit.to_static(net, input_spec=[paddle.static.InputSpec([1,3,48,320], 'float32', 'image')], full_graph=True)
    with paddle.no_grad():
        net(paddle.zeros([1,3,48,320], dtype='float32'))
    paddle.jit.save(net, str(directory/'recognizer'), input_spec=[paddle.static.InputSpec([1,3,48,320], 'float32', 'image')])
    import paddle2onnx
    output = directory/'recognizer.onnx'
    paddle2onnx.export(str(directory/'recognizer.json'), str(directory/'recognizer.pdiparams'),
                       save_file=str(output), opset_version=17, enable_onnx_checker=True, enable_optimize=False)
    write_json(directory/'characters.json', characters)
    import numpy as np
    import onnxruntime as ort
    session = ort.InferenceSession(str(output), providers=['CPUExecutionProvider'])
    rng = np.random.default_rng(81)
    x = rng.uniform(-1,1,(1,3,48,320)).astype(np.float32)
    with paddle.no_grad():
        expected = net(paddle.to_tensor(x)).numpy()
    actual = session.run(None, {session.get_inputs()[0].name:x})[0]
    np.testing.assert_allclose(actual, expected, atol=2e-4, rtol=2e-3)
    return dict(assets=asset, max_absolute_error=float(np.max(np.abs(actual-expected))))


def detector(directory):
    import paddle2onnx
    base, asset = model_asset('ppocr5_det')
    paddle2onnx.export(str(base/'inference.json'), str(base/'inference.pdiparams'),
        save_file=str(directory/'detector.onnx'), opset_version=17,
        enable_onnx_checker=True, enable_optimize=False)
    import onnxruntime as ort
    import numpy as np
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.log_severity_level = 3
    session = ort.InferenceSession(str(directory/'detector.onnx'), sess_options=options, providers=['CPUExecutionProvider'])
    x = np.zeros((1,3,320,640),dtype=np.float32)
    result = session.run(None,{session.get_inputs()[0].name:x})[0]
    if result.shape != (1,1,320,640) or not np.isfinite(result).all():
        raise ValueError('detector output mismatch')
    return dict(base=asset, output_shape=list(result.shape))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('task', choices=['chat','asr','ocr-ko','ocr-multi','ocr-det'])
    parser.add_argument('--run-name')
    args = parser.parse_args()
    offline()
    os.environ.update(OMP_NUM_THREADS='2', MKL_NUM_THREADS='2')
    directory = OUT / (args.run_name or args.task)
    directory.mkdir(parents=True, exist_ok=False)
    summary = dict(task=args.task, status='running', started_at=time.time(), medical_release_gate_result=False)
    write_json(directory/'summary.json', summary)
    try:
        summary['conversion'] = (chat(directory) if args.task=='chat' else asr(directory) if args.task=='asr'
                                  else detector(directory) if args.task=='ocr-det'
                                  else ocr(directory, args.task.removeprefix('ocr-')))
        summary.update(status='completed', files=inventory(directory))
    except BaseException as exc:
        summary.update(status='failed', failure_type=type(exc).__name__)
        raise
    finally:
        summary['finished_at'] = time.time()
        write_json(directory/'summary.json', summary)


if __name__ == '__main__':
    main()
