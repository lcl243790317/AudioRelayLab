# SPDX-License-Identifier: GPL-3.0-only
"""Optional private Modal backend; local and iOS backends are unchanged."""
import hashlib
import json
import os
from pathlib import Path
import modal

ROOT = Path(__file__).resolve().parent
APP_NAME = 'audiorelaylab-qwen'
VOLUME_NAME = 'audiorelaylab-qwen-assets'
SECRET_NAME = 'audiorelaylab-api-prod'
LOCK = json.loads((ROOT/'revoice-lock.json').read_text(encoding='utf-8'))
MODEL_RELEASE = hashlib.sha256((ROOT/'revoice-lock.json').read_bytes()).hexdigest()[:16]
REFERENCE_RELEASE = hashlib.sha256((ROOT/'revoice-references.json').read_bytes()).hexdigest()[:16]
MODEL_ROOT = '/assets/models/'+MODEL_RELEASE
REFERENCE_ROOT = '/assets/references/'+REFERENCE_RELEASE
GPU_SNAPSHOT = os.environ.get('AUDIOLAB_GPU_SNAPSHOT', '0') == '1'
SOURCE_FILES = ['revoice-lock.json','revoice-palette.json','revoice-audition-cases.json','revoice-review.json',
                'revoice-references.json','revoice_registry.py','revoice_contract.py','revoice_audio.py',
                'modal_api.py','modal_jobs.py','modal_engine.py','modal_app.py','setup_revoice_audition.py',
                'modal-inference-requirements.txt']
GPU_PINS = [line.strip() for line in (ROOT/'modal-inference-requirements.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')]


def with_source(image):
    # Exact allowlist; never mount the workspace, .private, models or audition recordings.
    for name in SOURCE_FILES:
        image = image.add_local_file(ROOT/name, '/opt/audiolab/'+name, copy=True)
    # Module globals are imported again inside remote containers; persist the selected deployment mode.
    return image.env({'PYTHONPATH':'/opt/audiolab', 'AUDIOLAB_GPU_SNAPSHOT':'1' if GPU_SNAPSHOT else '0'})


cpu_image = with_source(modal.Image.debian_slim(python_version='3.12')
                        .pip_install('modal==1.6.1','fastapi==0.142.2','pydantic==2.13.5','starlette==1.7.0'))
gpu_image = with_source(
    modal.Image.debian_slim(python_version='3.12')
    .apt_install('libsndfile1','ffmpeg','sox')
    .pip_install('torch=='+LOCK['inheritedRuntime']['torch'], 'torchaudio=='+LOCK['inheritedRuntime']['torch'],
                 index_url='https://download.pytorch.org/whl/cu124')
    .pip_install(*GPU_PINS, extra_options='--no-deps')
).env({'HF_HUB_OFFLINE':'1','TRANSFORMERS_OFFLINE':'1','TOKENIZERS_PARALLELISM':'false'})
assets = modal.Volume.from_name(VOLUME_NAME, create_if_missing=True)
job_states = modal.Dict.from_name(APP_NAME+'-jobs-v1',create_if_missing=True)
results = modal.Volume.from_name(APP_NAME+'-results-v1',create_if_missing=True)
app = modal.App(APP_NAME)


def job_service(mounted=False):
    from modal_jobs import JobService
    return JobService(job_states,'/results/audio',os.environ['AUDIOLAB_API_KEY'],
                      commit=results.commit if mounted else lambda: None,
                      reload=results.reload if mounted else lambda: None)


@app.function(image=cpu_image,secrets=[modal.Secret.from_name(SECRET_NAME)],volumes={'/results':results},
              cpu=.25,memory=512,timeout=1050,scaledown_window=75,
              min_containers=0,max_containers=1,buffer_containers=0,retries=0,include_source=False)
@modal.concurrent(max_inputs=1)
async def execute_job(identity):
    async def invoke(payload,request_id):
        custom = {'speaker':payload['speaker'],'instruction':payload['instruction']} if payload['mode']=='custom' else None
        return await QwenWorker().synthesize.remote.aio(payload['voice'],payload['text'],request_id,custom=custom)
    return await job_service(mounted=True).execute(identity,invoke)


@app.function(image=cpu_image,secrets=[modal.Secret.from_name(SECRET_NAME)],volumes={'/results':results},
              cpu=.25,memory=512,timeout=150,scaledown_window=75,
              min_containers=0,max_containers=1,buffer_containers=0,include_source=False)
@modal.concurrent(max_inputs=16)
@modal.asgi_app(requires_proxy_auth=False)
def download():
    # Read-only, job-specific HMAC credential. Never accepts a generation request
    # or the application's long-lived credentials.
    from modal_jobs import create_download_api
    return create_download_api(job_service(mounted=True))


