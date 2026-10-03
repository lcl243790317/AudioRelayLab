# SPDX-License-Identifier: GPL-3.0-only
"""Authenticated LAN API. The phone sends a selected recording only on Generate."""
import argparse
import hashlib
import hmac
import io
import json
import logging
import os
import queue
import secrets
import threading
import time
import uuid
import wave
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
from conversion_profiles import MODES, conversion_settings

ROOT = Path(__file__).resolve().parent
MAX_BYTES = 16 * 1024 * 1024
MAX_SECONDS = 60
LOG = logging.getLogger("AudioRelayLab.AI")

def event(name, **fields):
    LOG.info(json.dumps(dict(event=name, **fields), ensure_ascii=False))

def validate_wav(data):
    try:
        with wave.open(io.BytesIO(data), "rb") as f:
            rate, frames = f.getframerate(), f.getnframes()
            if f.getnchannels() != 1 or f.getsampwidth() != 2 or not 8000 <= rate <= 48000:
                raise ValueError("需要 8–48 kHz 单声道 16-bit PCM WAV")
            duration = frames / rate
            if not 0.3 <= duration <= MAX_SECONDS:
                raise ValueError("请使用 0.3–60 秒的纯人声录音")
            if len(f.readframes(frames)) != frames * 2:
                raise ValueError("WAV 文件不完整")
            return duration
    except (wave.Error, EOFError) as error:
        raise ValueError("无法读取 PCM WAV") from error

def load_profiles(root):
    profiles = json.loads((root / ".private/voices.json").read_text(encoding="utf-8-sig"))
    refs = (root / ".private/references").resolve()
    result = {}
    for profile in profiles:
        reference = (refs / profile["reference"]).resolve()
        if reference.parent != refs or not reference.is_file():
            raise ValueError("音色参考路径无效")
        validate_wav(reference.read_bytes())
        result[profile["id"]] = dict(profile, referencePath=reference)
    if not result:
        raise ValueError("请先配置至少一个真实参考音色")
    return result

class Service:
    def __init__(self, root=ROOT, backend_factory=None):
        self.root = Path(root)
        self.profiles = load_profiles(self.root)
        self.job_root = self.root / ".runtime/jobs"
        self.job_root.mkdir(parents=True, exist_ok=True)
        connection = self.root / ".private/connection.json"
        if connection.exists():
            self.token = json.loads(connection.read_text())["token"]
        else:
            self.token = secrets.token_urlsafe(32)
            connection.write_text(json.dumps({"token":self.token}), encoding="utf-8")
        self.jobs = {}
        self.lock = threading.RLock()
        self.queue = queue.Queue(maxsize=4)
        self.backend = None
        self.model_state = "notLoaded"
        self.backend_factory = backend_factory
        threading.Thread(target=self.work, daemon=True).start()

    def public_profile(self, profile):
        return {k:profile[k] for k in ("id", "name", "referenceOrigin")}

    def submit(self, data, voice, mode="preserveProsody", overrides=None):
        if voice not in self.profiles:
            raise ValueError("请选择服务器提供的音色")
        duration = validate_wav(data)
        settings = conversion_settings(self.profiles[voice], mode, overrides)
        with self.lock:
            if self.queue.full():
                raise ValueError("服务器队列已满，请稍后重试")
            # A bounded in-memory job index. Old audio remains local; no arbitrary path removal.
            if len(self.jobs) >= 128:
                finished = [k for k,v in self.jobs.items() if v.get("workerDone")]
                if not finished:
                    raise ValueError("服务器繁忙")
                del self.jobs[finished[0]]
            key = str(uuid.uuid4())
            folder = self.job_root / key
            folder.mkdir()
            source = folder / "source.wav"
            source.write_bytes(data)
            job = {"id":key, "state":"queued", "message":"等待电脑转换", "voiceID":voice,
                   "inputDuration":duration, "conversionMode":mode, "conversionSettings":settings,
                   "created":time.time(), "cancel":threading.Event(),
                   "folder":folder, "workerDone":False}
            self.jobs[key] = job
            self.queue.put_nowait(key)
            self.persist(key)
            event("submitted", job=key, voice=voice, mode=mode, duration=duration)
            return self.snapshot(key)

    def snapshot(self, key):
        with self.lock:
            if key not in self.jobs:
                raise KeyError(key)
            return {k:v for k,v in self.jobs[key].items() if k not in ("cancel", "folder", "workerDone")}

    def persist(self, key):
        with self.lock:
            job = self.jobs[key]
            target = job["folder"] / "state.json"
            temporary = target.with_suffix(".tmp")
            temporary.write_text(json.dumps(self.snapshot(key), ensure_ascii=False, indent=2), encoding="utf-8")
            temporary.replace(target)

    def update(self, key, **fields):
        with self.lock:
            job = self.jobs[key]
            if job["cancel"].is_set() and fields.get("state") != "cancelled":
                return
            job.update(fields)
            self.persist(key)
            event("state", job=key, state=job["state"])

    def cancel(self, key):
        with self.lock:
            job = self.jobs[key]
            job["cancel"].set()
            job.update(state="cancelled", message="已取消；运行中的模型步骤会在结束后丢弃输出")
            self.persist(key)
            event("cancelled", job=key)

    def work(self):
        while True:
            key = self.queue.get()
            with self.lock:
                job = self.jobs.get(key)
            if job is None:
                self.queue.task_done()
                continue
            try:
                if job["cancel"].is_set():
                    continue
                if self.backend is None:
                    self.model_state = "loading"
                    self.update(key, state="loading", message="首次加载 AI 模型，需要下载权重")
                    factory = self.backend_factory
                    if factory is None:
                        from seed_backend import SeedBackend
                        factory = SeedBackend
                    self.backend = factory()
                    self.model_state = "ready"
                if job["cancel"].is_set():
                    continue
                profile = self.profiles[job["voiceID"]]
                before = time.perf_counter()
                settings = job["conversionSettings"]
                prepare = getattr(self.backend, "prepare", None)
                if prepare is not None:
                    self.model_state = "loading"
                    self.update(key, state="loading", message="正在加载所选 AI 模型；切换模型需要稍等")
                    prepare(settings, job["cancel"])
                    self.model_state = "ready"
                self.update(key, state="converting", message="正在生成目标音色，保留原话")
                metadata = self.backend.convert(job["folder"] / "source.wav", profile["referencePath"],
                                                job["folder"] / "output.wav", settings, job["cancel"])
                metadata.update(conversionSeconds=time.perf_counter()-before,
                                voiceID=profile["id"], voiceName=profile["name"], referenceOrigin=profile["referenceOrigin"],
                                conversionMode=job["conversionMode"])
                if not job["cancel"].is_set():
                    self.update(key, state="complete", message="转换完成", metadata=metadata)
            except InterruptedError:
                self.update(key, state="cancelled", message="已取消")
            except Exception as error:
                if self.backend is None or getattr(self.backend, "models", True) is None:
                    self.model_state = "failed"
                if not job["cancel"].is_set():
                    self.update(key, state="failed", message="电脑 AI 推理失败，可直接重试。错误类型：" + type(error).__name__)
                LOG.error("job=%s inference failed\n%s", key, traceback.format_exc())
            finally:
                with self.lock:
                    job["workerDone"] = True
                self.queue.task_done()

