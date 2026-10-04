import asyncio
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid
import wave
from unittest import mock

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'server'))
from fastapi.testclient import TestClient
from modal_api import create_api
from modal_jobs import JobService, MemoryStore, JobError, LegacyJobGuard, create_download_api, validate_audio
from revoice_contract import SPEAKERS

KEY='test-only-durable-job-key-00000000000000000'
ORIGIN='https://download.example.test'

def result(payload,seconds=0.35):
    stream=io.BytesIO()
    with wave.open(stream,'wb') as writer:
        writer.setnchannels(1); writer.setsampwidth(2); writer.setframerate(24000)
        writer.writeframes(b'\x01\x00'*round(seconds*24000))
    data=stream.getvalue()
    return data,dict(sha256=hashlib.sha256(data).hexdigest(),sampleRate=24000,outputDuration=seconds,
        generationSeconds=0.4,modelLoadSeconds=0,sessionID='test-session',voice=payload['voice'],speaker=payload['speaker'])

class JobTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.now=1000000.; self.store=MemoryStore()
        self.jobs=JobService(self.store,self.temp.name,KEY,clock=lambda:self.now)
        self.payload=dict(mode='custom',voice='custom',variant='custom',speaker='Serena',text='嗯，我，我还没连 Wi-Fi。',instruction='  放松  ',revision='test-revision')
        self.id=uuid.uuid4().hex; self.enqueues=[]; self.invocations=[]
    async def enqueue(self,identity): self.enqueues.append(identity)
    async def invoke(self,payload,identity):
        self.invocations.append((payload,identity))
        data,metadata=result(payload)
        return dict(audio=data,metadata=metadata)
    async def submit(self): return await self.jobs.submit(self.id,self.payload,self.enqueue)
    async def test_disconnect_and_duplicate_spawn_only_infer_once(self):
        await self.submit(); await self.submit()
        await asyncio.gather(self.jobs.execute(self.id,self.invoke),self.jobs.execute(self.id,self.invoke))
        await self.submit()
        self.assertEqual(len(self.invocations),1); self.assertEqual(self.jobs.get(self.id)['state'],'complete')
        self.assertEqual(self.invocations[0][0],self.payload)
    async def test_restart_and_uncertain_submission_keep_original_id(self):
        async def lost(_): raise ConnectionError('response lost')
        with self.assertRaises(JobError) as e: await self.jobs.submit(self.id,self.payload,lost)
        self.assertEqual(e.exception.status,503)
        restarted=JobService(self.store,self.temp.name,KEY,clock=lambda:self.now)
        await restarted.submit(self.id,self.payload,self.enqueue); await restarted.execute(self.id,self.invoke)
        self.assertEqual(len(self.invocations),1)
    async def test_conflicting_parameters_never_start_second_gpu(self):
        await self.submit()
        with self.assertRaises(JobError) as e: await self.jobs.submit(self.id,self.payload|{'instruction':'different'},self.enqueue)
        self.assertEqual(e.exception.status,409); self.assertEqual(len(self.enqueues),1)
    async def test_failure_releases_slot_without_partial_audio(self):
        await self.submit()
        async def fail(*_): raise RuntimeError('OOM')
        await self.jobs.execute(self.id,fail)
        self.assertEqual(self.jobs.get(self.id)['state'],'failed'); self.assertFalse(list(Path(self.temp.name).glob('*')))
        await self.jobs.submit(uuid.uuid4().hex,self.payload,self.enqueue)
    async def test_wrong_voice_and_corrupt_output_fail_without_save(self):
        for corrupt in ('voice','digest','duration'):
            self.id=uuid.uuid4().hex; await self.submit()
            async def invoke(payload,identity):
                data,meta=result(payload)
                if corrupt=='voice': meta['speaker']='Vivian'
                if corrupt=='digest': data=data[:-2]
                if corrupt=='duration': meta['outputDuration']=181
                return data,meta
            await self.jobs.execute(self.id,invoke)
            self.assertEqual(self.jobs.get(self.id)['state'],'failed')
        self.assertFalse(list(Path(self.temp.name).glob('*')))
    async def test_result_lives_24_hours_and_cleanup_does_not_infer(self):
        await self.submit(); await self.jobs.execute(self.id,self.invoke)
        record=self.jobs.get(self.id); token='Bearer '+self.jobs.token(record)
        self.now+=86399; record,data=await self.jobs.download(self.id,token,0); self.assertIsNotNone(data)
        self.now+=2
        with self.assertRaises(JobError) as e: self.jobs.get(self.id)
        self.assertEqual(e.exception.status,410); self.assertEqual(self.jobs.cleanup()['expiredJobsRemoved'],1)
        self.assertFalse(list(Path(self.temp.name).glob('*'))); self.assertEqual(len(self.invocations),1)
    async def test_download_token_is_per_job_and_read_only(self):
        await self.submit(); record=self.jobs.get(self.id)
        for token in ('Bearer '+KEY,'Bearer '+'0'*64,'Bearer '+self.jobs.token(record)+'x'):
            with self.assertRaises(JobError): await self.jobs.download(self.id,token,0)
        self.store.put('job:'+uuid.uuid4().hex,record)
        self.assertEqual((await self.jobs.download(self.id,'Bearer '+self.jobs.token(record),0))[1],None)
        self.assertFalse(self.invocations)
    async def test_pending_deadline_releases_admission_and_unknown_ids(self):
        await self.submit(); self.now+=901
        self.assertEqual(self.jobs.get(self.id)['state'],'failed')
        await self.jobs.submit(uuid.uuid4().hex,self.payload,self.enqueue)
        for identity,status in [('bad',400),(uuid.uuid4().hex,404)]:
            with self.assertRaises(JobError) as e: self.jobs.get(identity)
            self.assertEqual(e.exception.status,status)
    async def test_legacy_calls_share_persistent_admission_and_rate(self):
        guard=LegacyJobGuard(self.jobs); self.assertTrue(guard.enter())
        with self.assertRaises(JobError): await self.submit()
        guard.leave(); await self.submit(); self.assertFalse(guard.enter())
        await self.jobs.execute(self.id,self.invoke)
        self.store.put('rate',[self.now]*12)
        with self.assertRaises(JobError) as e: await self.jobs.submit(uuid.uuid4().hex,self.payload,self.enqueue)
        self.assertEqual(e.exception.status,429)
    def test_70_second_output_supported_180_limit_and_truncation_rejected(self):
        for seconds in (70,180):
            data,meta=result(self.payload,seconds); validate_audio(data,meta)
        data,meta=result(self.payload,180.01)
        with self.assertRaises(ValueError): validate_audio(data,meta)
        data,meta=result(self.payload); data=data[:-1]; meta['sha256']=hashlib.sha256(data).hexdigest()
        with self.assertRaises(ValueError): validate_audio(data,meta)

