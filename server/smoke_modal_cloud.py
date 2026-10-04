# SPDX-License-Identifier: GPL-3.0-only
"""Small real-cloud smoke suite. Never substitutes mock results for L4 evidence."""
import argparse
import dataclasses
import datetime
import json
from pathlib import Path
import time
import uuid
import modal
from modal_client import auth_headers, read_config, request, synthesize
from revoice_registry import PresetRegistry

ROOT=Path(__file__).resolve().parent
APP_NAME='audiorelaylab-qwen'


def statistics():
    # Query the single class service pool without invoking a method/warming a GPU.
    worker=modal.Cls.from_name(APP_NAME,'QwenWorker')()
    return dataclasses.asdict(worker.synthesize.get_current_stats())


def wait_zero(output, label):
    started=time.monotonic()
    while time.monotonic()-started<180:
        state=statistics()
        if all(state.get(key,0)==0 for key in ('num_total_runners','num_running_inputs','backlog','input_headroom')):
            result=dict(label=label,seconds=time.monotonic()-started,stats=state)
            output.append(result)
            print('Scale-to-zero confirmed:',label,flush=True)
            return
        time.sleep(5)
    raise RuntimeError('Scale-to-zero was not confirmed; do not mark this test passed')


def collect_gpu_evidence(started, request_ids):
    app=modal.App.lookup(APP_NAME)
    found={}
    for _ in range(4):
        for entry in app.logs.fetch(since=started):
            for line in entry.message.splitlines():
                try:
                    item=json.loads(line)
                except ValueError:
                    continue
                if item.get('event')=='qwen_generation' and item.get('requestID') in request_ids:
                    found[item['requestID']]=item
        if set(found)==set(request_ids):return found
        time.sleep(3)
    raise RuntimeError('Private GPU audit metadata is incomplete')


