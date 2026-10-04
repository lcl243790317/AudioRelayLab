# SPDX-License-Identifier: GPL-3.0-only
"""Bounded serial L4 A/B. A repeated captured marker with a fresh session proves restore."""
import argparse
import dataclasses
import datetime
import json
from pathlib import Path
import statistics as math_stats
import time
import modal
from modal_client import read_config, request, synthesize, synthesize_custom
from smoke_modal_cloud import statistics, collect_gpu_evidence
from revoice_contract import SPEAKERS

ROOT=Path(__file__).resolve().parent
TEXT='你好，今天过得怎么样？'
MAX_COLD_REQUESTS=16

def save(path,report):
    path.write_text(json.dumps(report,ensure_ascii=False,indent=2,default=str)+'\n',encoding='utf-8')

def wait_zero(report,path,label):
    started=time.monotonic()
    while time.monotonic()-started<360:
        state=statistics()
        # The control plane can report zero runners while a draining container still has headroom.
        if all(state.get(key,0)==0 for key in ('num_total_runners','num_running_inputs','backlog','input_headroom')):
            report['scaleToZero'].append(dict(label=label,seconds=time.monotonic()-started,stats=state));save(path,report)
            return
        time.sleep(5)
    raise RuntimeError('GPU pool did not reach zero; the measurement is not cold')

def generate(config,voice,name,folder,started):
    item=synthesize(voice,TEXT,folder/(name+'.wav'),config)
    runtime=collect_gpu_evidence(started,[item['requestID']])[item['requestID']]
    if (runtime['gpuName']!='NVIDIA L4' or runtime['residentModelCount']!=1 or not runtime['offlineAssetsVerified']
            or runtime['sourceAudioProvidedToSynthesis'] or runtime['sourceTimingProvided']):
        raise RuntimeError('Runtime identity or source isolation failed')
    return dict(test=name,**item,runtime=runtime,passed=True)

