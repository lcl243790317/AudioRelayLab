import hashlib
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'server'))
from fastapi.testclient import TestClient
from modal_api import create_api
from modal_engine import QwenEngine
from revoice_registry import PresetRegistry
from revoice_contract import synthesis_arguments

class PresetInstructionTests(unittest.TestCase):
    def setUp(self):
        self.registry=PresetRegistry(); self.calls=[]
        async def worker(voice,text,identity,instruction=None):
            self.calls.append((voice,text,instruction))
            data=b'test audio'; preset=self.registry.get(voice)
            return dict(audio=data,metadata=dict(voice=voice,speaker=preset.speaker or '',
                sha256=hashlib.sha256(data).hexdigest(),sampleRate=24000,outputDuration=1,
                generationSeconds=1,modelLoadSeconds=0,sessionID='test'))
        self.key='test-preset-instruction-only-0000000000000'
        self.client=TestClient(create_api(worker,self.key))
        self.headers={'X-AudioRelay-Key':self.key}
    def test_catalog_supports_four_custom_presets_and_two_fixed_references(self):
        voices=self.client.get('/v1/voices',headers=self.headers).json()['voices']
        self.assertEqual({v['id'] for v in voices if v['supportsInstruction']},
            {'serena-original','vivian-original','ancient-dylan','cool-serena'})
        self.assertEqual(len(voices),6)
        self.assertTrue(self.client.get('/v1/health',headers=self.headers).json()['capabilities']['presetInstruction'])
        self.assertFalse(self.calls)
    def test_sync_default_explicit_empty_and_exact_instruction(self):
        for override in (None,'','  轻声，放松。\n清楚咬字。  '):
            body=dict(voice='serena-original',text='嗯，我，我没连 Wi-Fi。')
            if override is not None: body['instruction']=override
            response=self.client.post('/v1/tts',json=body,headers=self.headers)
            self.assertEqual(response.status_code,200,response.text)
            self.assertEqual(self.calls[-1],(body['voice'],body['text'],override))
            self.assertEqual(response.headers['x-voice-id'],'serena-original')
            self.assertEqual(response.headers['x-generation-mode'],'preset')
    def test_engine_receives_text_and_target_parameters_only(self):
        engine=object.__new__(QwenEngine); engine.registry=self.registry
        engine._generate=mock.Mock(return_value='ok')
        for voice in ('serena-original','vivian-original','ancient-dylan','cool-serena'):
            for instruction in ('','  自然慵懒。  '):
                engine.synthesize(voice,'嗯，我，我明天去。','request',instruction=instruction)
                args=engine._generate.call_args.args
                task=args[2]; self.assertEqual(task['instruction'],instruction)
                synth=synthesis_arguments('custom',task)
                self.assertEqual(synth['instruct'],instruction)
                self.assertEqual(synth['speaker'],self.registry.get(voice).speaker)
                self.assertFalse({'ref_audio','f0','source_audio','duration'} & set(synth))
    def test_base_override_and_bad_inputs_rejected_before_gpu(self):
        for voice,instruction in (('scholar-design',''),('cute-design','柔和'),('serena-original',None),
                                  ('serena-original','x'*501),('serena-original','bad\x00')):
            response=self.client.post('/v1/tts',json=dict(voice=voice,text='你好。',instruction=instruction),headers=self.headers)
            self.assertEqual(response.status_code,400)
        self.assertFalse(self.calls)
