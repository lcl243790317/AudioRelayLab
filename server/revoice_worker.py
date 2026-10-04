# SPDX-License-Identifier: GPL-3.0-only
"""Separate CPU ASR / GPU text-only TTS workers for local auditions, not an App API."""
import argparse
import hashlib
import json
import os
import time
from pathlib import Path
from revoice_contract import synthesis_arguments, text_for_synthesis, validate_input_duration, validate_output_duration
from revoice_audio import MAX_NEW_TOKENS, validated_samples

ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT / '.runtime/revoice'
LOCK = json.loads((ROOT/'revoice-lock.json').read_text(encoding='utf-8-sig'))

def digest(path):
    with Path(path).open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()

def write_json(path, data):
    temporary = path.with_suffix('.json.part')
    temporary.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    temporary.replace(path)

def asr(args):
    # Import CTranslate2 here only; this process never imports PyTorch.
    import numpy as np
    import soundfile as sf
    from faster_whisper import WhisperModel
    source, output = Path(args.input).resolve(), Path(args.output).resolve()
    if output.exists(): raise ValueError('Do not overwrite an existing transcript')
    samples, rate = sf.read(source,dtype='float32',always_2d=True)
    validate_input_duration(len(samples)/rate)
    if not np.isfinite(samples).all() or np.max(np.abs(samples)) < .0001:
        raise ValueError('原声为空或静音')
    started = time.perf_counter()
    model = WhisperModel(str(RUNTIME/'models/asr'),device='cpu',compute_type='int8',cpu_threads=8,local_files_only=True)
    segments, info = model.transcribe(str(source),language='zh',beam_size=5,condition_on_previous_text=False,
                                      vad_filter=True,vad_parameters=dict(min_silence_duration_ms=500))
    segments = [dict(start=float(s.start),end=float(s.end),text=s.text) for s in segments]
    text = text_for_synthesis(''.join(s['text'] for s in segments))
    report = dict(engine='faster-whisper large-v3',modelRevision=LOCK['models']['asr']['revision'],
                  computeType='int8',device='cpu',language=info.language,text=text,segments=segments,
                  sourceSHA256=digest(source),inputDuration=len(samples)/rate,elapsedSeconds=time.perf_counter()-started,
                  assessment='No text rewriting. ASR can misrecognize or omit spoken words; edit text before retrying.')
    output.parent.mkdir(parents=True,exist_ok=True)
    write_json(output,report)
    print(json.dumps(report,ensure_ascii=False),flush=True)

def tts(args):
    import numpy as np
    import soundfile as sf
    import torch
    from qwen_tts import Qwen3TTSModel
    tasks = json.loads(Path(args.tasks).read_text(encoding='utf-8-sig'))
    output_root = Path(args.output).resolve(); output_root.mkdir(parents=True,exist_ok=True)
    for task in tasks:
        text_for_synthesis(task['text'])
        if not task['id'] or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-_' for c in task['id']):
            raise ValueError('Invalid task ID')
        for suffix in ('.wav','.json'):
            if (output_root/(task['id']+suffix)).exists(): raise ValueError('Choose fresh audition paths')
    if args.variant == 'base' and (not args.reference or not args.reference_text):
        raise ValueError('Base requires a fixed target voice reference and exact reference text')
    device = 'cuda:0' if torch.cuda.is_available() else 'cpu'
    dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32
    started = time.perf_counter()
    model = Qwen3TTSModel.from_pretrained(str(RUNTIME/'models'/args.variant),device_map=device,
                                         dtype=dtype,attn_implementation='sdpa',local_files_only=True)
    load_seconds = time.perf_counter()-started
    prompt = None
    if args.variant == 'base':
        prompt = model.create_voice_clone_prompt(ref_audio=str(Path(args.reference).resolve()),
                                                 ref_text=text_for_synthesis(args.reference_text))
    # Observe codec count at the official API boundary; reject token-limit truncation.
    original_generate = model.model.generate
    observed = []
    def observe_generate(*values,**options):
        result = original_generate(*values,**options)
        observed[:] = [int(code.shape[0]) for code in result[0]]
        return result
    model.model.generate = observe_generate
    method = {'custom':model.generate_custom_voice,'design':model.generate_voice_design,'base':model.generate_voice_clone}[args.variant]
    for task in tasks:
        torch.manual_seed(task.get('seed',20261003))
        if torch.cuda.is_available(): torch.cuda.reset_peak_memory_stats()
        before = time.perf_counter()
        arguments = synthesis_arguments(args.variant,task,prompt)
        print('Generating '+task['id']+' ('+str(len(arguments['text']))+' characters)',flush=True)
        wavs, rate = method(**arguments,max_new_tokens=MAX_NEW_TOKENS)
        elapsed = time.perf_counter()-before
        samples = validated_samples(wavs[0],int(rate),observed)
        output = output_root/(task['id']+'.wav')
        partial = output.with_suffix('.wav.part')
        sf.write(partial,samples,int(rate),format='WAV',subtype='PCM_16')
        partial.replace(output)
        report = dict(engine='Qwen3-TTS 1.7B',variant=args.variant,modelRepository=LOCK['models'][args.variant]['repository'],
                      modelRevision=LOCK['models'][args.variant]['revision'],modelSHA256=LOCK['models'][args.variant]['files'][next(i for i,f in enumerate(LOCK['models'][args.variant]['files']) if f['path']=='model.safetensors')]['sha256'],
                      packageVersion='0.1.1',taskID=task['id'],text=arguments['text'],speaker=task.get('speaker'),
                      instruction=task.get('instruction'),seed=task.get('seed',20261003),outputDuration=len(samples)/rate,
                      sampleRate=int(rate),elapsedSeconds=elapsed,modelLoadSeconds=load_seconds,
                      device=device,dtype=str(dtype),attention='sdpa',codecFrames=observed[0],
                      cudaPeakAllocatedBytes=torch.cuda.max_memory_allocated() if torch.cuda.is_available() else None,
                      sourceAudioProvidedToSynthesis=False,sourceTimingProvided=False,
                      targetReferenceSHA256=digest(args.reference) if args.variant=='base' else None,
                      sha256=digest(output),assessment='Awaiting user listening review')
        write_json(output.with_suffix('.json'),report)
        print(json.dumps(report,ensure_ascii=False),flush=True)


def main():
    os.environ['HF_HUB_OFFLINE']='1'; os.environ['TRANSFORMERS_OFFLINE']='1'
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command',required=True)
    recognition = commands.add_parser('asr')
    recognition.add_argument('--input',required=True);recognition.add_argument('--output',required=True)
    synthesis = commands.add_parser('tts')
    synthesis.add_argument('--variant',choices=('custom','design','base'),required=True)
    synthesis.add_argument('--tasks',required=True);synthesis.add_argument('--output',required=True)
    synthesis.add_argument('--reference');synthesis.add_argument('--reference-text')
    args = parser.parse_args()
    if args.command=='asr': asr(args)
    else: tts(args)

if __name__=='__main__': main()
