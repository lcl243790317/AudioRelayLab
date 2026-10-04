import hashlib
import json
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'server'))
from fastapi.testclient import TestClient
from modal_api import create_api, validate_custom_request, RequestGuard
from modal_engine import QwenEngine
from revoice_contract import SPEAKERS, custom_task, synthesis_arguments

KEY = 'unit-test-only-application-key-000000000000'


class CustomCloudTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        async def preset(voice, text, request_id):
            raise AssertionError('Custom requests cannot enter the preset worker')
        async def custom(speaker, text, instruction, request_id):
            self.calls.append((speaker, text, instruction))
            data = b'test audio'
            return dict(audio=data, metadata=dict(voice='custom',speaker=speaker,sha256=hashlib.sha256(data).hexdigest(),
                sampleRate=24000,outputDuration=1.0,generationSeconds=1.2,modelLoadSeconds=0,sessionID='unit-session'))
        self.worker = custom
        self.client = TestClient(create_api(preset, KEY, custom_worker=custom))
        self.headers = {'X-AudioRelay-Key': KEY}

    def test_all_nine_speakers_are_cpu_discovered_and_supported_by_contract(self):
        response = self.client.get('/v1/speakers',headers=self.headers)
        self.assertEqual({s['id'] for s in response.json()['speakers']},set(SPEAKERS))
        self.assertEqual(len(response.json()['speakers']),9)
        self.assertFalse(self.calls)
        for speaker in SPEAKERS:
            task = custom_task(speaker,'嗯，我，我还没有连上 Wi-Fi。','  放松一点。  ')
            result = synthesis_arguments('custom',task)
            self.assertEqual(result['language'],'Auto')
            self.assertEqual(result['speaker'],speaker)
            self.assertEqual(result['instruct'],'  放松一点。  ')
            self.assertNotIn('ref_audio',result)

    def test_custom_request_preserves_text_and_instruction_and_returns_route_headers(self):
        for speaker in SPEAKERS:
            response = self.client.post('/v1/tts/custom',json=dict(speaker=speaker,text='嗯，我，我想明天去。',instruction='  自然、慢一点。  '),headers=self.headers)
            self.assertEqual(response.status_code,200)
            self.assertEqual(self.calls[-1],(speaker,'嗯，我，我想明天去。','  自然、慢一点。  '))
            self.assertEqual(response.headers['x-speaker-id'],speaker)
            self.assertEqual(response.headers['x-generation-mode'],'custom')
            self.assertEqual(response.headers['x-voice-id'],'custom')
            self.assertEqual(len(response.headers['x-model-revision']),40)

    def test_empty_instruction_is_optional_and_never_inherits_a_preset(self):
        response = self.client.post('/v1/tts/custom',json=dict(speaker='Serena',text='你好。'),headers=self.headers)
        self.assertEqual(response.status_code,200)
        self.assertEqual(self.calls[0][2],'')

    def test_bad_custom_inputs_never_dispatch_gpu(self):
        valid = dict(speaker='Serena',text='你好。')
        bad = [valid | {'speaker':'../../model'},valid | {'speaker':'serena'},valid | {'speaker':None},
               valid | {'instruction':'字'*501},valid | {'instruction':None},valid | {'instruction':'\x00'},
               valid | {'instruction':'\ud800'},valid | {'text':' '},valid | {'text':'字'*1001},
               valid | {'reference':'http://example.invalid'},valid | {'voice':'scholar-design'},
               valid | {'audio':'source.wav'},valid | {'language':'Chinese'},[],None]
        for body in bad:
            response = self.client.post('/v1/tts/custom',content=json.dumps(body).encode(),headers=self.headers | {'content-type':'application/json'})
            self.assertIn(response.status_code,[400,413])
        self.assertFalse(self.calls)

    def test_auth_and_duplicate_json_fields_are_rejected(self):
        body = dict(speaker='Serena',text='你好。')
        self.assertEqual(self.client.post('/v1/tts/custom',json=body).status_code,403)
        response = self.client.post('/v1/tts/custom',content='{"speaker":"Serena","speaker":"Vivian","text":"你好。"}',
                                    headers=self.headers | {'content-type':'application/json'})
        self.assertEqual(response.status_code,400);self.assertFalse(self.calls)

    def test_custom_and_preset_share_one_request_gate(self):
        guard = RequestGuard();guard.active = True
        client = TestClient(create_api(mock.AsyncMock(),KEY,guard=guard,custom_worker=self.worker))
        for path,body in [('/v1/tts',dict(voice='serena-original',text='你好。')),
                          ('/v1/tts/custom',dict(speaker='Serena',text='你好。'))]:
            self.assertEqual(client.post(path,json=body,headers=self.headers).status_code,429)
        self.assertFalse(self.calls)

    def test_worker_route_tampering_fails_without_publishing(self):
        async def worker(*args):
            result = await self.worker(*args);result['metadata']['speaker'] = 'Vivian';return result
        client = TestClient(create_api(mock.AsyncMock(),KEY,custom_worker=worker))
        self.assertEqual(client.post('/v1/tts/custom',json=dict(speaker='Serena',text='你好。'),headers=self.headers).status_code,503)

    def test_capabilities_report_old_cloud_compatibility_without_gpu(self):
        modern = self.client.get('/v1/health',headers=self.headers).json()
        self.assertTrue(modern['capabilities']['customTTS']);self.assertTrue(modern['capabilities']['textOnly'])
        legacy = TestClient(create_api(mock.AsyncMock(),KEY)).get('/v1/health',headers=self.headers).json()
        self.assertFalse(legacy['capabilities']['customTTS']);self.assertFalse(self.calls)


