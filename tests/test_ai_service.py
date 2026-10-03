"""API contract tests with an explicit backend double. Real GPU proof is separate."""
import hashlib
import io
import json
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import wave
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1] / "server"))
from app import Service, make_handler, validate_wav
from conversion_profiles import MODES, conversion_settings

def pcm(seconds=1):
    data = io.BytesIO()
    with wave.open(data,"wb") as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(22050)
        f.writeframes(b"\x10\x01"*int(seconds*22050))
    return data.getvalue()

class ContractBackend:
    device = "contract-test-double"
    def convert(self, source, reference, destination, settings, cancelled):
        data = source.read_bytes()
        destination.write_bytes(data)
        return {"engine":"contract-test-double", "sourceRevision":"test", "device":self.device,
                "sampleRate":22050, "duration":1, "settings":settings,
                "sha256":hashlib.sha256(data).hexdigest()}

class AIServiceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        refs = self.root / ".private/references"
        refs.mkdir(parents=True)
        (refs / "female.wav").write_bytes(pcm())
        profile = {"id":"female", "name":"测试音色", "reference":"female.wav", "referenceOrigin":"test",
                   "steps":30, "intelligibility":0.7, "similarity":0.7, "topP":0.9,
                   "temperature":0.85, "repetitionPenalty":1.0}
        (self.root / ".private/voices.json").write_text(json.dumps([profile]),encoding="utf-8")
        self.service = Service(self.root,ContractBackend)
        self.http = ThreadingHTTPServer(("127.0.0.1",0),make_handler(self.service))
        self.thread = threading.Thread(target=self.http.serve_forever,daemon=True)
        self.thread.start()
        self.base = "http://127.0.0.1:"+str(self.http.server_port)

    def tearDown(self):
        self.service.queue.join()
        self.http.shutdown(); self.http.server_close()
        self.tmp.cleanup()

    def request(self, path, method="GET", data=None, token=None):
        req = urllib.request.Request(self.base+path,data=data,method=method,
            headers={"Authorization":"Bearer "+(token or self.service.token)})
        return urllib.request.urlopen(req,timeout=5)

    def test_authentication_required(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request("/v1/voices",token="incorrect")
        self.assertEqual(caught.exception.code,401)

    def test_profiles_expose_origin_without_local_paths(self):
        with self.request("/v1/voices") as response:
            data = json.load(response)
        self.assertEqual(set(data["voices"][0]),{"id","name","referenceOrigin"})

    def test_health_supports_preserving_original_prosody(self):
        with self.request("/v1/health") as response:
            data = json.load(response)
        self.assertEqual(data["protocolVersion"],3)
        self.assertEqual(data["conversionMode"],"preserveProsody")
        self.assertEqual(data["conversionModes"],list(MODES))
        self.assertEqual(data["maxSeconds"],60)

    def test_sixty_seconds_upload_download_and_next_job_complete(self):
        for seconds in (60,31):
            data=pcm(seconds)
            with self.request("/v1/jobs?voice=female","POST",data) as response:
                key=json.load(response)["id"]
            self.service.queue.join()
            job=self.service.snapshot(key)
            self.assertEqual(job["state"],"complete")
            self.assertEqual(job["inputDuration"],seconds)
            with self.request("/v1/jobs/"+key+"/audio") as response:
                self.assertEqual(response.read(),data)

    def test_over_sixty_seconds_is_rejected_by_http_without_queueing(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request("/v1/jobs?voice=female","POST",pcm(60.1))
        self.assertEqual(caught.exception.code,400)
        self.assertEqual(self.service.jobs,{})

    def test_consecutive_jobs_complete_and_persist_separate_results(self):
        keys = []
        for duration in (0.5,1.0,1.5):
            with self.request("/v1/jobs?voice=female","POST",pcm(duration)) as response:
                keys.append(json.load(response)["id"])
            self.service.queue.join()
        self.assertEqual(len(set(keys)),3)
        for key,duration in zip(keys,(0.5,1.0,1.5)):
            job = self.service.snapshot(key)
            self.assertEqual(job["state"],"complete")
            persisted = json.loads((self.service.job_root/key/"state.json").read_text(encoding="utf-8"))
            self.assertEqual(persisted["state"],"complete")
            self.assertEqual(persisted["inputDuration"],duration)
            with self.request("/v1/jobs/"+key+"/audio") as response:
                self.assertEqual(response.read(),pcm(duration))

    def test_inference_failure_does_not_kill_worker_or_block_next_job(self):
        class RetryBackend(ContractBackend):
            attempts = 0
            def convert(self,*args):
                self.attempts += 1
                if self.attempts == 1: raise RuntimeError("controlled failure")
                return super().convert(*args)
        self.service.backend_factory = RetryBackend
        first = self.service.submit(pcm(),"female")["id"]
        self.service.queue.join()
        self.assertEqual(self.service.snapshot(first)["state"],"failed")
        second = self.service.submit(pcm(),"female")["id"]
        self.service.queue.join()
        self.assertEqual(self.service.snapshot(second)["state"],"complete")

    def test_job_result_download_hash_matches_actual_bytes(self):
        with self.request("/v1/jobs?voice=female","POST",pcm()) as response:
            self.assertEqual(response.status,202)
            key = json.load(response)["id"]
        self.service.queue.join()
        with self.request("/v1/jobs/"+key) as response:
            job = json.load(response)
        self.assertEqual(job["state"],"complete")
        with self.request("/v1/jobs/"+key+"/audio") as response:
            data = response.read(); header = response.headers["X-Audio-SHA256"]
        self.assertEqual(data,pcm())
        self.assertEqual(hashlib.sha256(data).hexdigest(),header)
        self.assertEqual(header,job["metadata"]["sha256"])

    def test_invalid_and_truncated_wav_rejected_before_queue(self):
        for data in (b"not audio",pcm()[:-8]):
            with self.assertRaises(ValueError): validate_wav(data)
        self.assertEqual(self.service.jobs,{})

    def test_long_recording_and_unknown_voice_rejected(self):
        with self.assertRaises(ValueError): validate_wav(pcm(60.1))
        with self.assertRaises(ValueError): self.service.submit(pcm(),"not-found")
        self.assertEqual(self.service.jobs,{})

    def test_cancelled_completed_job_cannot_be_downloaded(self):
        job = self.service.submit(pcm(),"female")
        self.service.queue.join()
        with self.request("/v1/jobs/"+job["id"],"DELETE") as response:
            self.assertEqual(json.load(response)["state"],"cancelled")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request("/v1/jobs/"+job["id"]+"/audio")
        self.assertEqual(caught.exception.code,409)

    def test_reference_path_escape_rejected(self):
        config = self.root / ".private/voices.json"
        profiles = json.loads(config.read_text())
        profiles[0]["reference"] = "../connection.json"
        config.write_text(json.dumps(profiles))
        with self.assertRaises(ValueError): Service(self.root,ContractBackend)

    def test_all_modes_are_submitted_and_audited_independently(self):
        for mode in MODES:
            with self.request("/v1/jobs?voice=female&mode="+mode,"POST",pcm()) as response:
                key=json.load(response)["id"]
            self.service.queue.join()
            job=self.service.snapshot(key)
            self.assertEqual(job["state"],"complete")
            self.assertEqual(job["metadata"]["conversionMode"],mode)
            self.assertEqual(job["conversionSettings"]["mode"],mode)
            self.assertEqual(job["conversionSettings"]["steps"],50 if mode=="timbrePriority" else (40 if mode=="preserveProsody" else 36))

    def test_custom_settings_reach_the_backend_and_reject_unsupported_keys(self):
        path="/v1/jobs?voice=female&mode=balancedV2&steps=48&intelligibility=1&similarity=0.55"
        with self.request(path,"POST",pcm()) as response:key=json.load(response)["id"]
        self.service.queue.join()
        settings=self.service.snapshot(key)["metadata"]["settings"]
        self.assertEqual(settings["steps"],48)
        self.assertEqual(settings["intelligibility"],1)
        self.assertEqual(settings["similarity"],0.55)
        for query in ("mode=unknown","mode=naturalSpeech&similarity=1","mode=balancedV2&steps=nan",
                      "mode=balancedV2&steps=40.5","mode=preserveProsody&pitchShift=7",
                      "mode=timbrePriority&temperature=5","mode=naturalSpeech&steps=40&steps=41"):
            with self.assertRaises(urllib.error.HTTPError) as caught:self.request("/v1/jobs?voice=female&"+query,"POST",pcm())
            self.assertEqual(caught.exception.code,400)

    def test_recommended_quality_settings_and_custom_profiles_validate(self):
        settings=conversion_settings({},"timbrePriority")
        self.assertEqual(settings["steps"],50)
        self.assertEqual(settings["intelligibility"],1)
        with self.assertRaises(ValueError):conversion_settings({"modes":{"timbrePriority":{"temperature":float("nan")}}},"timbrePriority")
        with self.assertRaises(ValueError):conversion_settings({"modes":{"naturalSpeech":{"extra":1}}},"naturalSpeech")

if __name__ == "__main__": unittest.main()