def make_handler(service):
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(30)

        def log_message(self, *args):
            pass

        def respond(self, status, body, content_type="application/json", sha=None):
            data = json.dumps(body, ensure_ascii=False).encode() if content_type == "application/json" else body
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            if sha:
                self.send_header("X-Audio-SHA256", sha)
            self.end_headers()
            self.wfile.write(data)

        def handle_request(self):
            if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + service.token):
                self.respond(401, {"message":"连接密钥不正确"})
                return
            parsed = urlsplit(self.path)
            parts = parsed.path.strip("/").split("/")
            try:
                if self.command == "GET" and parsed.path == "/v1/health":
                    self.respond(200, {"engine":getattr(service.backend,"engine","Seed-VC V1 / V2 / F0"), "modelState":service.model_state,
                                       "protocolVersion":3, "conversionMode":"preserveProsody", "conversionModes":list(MODES),
                                       "processID":os.getpid(),
                                       "maxSeconds":MAX_SECONDS, "device":str(service.backend.device) if service.backend else "pending"})
                elif self.command == "GET" and parsed.path == "/v1/voices":
                    self.respond(200, {"voices":[service.public_profile(p) for p in service.profiles.values()]})
                elif self.command == "POST" and parsed.path == "/v1/jobs":
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 44 <= length <= MAX_BYTES:
                        raise ValueError("上传文件大小无效")
                    data = self.rfile.read(length)
                    if len(data) != length:
                        raise ValueError("录音上传未完成")
                    query = parse_qs(parsed.query, keep_blank_values=True)
                    if any(len(v) != 1 for v in query.values()) or set(query)-{"voice","mode","steps","intelligibility","similarity","pitchShift"}:
                        raise ValueError("AI 请求包含未知或重复参数")
                    voice = query.get("voice", [""])[0]
                    mode = query.get("mode", ["preserveProsody"])[0]
                    overrides = {k:v[0] for k,v in query.items() if k not in ("voice","mode")}
                    self.respond(202, service.submit(data, voice, mode, overrides))
                elif len(parts) in (3,4) and parts[:2] == ["v1","jobs"]:
                    key = parts[2]
                    if str(uuid.UUID(key)) != key:
                        raise ValueError("任务编号无效")
                    if self.command == "DELETE" and len(parts) == 3:
                        service.cancel(key)
                        self.respond(200, service.snapshot(key))
                    elif self.command == "GET" and len(parts) == 3:
                        self.respond(200, service.snapshot(key))
                    elif self.command == "GET" and parts[3:] == ["audio"]:
                        job = service.snapshot(key)
                        if job["state"] != "complete":
                            self.respond(409, {"message":"转换尚未完成"})
                        else:
                            data = (service.job_root / key / "output.wav").read_bytes()
                            self.respond(200, data, "audio/wav", hashlib.sha256(data).hexdigest())
                    else:
                        self.respond(404, {"message":"接口不存在"})
                else:
                    self.respond(404, {"message":"接口不存在"})
            except KeyError:
                self.respond(404, {"message":"任务不存在或电脑服务已重启，请用当前原声重新生成"})
            except (ValueError, OSError) as error:
                self.respond(400, {"message":str(error)[:1000]})

        do_GET = handle_request
        do_POST = handle_request
        do_DELETE = handle_request
    return Handler

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", stream=__import__("sys").stdout)
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=7867)
    args = parser.parse_args()
    service = Service()
    server = ThreadingHTTPServer((args.host,args.port), make_handler(service))
    (ROOT / ".private/listener-pid.txt").write_text(str(os.getpid()),encoding="ascii")
    from process_identity import save_identity
    save_identity(ROOT / ".private/server-process.json")
    print("AudioRelayLab AI service ready; model loads on first job. Port", args.port, flush=True)
    server.serve_forever()