class SnapshotStateTests(unittest.TestCase):
    def test_restore_changes_session_and_counters_but_retains_target_cache_marker(self):
        engine = object.__new__(QwenEngine)
        engine.session_id='captured-session';engine.generations=42;engine.observed=[4]
        engine.gpu_name='NVIDIA L4';engine.torch=mock.Mock();engine.torch.cuda.get_device_name.return_value='NVIDIA L4'
        engine.registry=mock.Mock();engine.registry.presets={};engine.snapshot_marker='one-snapshot'
        engine.reset_session();first=engine.session_id;engine.reset_session()
        self.assertNotEqual(first,engine.session_id);self.assertNotEqual(first,'captured-session')
        self.assertEqual(engine.generations,0);self.assertEqual(engine.observed,[])
        self.assertEqual(engine.snapshot_marker,'one-snapshot')

    def test_capture_prepares_base_prompts_then_releases_base_before_custom_warmup(self):
        engine = object.__new__(QwenEngine);calls=[]
        engine._load=lambda variant:calls.append(variant)
        engine.load_peak_bytes=100;engine.torch=mock.Mock();engine.torch.cuda.max_memory_allocated.return_value=200
        engine.synthesize_custom=mock.Mock();engine.reset_session=mock.Mock()
        engine.prepare_snapshot()
        self.assertEqual(calls,['base','custom'])
        self.assertEqual(engine.initialization_peak,200)
        engine.synthesize_custom.assert_called_once_with('Serena','你好，我们开始吧。','','snapshot-warmup')
        engine.reset_session.assert_called_once();self.assertEqual(len(engine.snapshot_marker),32)

    def test_deployment_keeps_one_unparameterized_l4_pool_and_75_second_window(self):
        source=(Path(__file__).resolve().parents[1]/'server/modal_app.py').read_text(encoding='utf-8')
        gpu = source[source.index('@app.cls('):source.index('class QwenWorker:')]
        self.assertIn('scaledown_window=75',gpu)
        self.assertIn('min_containers=0',gpu); self.assertIn('max_containers=1',gpu)
        self.assertIn('buffer_containers=0',gpu)
        self.assertEqual(source.count("gpu='L4'"),1)
        self.assertIn("gpu='L4'",source);self.assertNotIn('@modal.parameter',source)
        self.assertIn('enable_memory_snapshot=GPU_SNAPSHOT',source)
        self.assertIn("'AUDIOLAB_GPU_SNAPSHOT':'1' if GPU_SNAPSHOT else '0'",source)
        self.assertIn('max_inputs=1',source);self.assertIn('retries=0',source)


if __name__ == '__main__':unittest.main()
