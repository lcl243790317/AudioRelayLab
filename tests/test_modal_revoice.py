import asyncio
import contextlib
import hashlib
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'server'))
from fastapi.testclient import TestClient
from modal_api import create_api, RequestGuard, validate_request
from modal_engine import QwenEngine, verify_models
from revoice_audio import validated_samples, wav_bytes
from revoice_registry import PresetRegistry

ROOT = Path(__file__).resolve().parents[1]
TEST_KEY = 'test-only-not-a-deployment-credential-000000'


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.registry = PresetRegistry()

    def test_all_ten_identities_remain_and_only_six_accepted_are_enabled(self):
        self.assertEqual(len(self.registry.presets), 10)
        self.assertEqual([v['id'] for v in self.registry.public_voices()],
                         ['serena-original','vivian-original','ancient-dylan','scholar-design','cute-design','cool-serena'])
        self.assertEqual(self.registry.required_variants(), ['base','custom'])
        self.assertTrue(all(not p['needsVoiceDesignRuntime'] for p in self.registry.inventory()))
        for name in ['cute-serena','lazy-vivian','lazy-design','magnetic-uncle']:
            self.registry.get(name)
            with self.assertRaises(ValueError):
                self.registry.get(name, cloud=True)

    def test_original_speaker_and_performance_instruction_are_preserved(self):
        cases = json.loads((ROOT/'server/revoice-audition-cases.json').read_text(encoding='utf-8'))
        palette = json.loads((ROOT/'server/revoice-palette.json').read_text(encoding='utf-8'))
        for profile in palette['profiles']:
            p = self.registry.get(profile['id'])
            task = p.task('嗯，我，我想休息一下。')
            self.assertEqual(task['text'],'嗯，我，我想休息一下。')
            if profile['kind']=='accepted':
                self.assertEqual(task['instruction'],cases['customInstruction'])
                self.assertEqual(task['speaker'],profile['sourcePrefix'].capitalize())
            elif profile['kind']=='custom':
                self.assertEqual(task['instruction'],profile['instruction'])
                self.assertEqual(task['speaker'],profile['speaker'])
            else:
                self.assertNotIn('instruction',task)
                self.assertNotIn('speaker',task)

    def test_reference_audio_metadata_and_text_must_all_match(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio = root/'fixed.wav'; audio.write_bytes(b'fixed target identity')
            design = self.registry.lock['models']['design']
            metadata = dict(variant='design',sha256=hashlib.sha256(audio.read_bytes()).hexdigest(),text='固定参考文字。',
                            modelRepository=design['repository'],modelRevision=design['revision'],
                            modelSHA256=next(f['sha256'] for f in design['files'] if f['path']=='model.safetensors'))
            report = root/'fixed.json';report.write_text(json.dumps(metadata),encoding='utf-8')
            expected = dict(audioFile=audio.name,metadataFile=report.name,audioSHA256=metadata['sha256'],
                            metadataSHA256=hashlib.sha256(report.read_bytes()).hexdigest(),
                            textSHA256=hashlib.sha256(metadata['text'].encode()).hexdigest())
            with mock.patch.dict(self.registry.references, {'scholar-design':expected}):
                self.assertEqual(self.registry.verify_reference('scholar-design',root),(audio,metadata['text']))
                audio.write_bytes(b'changed identity')
                with self.assertRaises(ValueError):self.registry.verify_reference('scholar-design',root)
                audio.write_bytes(b'fixed target identity')
                report.write_text('{}')
                with self.assertRaises(ValueError):self.registry.verify_reference('scholar-design',root)

    def test_reference_transcript_and_model_revision_cannot_be_substituted(self):
        # Validation also rejects a self-consistent replacement sidecar with a changed transcript/model.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); audio = root/'fixed.wav';audio.write_bytes(b'identity')
            report=root/'fixed.json'; design=self.registry.lock['models']['design']
            for changes in [dict(text='换了一份文字。'),dict(modelRevision='main')]:
                metadata=dict(variant='design',sha256=hashlib.sha256(audio.read_bytes()).hexdigest(),text='固定参考。',
                              modelRepository=design['repository'],modelRevision=design['revision'],
                              modelSHA256=next(f['sha256'] for f in design['files'] if f['path']=='model.safetensors'))
                metadata.update(changes);report.write_text(json.dumps(metadata),encoding='utf-8')
                expected=dict(audioFile=audio.name,metadataFile=report.name,audioSHA256=metadata['sha256'],
                              metadataSHA256=hashlib.sha256(report.read_bytes()).hexdigest(),
                              textSHA256=hashlib.sha256('固定参考。'.encode()).hexdigest())
                with mock.patch.dict(self.registry.references,{'scholar-design':expected}):
                    with self.assertRaises(ValueError):self.registry.verify_reference('scholar-design',root)

    def test_corrupt_pinned_weights_fail_before_loading_a_model(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            item=dict(path='model.safetensors',bytes=4,sha256=hashlib.sha256(b'lock').hexdigest())
            registry=mock.Mock();registry.required_variants.return_value=['custom','base']
            registry.lock={'models':{v:{'files':[item]} for v in ['custom','base']}}
            for variant in ['custom','base']:
                (root/variant).mkdir();(root/variant/'model.safetensors').write_bytes(b'lock')
            verify_models(registry,root)
            (root/'base/model.safetensors').write_bytes(b'evil')
            with self.assertRaises(RuntimeError):verify_models(registry,root)


class AuthAndInputTests(unittest.TestCase):
    def setUp(self):
        self.calls=[]
        async def worker(voice,text,request_id):
            self.calls.append(dict(voice=voice,text=text,request_id=request_id))
            data=b'validated test waveform'
            return dict(audio=data,metadata=dict(voice=voice,sha256=hashlib.sha256(data).hexdigest(),sampleRate=24000,
                outputDuration=1.2,generationSeconds=2.3,modelLoadSeconds=.4,sessionID='test-session'))
        self.worker=worker
        self.client=TestClient(create_api(worker,TEST_KEY))
        self.headers={'X-AudioRelay-Key':TEST_KEY}

    def test_missing_secret_fails_startup(self):
        for key in (None,'','short'):
            with self.assertRaises(RuntimeError):create_api(self.worker,key)

    def test_wrong_or_missing_or_duplicate_app_auth_never_calls_gpu(self):
        for headers in ({},{'X-AudioRelay-Key':'incorrect'}, [('X-AudioRelay-Key',TEST_KEY),('X-AudioRelay-Key','other')]):
            response=self.client.post('/v1/tts',json=dict(voice='serena-original',text='你好。'),headers=headers)
            self.assertEqual(response.status_code,403)
            self.assertEqual(response.headers['cache-control'],'no-store')
        self.assertFalse(self.calls)

    def test_invalid_requests_never_call_gpu(self):
        bodies=[dict(voice='unknown',text='你好。'),dict(voice='serena-original',text=' '),
                dict(voice='serena-original',text='字'*1001),dict(voice='serena-original',text=123),
                dict(voice={'speaker':'Serena'},text='你好。'),dict(voice='cute-serena',text='你好。'),
                dict(voice='serena-original',text='你好。',speaker='Vivian'),
                dict(voice='serena-original',text='你好。',reference='https://example.invalid/ref.wav'),
                dict(voice='../model',text='你好。'),[],None]
        for body in bodies:
            with self.subTest(body=str(body)[:70]):
                response=self.client.post('/v1/tts',json=body,headers=self.headers)
                self.assertGreaterEqual(response.status_code,400);self.assertLess(response.status_code,500)
        self.assertFalse(self.calls)

    def test_large_and_ambiguous_json_rejected_before_gpu(self):
        response=self.client.post('/v1/tts',content=b'x'*8193,headers={**self.headers,'content-type':'application/json'})
        self.assertEqual(response.status_code,413)
        response=self.client.post('/v1/tts',content='{"voice":"serena-original","voice":"vivian-original","text":"你好。"}',
                                  headers={**self.headers,'content-type':'application/json'})
        self.assertEqual(response.status_code,400)
        self.assertFalse(self.calls)

    def test_chunked_body_limit_does_not_trust_content_length(self):
        response=self.client.post('/v1/tts',content=iter([b'x'*4096,b'x'*4097]),
                                  headers={**self.headers,'content-type':'application/json'})
        self.assertEqual(response.status_code,413);self.assertFalse(self.calls)

    def test_invalid_unicode_and_control_text_rejected_before_gpu(self):
        for text in ('\\ud800','\\u0000'):
            content='{"voice":"serena-original","text":"'+text+'"}'
            response=self.client.post('/v1/tts',content=content,headers={**self.headers,'content-type':'application/json'})
            self.assertEqual(response.status_code,400)
        self.assertFalse(self.calls)

    def test_health_voices_docs_and_cors_never_warm_gpu_or_expose_assets(self):
        response=self.client.get('/v1/voices',headers=self.headers)
        self.assertEqual(response.status_code,200)
        self.assertEqual(len(response.json()['voices']),6)
        self.assertTrue(all(set(v)=={'id','displayName','variant','speaker','instruction','fixedReferenceID'} for v in response.json()['voices']))
        self.assertNotIn('access-control-allow-origin',response.headers)
        self.assertEqual(self.client.get('/v1/health',headers=self.headers).status_code,200)
        for path in ['/docs','/redoc','/openapi.json']:
            self.assertEqual(self.client.get(path,headers=self.headers).status_code,404)
        self.assertFalse(self.calls)

    def test_legitimate_text_is_not_rewritten_and_output_hash_is_returned(self):
        text='嗯，我，我的 Wi-Fi 还没连上。'
        response=self.client.post('/v1/tts',json=dict(voice='serena-original',text=text),headers=self.headers)
        self.assertEqual(response.status_code,200)
        self.assertEqual(self.calls[0]['text'],text)
        self.assertEqual(response.headers['x-audio-sha256'],hashlib.sha256(response.content).hexdigest())
        self.assertEqual(response.headers['cache-control'],'no-store')
        self.assertNotIn(TEST_KEY,response.text)

    def test_errors_are_sanitized_and_next_request_can_proceed(self):
        attempts=0
        async def failing(voice,text,request_id):
            nonlocal attempts
            attempts+=1
            if attempts==1:raise RuntimeError('private path /secret and '+TEST_KEY+' and '+text)
            return await self.worker(voice,text,request_id)
        client=TestClient(create_api(failing,TEST_KEY))
        response=client.post('/v1/tts',json=dict(voice='serena-original',text='私人原文'),headers=self.headers)
        self.assertEqual(response.status_code,503)
        self.assertNotIn('private',response.text);self.assertNotIn(TEST_KEY,response.text);self.assertNotIn('私人原文',response.text)
        response=client.post('/v1/tts',json=dict(voice='serena-original',text='再试。'),headers=self.headers)
        self.assertEqual(response.status_code,200)

    def test_result_voice_and_audio_integrity_are_verified(self):
        async def changed(voice,text,request_id):
            result=await self.worker(voice,text,request_id);result['audio']=b'tampered'
            return result
        client=TestClient(create_api(changed,TEST_KEY))
        response=client.post('/v1/tts',json=dict(voice='serena-original',text='你好。'),headers=self.headers)
        self.assertEqual(response.status_code,503)
        self.assertNotEqual(response.content,b'tampered')

    def test_busy_and_rate_guards_are_bounded_without_dispatch(self):
        now=[0.0];guard=RequestGuard(clock=lambda:now[0])
        self.assertTrue(guard.enter());self.assertFalse(guard.enter());guard.leave()
        for _ in range(11):self.assertTrue(guard.enter());guard.leave()
        self.assertFalse(guard.enter());now[0]=61
        self.assertTrue(guard.enter());guard.leave()
        guard.active=True
        client=TestClient(create_api(self.worker,TEST_KEY,guard=guard))
        response=client.post('/v1/tts',json=dict(voice='serena-original',text='你好。'),headers=self.headers)
        self.assertEqual(response.status_code,429);self.assertFalse(self.calls)


class AudioSafetyTests(unittest.TestCase):
    def test_invalid_nonfinite_silent_token_limited_and_oversize_output_rejected(self):
        import numpy as np
        for samples,rate,frames in [(np.zeros(240),24000,[3]),(np.array([np.nan]),24000,[1]),
                (np.array([np.inf]),24000,[1]),(np.ones(240),24000,[2300]),
                (np.ones(181),1,[100]),(np.ones(2),0,[1]),(np.ones(2),24000,[])]:
            with self.assertRaises((RuntimeError,ValueError)):validated_samples(samples,rate,frames)

    def test_normalization_preserves_duration_and_creates_verifiable_pcm(self):
        import numpy as np
        samples=validated_samples(np.linspace(-1.5,1.5,24000),24000,[12])
        self.assertEqual(len(samples),24000);self.assertLessEqual(float(np.max(np.abs(samples))),.98001)
        data,sha=wav_bytes(samples,24000)
        self.assertEqual(sha,hashlib.sha256(data).hexdigest())
        with wave.open(io.BytesIO(data)) as audio:
            self.assertEqual((audio.getnframes(),audio.getframerate(),audio.getnchannels()),(24000,24000,1))


class ModelLifetimeTests(unittest.TestCase):
    def test_switching_releases_previous_model_and_caches_reference_prompt(self):
        # Tests the lifecycle boundary with model loading isolated; real L4 validation remains separate.
        loaded=[];prompt_calls=[]
        class Model:
            def __init__(self,path):
                self.path=path;self.model=mock.Mock(generate=lambda:None)
            def create_voice_clone_prompt(self,**values):
                prompt_calls.append(values);return []
        engine=object.__new__(QwenEngine)
        engine.model=engine.variant=None;engine.prompts={};engine.observed=[]
        engine.model_root=Path('/models');engine.references={'scholar-design':(Path('/fixed.wav'),'固定文字。')}
        engine.torch=mock.Mock();engine.torch.inference_mode=contextlib.nullcontext;engine.torch.bfloat16='bf16'
        def load(path,**options):
            self.assertIsNone(engine.model)
            self.assertEqual(options['attn_implementation'],'sdpa');self.assertTrue(options['local_files_only'])
            loaded.append(path);return Model(path)
        engine.model_class=mock.Mock(from_pretrained=load)
        engine._load('base');engine._load('base');engine._load('custom');engine._load('base')
        self.assertEqual([Path(p).name for p in loaded],['base','custom','base'])
        self.assertEqual(len(prompt_calls),1)
        self.assertGreaterEqual(engine.torch.cuda.empty_cache.call_count,3)


class ClientSafetyTests(unittest.TestCase):
    def test_invalid_output_does_not_spend_a_gpu_request(self):
        import modal_client
        with tempfile.TemporaryDirectory() as directory:
            for filename in ['exists.wav','invalid.mp3']:
                output=Path(directory)/filename
                if filename=='exists.wav':output.write_bytes(b'original')
                with mock.patch.object(modal_client,'request') as dispatch:
                    with self.assertRaises(modal_client.ClientError):
                        modal_client.synthesize('serena-original','你好。',output,config={})
                    dispatch.assert_not_called()

    def test_redirects_cannot_send_credentials_to_another_origin(self):
        import modal_client
        config=dict(endpoint='https://test-only.modal.run',proxyTokenID='test-id',proxyTokenSecret='test-secret',apiKey=TEST_KEY)
        fake=mock.MagicMock();fake.__enter__.return_value=fake
        response=mock.MagicMock(status_code=303,headers={'location':'https://other.invalid/result'})
        response.__enter__.return_value=response;fake.stream.return_value=response
        with mock.patch.object(modal_client.httpx,'Client',return_value=fake):
            with self.assertRaises(modal_client.ClientError):modal_client.request(config,'POST','v1/tts',body={})
        self.assertEqual(fake.stream.call_count,1)

    def test_silent_or_tampered_waveform_is_never_saved(self):
        import modal_client
        import numpy as np
        data,sha=wav_bytes(np.zeros(24000,dtype=np.float32),24000)
        headers={'content-type':'audio/wav','x-audio-sha256':sha,'x-audio-duration':'1','x-audio-sample-rate':'24000',
                 'x-model-variant':'custom','x-generation-seconds':'2','x-model-load-seconds':'3'}
        result=modal_client.HTTPResult(200,data,headers,4)
        with self.assertRaises(modal_client.ClientError):modal_client.validate_wav(result,PresetRegistry().get('serena-original'))
        result.data=b'changed'
        with self.assertRaises(modal_client.ClientError):modal_client.validate_wav(result,PresetRegistry().get('serena-original'))


if __name__=='__main__':unittest.main()