def run(output):
    config=read_config();registry=PresetRegistry();headers=auth_headers(config)
    if output.exists():raise ValueError('Choose a fresh smoke-test directory')
    output.mkdir(parents=True)
    started=datetime.datetime.now(datetime.timezone.utc)
    report=dict(status='running',startedAt=started.isoformat(),appName=APP_NAME,endpoint=config['endpoint'],
                security=[],voices=[],scaleToZero=[])
    def save():
        (output/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2,default=str)+'\n',encoding='utf-8')
    save()
    try:
        wait_zero(report['scaleToZero'],'before-security-tests')
        before=statistics()
        health=request(config,'GET','v1/health')
        voices=request(config,'GET','v1/voices')
        if health.status!=200 or voices.status!=200:
            raise RuntimeError('The authenticated CPU endpoints are unavailable')
        actual_voices=json.loads(voices.data).get('voices')
        if actual_voices!=registry.public_voices():
            raise RuntimeError('The deployed voice inventory differs from the approved local registry')
        report['cpuEndpoints']=dict(health=json.loads(health.data),voices=actual_voices)
        save()
        security=[('missing-proxy',{},dict(voice='serena-original',text='你好。')),
                  ('wrong-proxy',{**headers,'Modal-Key':'invalid','Modal-Secret':'invalid'},dict(voice='serena-original',text='你好。')),
                  ('wrong-app-key',{**headers,'X-AudioRelay-Key':'invalid'},dict(voice='serena-original',text='你好。')),
                  ('unknown-voice',headers,dict(voice='unknown-preset',text='你好。')),
                  ('empty-text',headers,dict(voice='serena-original',text=' ')),
                  ('oversize-text',headers,dict(voice='serena-original',text='字'*1001))]
        for name,auth,body in security:
            response=request(config,'POST','v1/tts',body=body,headers=auth)
            expected=(401,403) if name in ('missing-proxy','wrong-proxy','wrong-app-key') else (400,413,422)
            if response.status not in expected:raise RuntimeError('Security check failed: '+name)
            report['security'].append(dict(test=name,status=response.status,passed=True));save()
        after=statistics()
        if before['num_total_runners']!=0 or after['num_total_runners']!=0 or after['num_running_inputs']!=0:
            raise RuntimeError('An invalid HTTP request appears to have activated GPU resources')
        report['invalidRequestsDidNotActivateGPU']=True
        def generate(voice,text,name):
            metadata=synthesize(voice,text,output/(name+'.wav'),config)
            report['voices'].append(dict(test=name,**metadata,passed=True));save()
            print('Generated:',voice,name,flush=True)
            return metadata
        cold=generate('serena-original','今天的天气不错，我们出去走走吧。','cold')
        warm=generate('serena-original','真的吗？那太好了。','warm')
        if cold['sessionID']!=warm['sessionID'] or warm['modelLoadSeconds']!=0:
            raise RuntimeError('Warm generation did not reuse the same resident model')
        report['firstColdSeconds']=cold['totalSeconds'];report['warmSeconds']=warm['totalSeconds']
        tested={'serena-original'}
        # Finish CustomVoice first, then switch once to Base to minimize GPU model reloads.
        for preset in sorted((p for p in registry.presets.values() if p.enabled),key=lambda p:p.variant=='base'):
            if preset.id in tested:continue
            generate(preset.id,'你好，今天过得怎么样？',preset.id);tested.add(preset.id)
        if tested!={p.id for p in registry.presets.values() if p.enabled}:
            raise RuntimeError('Not all accepted voices have real WAV evidence')
        wait_zero(report['scaleToZero'],'after-warm-and-all-presets');save()
        second=generate('serena-original','你好，我们又见面了。','second-cold')
        if second['sessionID']==cold['sessionID']:
            raise RuntimeError('The post-idle request did not create a new GPU session')
        report['secondColdSeconds']=second['totalSeconds']
        evidence=collect_gpu_evidence(started,[v['requestID'] for v in report['voices']])
        for result in report['voices']:
            item=evidence[result['requestID']];preset=registry.get(result['voice'])
            if (item['gpuName'].removeprefix('NVIDIA ').strip()!='L4' or item['cudaTotalMemoryBytes']<22_000_000_000 or item['dtype']!='torch.bfloat16'
                    or item['attention']!='sdpa' or item['variant']!=preset.variant or item['residentModelCount']!=1
                    or not item['offlineAssetsVerified'] or item['sourceAudioProvidedToSynthesis'] or item['sourceTimingProvided']):
                raise RuntimeError('Runtime GPU, model route or offline input isolation differs from the intended deployment')
            if preset.variant=='base' and item['targetReferenceSHA256']!=registry.references[preset.reference_id]['audioSHA256']:
                raise RuntimeError('Cloud target reference identity mismatch')
            pinned=registry.lock['models'][preset.variant]
            if item['modelRevision']!=pinned['revision'] or item['modelRepository']!=pinned['repository']:
                raise RuntimeError('Runtime model was not the locked 1.7B revision')
            result['runtime']=item
        report['actualGPU']='NVIDIA L4'
        report['peakGiB']=max(v['runtime']['cudaPeakAllocatedBytes'] for v in report['voices'])/1024**3
        wait_zero(report['scaleToZero'],'final-idle');save()
        workspace=modal.Workspace.from_context()
        report['billingSummary']=dataclasses.asdict(workspace.billing.summary())
        report['rates']={k:str(v) for k,v in workspace.billing.rates().items() if 'L4' in k or 'l4' in k}
        report['status']='passed';save()
        print('All real-cloud checks passed. Report:',output/'report.json',flush=True)
    except BaseException as error:
        report.update(status='failed',failureType=type(error).__name__)
        save()
        raise


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir',default=str(ROOT.parent/'dist/modal-smoke'/uuid.uuid4().hex))
    args=parser.parse_args();run(Path(args.output_dir).resolve())


if __name__=='__main__':main()
