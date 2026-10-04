# SPDX-License-Identifier: GPL-3.0-only
"""Run local recording -> CPU transcription -> text-only TTS, or corrected-text TTS."""
import argparse
import json
import os
import shutil
import subprocess
import time
import uuid
from pathlib import Path
from revoice_contract import text_for_synthesis
from revoice_worker import digest
from revoice_registry import PresetRegistry

ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT/'.runtime/revoice'
PYTHON = RUNTIME/'venv/Scripts/python.exe'
WORKER = ROOT/'revoice_worker.py'


def run_worker(arguments, log, timeout=1800):
    environment = dict(os.environ,PYTHONUNBUFFERED='1',HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1')
    with log.open('w',encoding='utf-8') as stream:
        child = subprocess.Popen([str(PYTHON),'-u','-X','utf8',str(WORKER)]+arguments,
                                 stdout=stream,stderr=subprocess.STDOUT,env=environment)
        try:
            result = child.wait(timeout=timeout)
            if result: raise RuntimeError('Local worker failed; see '+str(log))
        except BaseException:
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=10)
                except subprocess.TimeoutExpired: child.kill();child.wait(timeout=10)
            raise


def evaluate(input_path, text, voice, output):
    registry = PresetRegistry()
    preset = None if voice in ('Serena','Vivian','Designed') else registry.get(voice)
    output = Path(output).resolve()
    if output.suffix.lower() != '.wav': raise ValueError('Output must be a WAV file')
    if output.exists() or output.with_suffix('.json').exists(): raise ValueError('Existing results are never overwritten')
    if not PYTHON.is_file(): raise ValueError('Run setup_revoice_audition.py first')
    folder = RUNTIME/'jobs'/str(uuid.uuid4());folder.mkdir(parents=True)
    before = time.perf_counter()
    recognition = None
    if input_path is not None:
        print('识别中：CPU large-v3',flush=True)
        run_worker(['asr','--input',str(Path(input_path).resolve()),'--output',str(folder/'transcript.json')],folder/'asr.log')
        recognition = json.loads((folder/'transcript.json').read_text(encoding='utf-8'))
        text = recognition['text']
    text = text_for_synthesis(text)
    task = dict(id='result',text=text)
    cases = json.loads((ROOT/'revoice-audition-cases.json').read_text(encoding='utf-8-sig'))
    variant = preset.variant if preset else ('base' if voice=='Designed' else 'custom')
    if preset: task.update(preset.task(text))
    elif variant=='custom':task.update(speaker=voice,instruction=cases['customInstruction'])
    task_path = folder/'tts-task.json'
    task_path.write_text(json.dumps([task],ensure_ascii=False),encoding='utf-8')
    arguments = ['tts','--variant',variant,'--tasks',str(task_path),'--output',str(folder)]
    if variant=='base':
        if preset:
            reference, reference_text = registry.verify_reference(preset.reference_id,ROOT.parent/'dist/revoice-expanded')
        else:
            reference = ROOT.parent/'dist/revoice/designed-reference.wav'
            reference_metadata = json.loads(reference.with_suffix('.json').read_text(encoding='utf-8'))
            if reference_metadata['variant']!='design' or digest(reference)!=reference_metadata['sha256']:
                raise ValueError('The fixed designed target reference has changed')
            reference_text = reference_metadata['text']
        arguments += ['--reference',str(reference),'--reference-text',reference_text]
    print('配音中：'+voice+'（只传文字和目标声线）',flush=True)
    run_worker(arguments,folder/'tts.log')
    report = json.loads((folder/'result.json').read_text(encoding='utf-8'))
    if digest(folder/'result.wav')!=report['sha256']:raise ValueError('Worker output hash mismatch')
    report.update(recognizedText=recognition['text'] if recognition else None,synthesisText=text,
                  recognition=recognition,pipelineSeconds=time.perf_counter()-before,
                  operation='recordingRevoice' if recognition else 'correctedTextSynthesis',
                  sourceFileProvidedToTTS=False)
    output.parent.mkdir(parents=True,exist_ok=True)
    # Prepare complete files before publishing; hard links fail if another writer won.
    temporary_audio = output.parent/('.revoice-'+uuid.uuid4().hex+'.wav.part')
    temporary_metadata = temporary_audio.with_suffix('.json.part')
    published = False
    try:
        shutil.copy2(folder/'result.wav',temporary_audio)
        temporary_metadata.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        os.link(temporary_audio,output)
        published = True
        os.link(temporary_metadata,output.with_suffix('.json'))
    except BaseException:
        if published and output.exists() and os.path.samefile(temporary_audio,output): output.unlink()
        raise
    finally:
        temporary_audio.unlink(missing_ok=True)
        temporary_metadata.unlink(missing_ok=True)
    print('已保存：'+str(output),flush=True)
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    source=parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--input');source.add_argument('--text')
    parser.add_argument('--voice',required=True,help='Serena / Vivian / Designed, or a current registry preset ID')
    parser.add_argument('--output',required=True)
    args=parser.parse_args()
    evaluate(args.input,args.text,args.voice,args.output)

if __name__=='__main__': main()
