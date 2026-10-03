import sys
import unittest
import json
import tempfile
from unittest import mock
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'server'))
import evaluate_revoice
from revoice_contract import synthesis_arguments,text_for_synthesis,validate_input_duration,validate_output_duration

class RevoiceContractTests(unittest.TestCase):
    def test_source_voice_and_timing_cannot_enter_custom_synthesis(self):
        for speaker in ('Serena','Vivian','Dylan','Uncle_Fu'):
            with self.subTest(speaker=speaker):
                task=dict(text='嗯，我，我想先休息一下。',speaker=speaker,instruction='自然说话')
                changed=dict(task,sourceAudio='another.wav',sourceF0=70,inputDuration=50,sourceSpeaker='male',rate=2)
                self.assertEqual(synthesis_arguments('custom',task),synthesis_arguments('custom',changed))
                self.assertEqual(set(synthesis_arguments('custom',changed)),{'text','language','non_streaming_mode','speaker','instruct'})

    def test_repetitions_and_spoken_words_are_not_rewritten(self):
        self.assertEqual(text_for_synthesis('嗯，嗯，我，我的 Wi-Fi 还没连上。'),'嗯，嗯，我，我的 Wi-Fi 还没连上。')

    def test_output_is_independent_of_the_sixty_second_input_limit(self):
        validate_input_duration(60);validate_output_duration(80);validate_output_duration(180)
        for seconds in (60.01,0.29,float('nan')):
            with self.assertRaises(ValueError):validate_input_duration(seconds)
        for seconds in (180.01,0,float('inf')):
            with self.assertRaises(ValueError):validate_output_duration(seconds)

    def test_fixed_target_prompt_is_required_and_source_fields_are_ignored(self):
        task=dict(text='明天见。',sourceAudio='my-voice.wav',sourceTiming=[1,2])
        with self.assertRaises(ValueError):synthesis_arguments('base',task)
        prompt=object()
        result=synthesis_arguments('base',task,prompt)
        self.assertIs(result['voice_clone_prompt'],prompt)
        self.assertEqual(set(result),{'text','language','non_streaming_mode','voice_clone_prompt'})

    def test_empty_and_oversized_text_never_get_truncated(self):
        self.assertEqual(len(text_for_synthesis('字'*1000)),1000)
        for text in ('字'*1001,' ',None):
            with self.assertRaises(ValueError):text_for_synthesis(text)

    def test_unknown_voice_is_rejected(self):
        with self.assertRaises(ValueError):synthesis_arguments('custom',dict(text='你好。',speaker='old-rvc'))

    def test_corrected_text_skips_recognition_and_does_not_forward_an_audio_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            seen=[]
            def worker(arguments,log):
                seen.append(arguments)
                self.assertEqual(arguments[0],'tts')
                self.assertNotIn('--input',arguments)
                task=json.loads(Path(arguments[arguments.index('--tasks')+1]).read_text())[0]
                self.assertEqual(task['text'],'嗯，我，我想明天再去。')
                output=Path(arguments[arguments.index('--output')+1])
                (output/'result.wav').write_bytes(b'validated fake worker result')
                (output/'result.json').write_text(json.dumps(dict(sha256=evaluate_revoice.digest(output/'result.wav'))))
            with mock.patch.object(evaluate_revoice,'RUNTIME',folder/'runtime'),mock.patch.object(evaluate_revoice,'PYTHON',Path(__file__)),mock.patch.object(evaluate_revoice,'run_worker',worker):
                report=evaluate_revoice.evaluate(None,'嗯，我，我想明天再去。','Serena',folder/'corrected.wav')
            self.assertEqual(len(seen),1)
            self.assertIsNone(report['recognition'])
            self.assertFalse(report['sourceFileProvidedToTTS'])
            self.assertTrue((folder/'corrected.wav').exists())

    def test_worker_failure_never_publishes_partial_audio(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            with mock.patch.object(evaluate_revoice,'RUNTIME',folder/'runtime'),mock.patch.object(evaluate_revoice,'PYTHON',Path(__file__)),mock.patch.object(evaluate_revoice,'run_worker',side_effect=RuntimeError('failed before complete')):
                with self.assertRaises(RuntimeError):evaluate_revoice.evaluate(None,'你好。','Vivian',folder/'failed.wav')
            self.assertFalse((folder/'failed.wav').exists())
            self.assertFalse((folder/'failed.json').exists())

    def test_concurrent_output_is_not_overwritten_or_deleted(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp);target=folder/'concurrent.wav'
            def worker(arguments,log):
                output=Path(arguments[arguments.index('--output')+1])
                (output/'result.wav').write_bytes(b'model output')
                (output/'result.json').write_text(json.dumps(dict(sha256=evaluate_revoice.digest(output/'result.wav'))))
                target.write_bytes(b'other writer original file')
            with mock.patch.object(evaluate_revoice,'RUNTIME',folder/'runtime'),mock.patch.object(evaluate_revoice,'PYTHON',Path(__file__)),mock.patch.object(evaluate_revoice,'run_worker',worker):
                with self.assertRaises(FileExistsError):evaluate_revoice.evaluate(None,'你好。','Serena',target)
            self.assertEqual(target.read_bytes(),b'other writer original file')

if __name__=='__main__':unittest.main()