class JobAPITests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.store=MemoryStore(); self.jobs=JobService(self.store,self.temp.name,KEY)
        self.enqueued=[]
        async def enqueue(identity): self.enqueued.append(identity)
        self.client=TestClient(create_api(mock.AsyncMock(),KEY,custom_worker=mock.AsyncMock(),
            jobs=self.jobs,enqueue=enqueue,download_origin=ORIGIN))
        self.download=TestClient(create_download_api(self.jobs)); self.headers={'X-AudioRelay-Key':KEY}
        self.body=dict(requestID=str(uuid.uuid4()),mode='custom',speaker='Serena',text='嗯，我，我没连 Wi-Fi。',instruction='  原样传递。  ')
    def submit(self,body=None): return self.client.post('/v1/jobs',json=body or self.body,headers=self.headers)
    def test_all_speakers_raw_instruction_and_text_only(self):
        for speaker in SPEAKERS:
            body=self.body|dict(requestID=str(uuid.uuid4()),speaker=speaker)
            response=self.submit(body); self.assertEqual(response.status_code,202,response.text)
            record=self.jobs.get(response.json()['id'])
            self.assertEqual(record['payload']['instruction'],self.body['instruction'])
            self.assertEqual(set(record['payload']),{'mode','voice','variant','speaker','text','instruction','revision'})
            self.jobs.release_active(record['id'])
    def test_preset_uses_registry_instruction_and_never_accepts_override(self):
        body=dict(requestID=str(uuid.uuid4()),mode='preset',voice='cool-serena',text='今天好吗？')
        bad=self.submit(body|{'instruction':'override'}); self.assertEqual(bad.status_code,400); self.assertFalse(self.enqueued)
        response=self.submit(body); self.assertEqual(response.status_code,202)
        self.assertTrue(self.jobs.get(response.json()['id'])['payload']['instruction'])
    def test_invalid_and_unauthenticated_requests_never_enqueue(self):
        for body in [self.body|{'speaker':'unknown'},self.body|{'text':'x'*1001},self.body|{'instruction':'x'*501},
                     self.body|{'requestID':'bad'},self.body|{'audio':'unwanted'},self.body|{'mode':'bad'},self.body|{'text':''}]:
            self.assertEqual(self.submit(body).status_code,400)
        self.assertEqual(self.client.post('/v1/jobs',json=self.body).status_code,403)
        self.assertEqual(self.client.post('/v1/jobs',json=self.body,headers={'Authorization':'Bearer '+'0'*64}).status_code,403)
        raw=json.dumps(self.body)[:-1]+',"speaker":"Vivian"}'
        self.assertEqual(self.client.post('/v1/jobs',content=raw,headers=self.headers|{'Content-Type':'application/json'}).status_code,400)
        self.assertFalse(self.enqueued)
    def test_health_queries_and_download_do_not_enqueue_or_import_gpu(self):
        health=self.client.get('/v1/health',headers=self.headers).json()
        self.assertTrue(health['capabilities']['asyncJobs']); self.assertEqual(health['jobDownloadOrigin'],ORIGIN)
        reply=self.submit().json(); self.enqueued.clear()
        self.assertEqual(self.client.get('/v1/jobs/'+reply['id'],headers=self.headers).status_code,200)
        url='/v1/jobs/'+reply['id']+'/audio'
        self.assertEqual(self.download.get(url,headers={'X-AudioRelay-Key':KEY}).status_code,403)
        token={'Authorization':'Bearer '+reply['downloadToken']}
        self.assertEqual(self.download.get(url,headers=token).status_code,202)
        for wait in ('121','-1','nan'):
            self.assertEqual(self.download.get(url+'?wait='+wait,headers=token).status_code,400)
        self.assertEqual(self.download.post('/v1/jobs',json=self.body,headers=token).status_code,404)
        self.assertFalse(self.enqueued)
    def test_full_download_and_range_have_identical_digest_identity(self):
        reply=self.submit().json()
        async def invoke(payload,identity): return result(payload)
        asyncio.run(self.jobs.execute(reply['id'],invoke))
        url='/v1/jobs/'+reply['id']+'/audio'; token={'Authorization':'Bearer '+reply['downloadToken']}
        full=self.download.get(url,headers=token); self.assertEqual(full.status_code,200)
        self.assertEqual(hashlib.sha256(full.content).hexdigest(),full.headers['X-Audio-SHA256'])
        resumed=self.download.get(url,headers=token|{'Range':'bytes=44-'})
        self.assertEqual(resumed.status_code,206); self.assertEqual(resumed.content,full.content[44:])
        self.assertEqual(resumed.headers['X-Request-ID'],reply['id'])
        self.assertEqual(self.download.get(url,headers=token|{'Range':'bytes=999999-'}).status_code,416)
        another=self.jobs.store.get('job:'+reply['id']); another['expiresAt']+=1
        self.jobs.store.put('job:'+reply['id'],another)
        self.assertEqual(self.download.get(url,headers=token).status_code,403)

if __name__=='__main__': unittest.main()