def run(folder,phase):
    folder.mkdir(parents=True,exist_ok=True)
    path=folder/'snapshot-report.json'
    report=json.loads(path.read_text(encoding='utf-8')) if path.exists() else dict(
        startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),coldRequests=0,baseline=[],snapshot=[],
        warm=[],smoke=[],scaleToZero=[],status='running')
    config=read_config();started=datetime.datetime.now(datetime.timezone.utc)
    phase_folder=folder/phase;phase_folder.mkdir(exist_ok=True)
    report[phase+'StartedAt']=started.isoformat()
    report[phase+'BillingBefore']=dataclasses.asdict(modal.Workspace.from_context().billing.summary());save(path,report)
    def cold(voice):
        if report['coldRequests']>=MAX_COLD_REQUESTS:raise RuntimeError('The 16-cold-request bound was reached')
        wait_zero(report,path,'before-'+str(report['coldRequests']+1))
        report['coldRequests']+=1;save(path,report)
        name='cold-'+str(report['coldRequests'])
        value=generate(config,voice,name,phase_folder,started)
        prior = report['baseline'] + report['snapshot'] + report.get('invalidColdSamples',[])
        if value['runtime']['generationNumber'] != 1 or any(v['sessionID']==value['sessionID'] for v in prior):
            value['excludedReason']='A live container was reused; not a cold start'
            report.setdefault('invalidColdSamples',[]).append(value);save(path,report)
            return cold(voice)
        report[phase].append(value);save(path,report)
        print(json.dumps(dict(phase=phase,test=name,voice=voice,totalSeconds=value['totalSeconds'],
                              modelLoadSeconds=value['modelLoadSeconds'],snapshotMarker=value['runtime'].get('snapshotMarker'))),flush=True)
        return value
    try:
        if phase=='baseline':
            for voice in ('serena-original','scholar-design'):
                for _ in range(2):
                    if sum(v['voice']==voice for v in report['baseline'])>=2:break
                    value=cold(voice)
                    if not report['warm']:
                        time.sleep(110)
                        warm=generate(config,voice,'after-110-seconds',phase_folder,started)
                        if warm['sessionID']!=value['sessionID'] or warm['modelLoadSeconds']!=0:
                            raise RuntimeError('The 120-second window did not retain the model for 110 seconds')
                        report['warm'].append(warm);save(path,report)
        else:
            markers={v['runtime']['snapshotMarker'] for v in report['snapshot'] if v['runtime'].get('snapshotMarker')}
            for voice in ('serena-original','scholar-design'):
                while sum(v['voice']==voice and v.get('confirmedRestore') for v in report['snapshot'])<3:
                    value=cold(voice);marker=value['runtime'].get('snapshotMarker')
                    if not marker:raise RuntimeError('GPU snapshot initialization was not active')
                    previous=[v for v in report['snapshot'][:-1] if v['runtime'].get('snapshotMarker')==marker]
                    value['confirmedRestore']=marker in markers and all(v['sessionID']!=value['sessionID'] for v in previous)
                    value['restoreEvidence']='repeated captured marker, fresh post-restore session, CUDA inference and one resident model' if value['confirmedRestore'] else 'capture or first observation'
                    markers.add(marker);save(path,report)
            results={}
            for voice in ('serena-original','scholar-design'):
                a=math_stats.median(v['totalSeconds'] for v in report['baseline'] if v['voice']==voice)
                b=math_stats.median(v['totalSeconds'] for v in report['snapshot'] if v['voice']==voice and v.get('confirmedRestore'))
                results[voice]=dict(baselineMedianSeconds=a,snapshotMedianSeconds=b,reduction=1-b/a,passed=b<=a*.7)
            report['comparison']=results;report['enableSnapshot']=all(v['passed'] for v in results.values())
            # Reuse the final live Base session for voice smoke; this creates no second GPU pool.
            final_session=report['snapshot'][-1]['sessionID']
            smoke_folder=folder/'voices';smoke_folder.mkdir(exist_ok=True)
            for voice in ('cute-design','vivian-original','ancient-dylan','cool-serena'):
                if any(v.get('voice')==voice for v in report['smoke']):continue
                item=generate(config,voice,'preset-'+voice,smoke_folder,started)
                if item['sessionID']!=final_session:raise RuntimeError('Smoke unexpectedly created a new GPU session')
                report['smoke'].append(item);save(path,report)
            for speaker in SPEAKERS:
                if any(v.get('speaker')==speaker and v.get('generationMode')=='custom' for v in report['smoke']):continue
                item=synthesize_custom(speaker,TEXT,'',smoke_folder/('speaker-'+speaker+'.wav'),config)
                item['runtime']=collect_gpu_evidence(started,[item['requestID']])[item['requestID']]
                if item['sessionID']!=final_session or item['runtime']['residentModelCount']!=1:
                    raise RuntimeError('Custom smoke did not reuse the single GPU session')
                report['smoke'].append(dict(**item,passed=True));save(path,report)
                print(json.dumps(dict(test='speaker-smoke',speaker=speaker,totalSeconds=item['totalSeconds'])),flush=True)
        wait_zero(report,path,'phase-final-idle')
        report[phase+'BillingAfter']=dataclasses.asdict(modal.Workspace.from_context().billing.summary())
        report['status']=phase+'-passed';save(path,report)
        # Preserve platform messages that corroborate snapshot capture/restore, without user content.
        events=[]
        for entry in modal.App.lookup('audiorelaylab-qwen').logs.fetch(since=started):
            for line in entry.message.splitlines():
                if 'snapshot' in line.lower() and not line.startswith('{'):
                    events.append(line[:500])
        report[phase+'PlatformSnapshotEvents']=events;save(path,report)
    except BaseException as error:
        report.update(status=phase+'-failed',failureType=type(error).__name__,failure=str(error))
        if phase=='snapshot':report['enableSnapshot']=False
        save(path,report);raise

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase',choices=['baseline','snapshot'],required=True)
    parser.add_argument('--output-dir',required=True)
    args=parser.parse_args();run(Path(args.output_dir).resolve(),args.phase)
