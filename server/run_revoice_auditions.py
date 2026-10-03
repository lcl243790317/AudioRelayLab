# SPDX-License-Identifier: GPL-3.0-only
"""Reproduce the complete audition set into a new directory; production service is not controlled."""
import argparse
import json
from pathlib import Path
import numpy as np
import soundfile as sf
from scipy.signal import resample
from evaluate_revoice import run_worker, evaluate

ROOT=Path(__file__).resolve().parent

def write_tasks(path,tasks):
    path.write_text(json.dumps(tasks,ensure_ascii=False,indent=2),encoding='utf-8')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir',required=True)
    args=parser.parse_args();output=Path(args.output_dir).resolve()
    if output.exists():raise ValueError('Use a new output directory; auditions are never overwritten')
    output.mkdir(parents=True)
    cases=json.loads((ROOT/'revoice-audition-cases.json').read_text(encoding='utf-8-sig'))
    custom=[dict(c,id=speaker.lower()+'-'+c['id'],speaker=speaker,instruction=cases['customInstruction']) for speaker in ['Serena','Vivian'] for c in cases['cases']]
    custom += [dict(id='serena-short',text='嗯，嗯，好的。',speaker='Serena',instruction=cases['customInstruction']),dict(id='serena-long',text=cases['longText'],speaker='Serena',instruction=cases['customInstruction'])]
    write_tasks(output/'custom-tasks.json',custom)
    run_worker(['tts','--variant','custom','--tasks',str(output/'custom-tasks.json'),'--output',str(output)],output/'custom.log')
    write_tasks(output/'design-tasks.json',[dict(id='designed-reference',text=cases['referenceText'],instruction=cases['designInstruction'])])
    run_worker(['tts','--variant','design','--tasks',str(output/'design-tasks.json'),'--output',str(output)],output/'design.log')
    write_tasks(output/'base-tasks.json',[dict(c,id='designed-'+c['id']) for c in cases['cases']])
    run_worker(['tts','--variant','base','--tasks',str(output/'base-tasks.json'),'--output',str(output),'--reference',str(output/'designed-reference.wav'),'--reference-text',cases['referenceText']],output/'base.log')
    revision=json.loads((ROOT/'revoice-lock.json').read_text())['sourceSampleRevision']
    examples=ROOT/'.runtime'/('seed-vc-'+revision)/'examples/source'
    for name,filename in [('male','source_s3.wav'),('dialogue','source_s4.wav')]:
        samples,rate=sf.read(examples/filename,dtype='float32')
        sf.write(output/('source-'+name+'.wav'),samples,rate,subtype='PCM_16')
        if name=='male':
            sf.write(output/'source-male-fast.wav',resample(samples,int(len(samples)/1.2)),rate,subtype='PCM_16')
            sixty=np.tile(samples,int(np.ceil(60*rate/len(samples))))[:60*rate]
            sf.write(output/'source-60s.wav',sixty,rate,subtype='PCM_16')
    for name in ['male','male-fast','dialogue','60s']:
        evaluate(output/('source-'+name+'.wav'),None,'Serena',output/('pipeline-'+name+'.wav'))
    evaluate(None,'嗯，我，我想明天再去。明天晚上七点半，记得检查 Wi-Fi。','Serena',output/'corrected-text.wav')
    from build_revoice_audition_page import make_page
    make_page(output,output/'自然重新配音试听.html')

if __name__=='__main__':main()
