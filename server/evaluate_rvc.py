# SPDX-License-Identifier: GPL-3.0-only
"""Isolated, offline RVC audition. Does not register voices or restart the service."""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def evaluate(args):
    import numpy as np
    import soundfile as sf
    import torch
    upstream, model, source, output = (Path(v).resolve() for v in
                                    (args.upstream, args.model, args.input, args.output))
    if not (upstream / 'infer/cli.py').is_file():
        raise ValueError('Expected the pinned official RVC CLI source')
    if any(output.with_suffix(suffix).exists() for suffix in (output.suffix, '.json', '.log')):
        raise ValueError('Choose a new output path; auditions are never overwritten')
    audio, rate = sf.read(source, dtype='float32', always_2d=True)
    seconds = len(audio) / rate
    if not 0.3 <= seconds <= 60 or not np.isfinite(audio).all():
        raise ValueError('Input must be 0.3–60 seconds of finite speech audio')
    checkpoint = torch.load(model, map_location='cpu', weights_only=True)
    if not isinstance(checkpoint, dict) or 'weight' not in checkpoint or 'config' not in checkpoint:
        raise ValueError('Not an inference voice checkpoint')
    index = Path(args.index).resolve() if args.index else None
    if index is not None and not index.is_file():
        raise ValueError('Index does not exist')
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [sys.executable, '-X', 'utf8', '-m', 'infer.cli', '--model', str(model),
               '--input', str(source), '--output', str(output), '--pitch', str(args.pitch),
               '--f0-method', 'rmvpe', '--index-rate', str(args.index_rate if index else 0),
               '--protect', str(args.protect), '--rms-mix-rate', '1']
    if index: command += ['--index', str(index)]
    environment = dict(os.environ, TORCH_FORCE_WEIGHTS_ONLY_LOAD='1', RVC_CUDA_GRAPH='0')
    environment['PYTHONPATH'] = str(Path(__file__).resolve().parent / 'rvc_isolation')
    environment['PATH'] = str(Path(sys.executable).parent) + os.pathsep + environment.get('PATH','')
    before = time.perf_counter()
    result = subprocess.run(command, cwd=upstream, env=environment, capture_output=True,
                            text=True, encoding='utf-8', errors='replace', timeout=600)
    elapsed = time.perf_counter()-before
    output.with_suffix('.log').write_text(result.stdout+'\n'+result.stderr, encoding='utf-8')
    if result.returncode or not output.is_file():
        raise RuntimeError('RVC did not produce audio; see '+str(output.with_suffix('.log')))
    samples, output_rate = sf.read(output, dtype='float32', always_2d=True)
    if len(samples) == 0 or not np.isfinite(samples).all() or np.max(np.abs(samples)) < .0001:
        raise RuntimeError('Invalid or silent output')
    if abs(len(samples)/output_rate-seconds) > .15:
        raise RuntimeError('Output duration differs from the source by more than 150 ms')
    report = dict(engine='RVC isolated audition', upstreamRevision=args.revision,
                  modelSHA256=digest(model), indexSHA256=digest(index) if index else None,
                  sourceSHA256=digest(source), outputSHA256=digest(output),
                  inputDuration=seconds, outputDuration=len(samples)/output_rate,
                  sampleRate=output_rate, elapsedSeconds=elapsed,
                  peak=float(np.max(np.abs(samples))),
                  settings=dict(pitch=args.pitch, indexRate=args.index_rate if index else 0,
                                protect=args.protect, f0Method='rmvpe', rmsMixRate=1),
                  device=torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'CPU',
                  assessment='Awaiting listening review; numerical checks do not prove naturalness')
    output.with_suffix('.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False),flush=True)
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('upstream','revision','model','input','output'):
        parser.add_argument('--'+name,required=True)
    parser.add_argument('--index')
    parser.add_argument('--pitch',type=int,default=8,choices=range(-12,13))
    parser.add_argument('--index-rate',type=float,default=.65)
    parser.add_argument('--protect',type=float,default=.33)
    args=parser.parse_args()
    if not 0 <= args.index_rate <= 1 or not 0 <= args.protect <= .5:
        parser.error('Index rate must be 0–1; protection must be 0–0.5')
    evaluate(args)


if __name__=='__main__': main()