@app.function(image=cpu_image,secrets=[modal.Secret.from_name(SECRET_NAME)],volumes={'/results':results},
              cpu=.25,memory=512,timeout=60,scaledown_window=10,
              min_containers=0,max_containers=1,buffer_containers=0,schedule=modal.Period(hours=1),include_source=False)
def cleanup_jobs():
    return job_service(mounted=True).cleanup()


@app.function(image=cpu_image, volumes={'/assets':assets}, cpu=2, memory=2048, timeout=1800,
              min_containers=0, max_containers=1, buffer_containers=0, scaledown_window=10, include_source=False)
def prepare_models():
    """Explicit CPU-only initialization. Never called by the HTTP or GPU request path."""
    import shutil
    from revoice_registry import PresetRegistry, digest
    from setup_revoice_audition import download
    registry = PresetRegistry()
    cache = Path('/assets/blobs'); cache.mkdir(parents=True, exist_ok=True)
    for variant in registry.required_variants():
        pinned = registry.lock['models'][variant]
        for item in pinned['files']:
            target = Path(MODEL_ROOT)/variant/item['path']
            if target.exists():
                if target.stat().st_size != item['bytes'] or digest(target) != item['sha256']:
                    raise RuntimeError('Existing model does not match the pinned identity')
                continue
            blob = download(pinned['repository'], pinned['revision'], item, cache)
            target.parent.mkdir(parents=True, exist_ok=True)
            try:
                os.link(blob, target)
            except OSError:
                shutil.copy2(blob, target)
    assets.commit()
    return {'variants':registry.required_variants(), 'status':'pinned assets verified'}


@app.cls(image=gpu_image, gpu='L4', cpu=2, memory=12288, volumes={'/assets':assets},
         min_containers=0, max_containers=1, buffer_containers=0, scaledown_window=75,
         enable_memory_snapshot=GPU_SNAPSHOT,
         experimental_options={'enable_gpu_snapshot': True} if GPU_SNAPSHOT else None,
         timeout=660, startup_timeout=300, retries=0, block_network=True, include_source=False)
@modal.concurrent(max_inputs=1)
class QwenWorker:
    # No modal.parameter: all presets share this single GPU autoscaling pool.
    @modal.enter(snap=GPU_SNAPSHOT)
    def initialize(self):
        from modal_engine import QwenEngine
        self.engine = QwenEngine(MODEL_ROOT, REFERENCE_ROOT)
        if GPU_SNAPSHOT:
            self.engine.prepare_snapshot()

    @modal.enter(snap=False)
    def restore(self):
        self.engine.reset_session()
        print(json.dumps(dict(event='qwen_ready', sessionID=self.engine.session_id,
                              snapshotMarker=self.engine.snapshot_marker,
                              initializationPeakAllocatedBytes=self.engine.initialization_peak)), flush=True)

    @modal.method()
    def synthesize(self, voice, text, request_id, custom=None):
        import logging
        try:
            if custom is not None:
                if voice != 'custom':
                    raise ValueError('Custom route mismatch')
                return self.engine.synthesize_custom(custom['speaker'], text, custom['instruction'], request_id)
            return self.engine.synthesize(voice, text, request_id)
        except Exception as error:
            self.engine.unload()
            logging.getLogger('audiorelaylab.gpu').warning(json.dumps(dict(requestID=request_id,
                status='failed', errorType=type(error).__name__)))
            raise RuntimeError('Generation failed') from None


@app.function(image=cpu_image, secrets=[modal.Secret.from_name(SECRET_NAME)], cpu=.25, memory=512,
              min_containers=0, max_containers=1, buffer_containers=0, scaledown_window=75,
              timeout=900, include_source=False)
@modal.concurrent(max_inputs=16)
@modal.asgi_app(requires_proxy_auth=True)
def api():
    from modal_api import create_api
    async def invoke(voice, text, request_id):
        return await QwenWorker().synthesize.remote.aio(voice, text, request_id)
    async def invoke_custom(speaker, text, instruction, request_id):
        return await QwenWorker().synthesize.remote.aio('custom', text, request_id,
                                                    custom={'speaker': speaker, 'instruction': instruction})
    # Missing secret fails startup. No fallback and no credential in source.
    from modal_jobs import LegacyJobGuard
    jobs = job_service()
    async def enqueue(identity):
        await execute_job.spawn.aio(identity)
    return create_api(invoke,os.environ['AUDIOLAB_API_KEY'],custom_worker=invoke_custom,
                      jobs=jobs,enqueue=enqueue,download_origin=download.get_web_url(),guard=LegacyJobGuard(jobs))
