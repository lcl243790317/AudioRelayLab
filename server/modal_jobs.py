# SPDX-License-Identifier: GPL-3.0-only
"""Durable CPU-only jobs. This module never imports the inference runtime."""
import asyncio
import copy
import hashlib
import hmac
import io
import json
from pathlib import Path
import re
import threading
import time
import uuid
import wave

RETENTION_SECONDS = 24 * 3600
JOB_TIMEOUT = 900
ACTIVE_LEASE_SECONDS = 1200
MAX_AUDIO_BYTES = 10 * 1024 * 1024


class JobError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message
        super().__init__(message)


class MemoryStore:
    """Test adapter with the same atomic put-if-absent contract as Modal Dict."""
    def __init__(self):
        self.data, self.lock = {}, threading.Lock()

    def get(self, key, default=None):
        with self.lock:
            return copy.deepcopy(self.data.get(key, default))

    def put(self, key, value, *, skip_if_exists=False):
        with self.lock:
            if skip_if_exists and key in self.data:
                return False
            self.data[key] = copy.deepcopy(value)
            return True

    def pop(self, key, default=None):
        with self.lock:
            return self.data.pop(key, default)

    def items(self):
        with self.lock:
            return list(copy.deepcopy(self.data).items())


def job_id(value):
    if not isinstance(value, str):
        raise JobError(400, 'Invalid request ID')
    try:
        return uuid.UUID(value).hex
    except (ValueError, AttributeError):
        raise JobError(400, 'Invalid request ID') from None


def audio_headers(record):
    meta, payload = record['metadata'], record['payload']
    return {'X-Request-ID': record['id'], 'X-Audio-SHA256': meta['sha256'],
            'X-Audio-Sample-Rate': str(meta['sampleRate']), 'X-Audio-Duration': str(meta['outputDuration']),
            'X-Generation-Seconds': str(meta['generationSeconds']),
            'X-Model-Load-Seconds': str(meta['modelLoadSeconds']), 'X-Worker-Session': meta['sessionID'],
            'X-Model-Variant': payload['variant'], 'X-Voice-ID': payload['voice'],
            'X-Speaker-ID': payload['speaker'], 'X-Generation-Mode': payload['mode'],
            'X-Model-Revision': payload['revision'], 'ETag': '"'+meta['sha256']+'"',
            'Accept-Ranges': 'bytes', 'Content-Disposition': 'attachment; filename="revoice.wav"'}


def validate_audio(data, metadata):
    if not isinstance(data, bytes) or not 44 <= len(data) <= MAX_AUDIO_BYTES:
        raise ValueError('Invalid audio size')
    if metadata['sha256'] != hashlib.sha256(data).hexdigest():
        raise ValueError('Audio digest mismatch')
    with wave.open(io.BytesIO(data), 'rb') as reader:
        frames, rate = reader.getnframes(), reader.getframerate()
        if reader.getnchannels() != 1 or reader.getsampwidth() != 2 or rate != 24000:
            raise ValueError('Unsupported output format')
        duration = frames/rate
        if not 0 < duration <= 180 or len(reader.readframes(frames+1)) != frames*2:
            raise ValueError('Incomplete output')
    if metadata['sampleRate'] != rate or abs(metadata['outputDuration']-duration) > 1/rate:
        raise ValueError('Output duration mismatch')


class JobService:
    def __init__(self, store, directory, key, *, clock=time.time, commit=lambda: None, reload=lambda: None):
        self.store, self.directory, self.clock = store, Path(directory), clock
        self.commit, self.reload = commit, reload
        self.signing_key = hmac.new(key.encode(), b'audiorelaylab-job-download-v1', hashlib.sha256).digest()

    def reserve_active(self, identity):
        current = self.store.get('active')
        if current and current['until'] <= self.clock():
            self.store.pop('active', None)
            current = None
        if current:
            return current['id'] == identity
        return self.store.put('active', {'id': identity, 'until': self.clock()+ACTIVE_LEASE_SECONDS}, skip_if_exists=True)

    def release_active(self, identity):
        current = self.store.get('active')
        if current and current['id'] == identity:
            self.store.pop('active', None)

    def charge_rate(self):
        now = self.clock()
        starts = [t for t in self.store.get('rate', []) if t > now-3600]
        if len(starts) >= 180 or sum(t > now-60 for t in starts) >= 12:
            raise JobError(429, 'Busy or rate limited')
        self.store.put('rate', starts+[now])

    def token(self, record):
        message = f"{record['id']}:{record['expiresAt']:.6f}".encode()
        return hmac.new(self.signing_key, message, hashlib.sha256).hexdigest()

    def authenticate_download(self, identity, authorization):
        record = self.get(identity)
        supplied = authorization.removeprefix('Bearer ') if isinstance(authorization, str) else ''
        if not authorization or not authorization.startswith('Bearer ') or not hmac.compare_digest(self.token(record), supplied):
            raise JobError(403, 'Unauthorized')
        return record

    def get(self, identity):
        identity = job_id(identity)
        record = self.store.get('job:'+identity)
        if record is None:
            raise JobError(404, 'Job not found')
        if record['expiresAt'] <= self.clock():
            raise JobError(410, 'Job expired')
        if record['state'] in ('queued', 'running') and record['deadline'] <= self.clock():
            record['state'] = 'failed'; record['error'] = 'Generation timed out'
            self.store.put('job:'+identity, record)
            self.release_active(identity)
        return record

    async def submit(self, identity, payload, enqueue):
        identity = job_id(identity)
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
        existing = self.store.get('job:'+identity)
        if existing:
            if existing['digest'] != digest:
                raise JobError(409, 'Request ID already belongs to different parameters')
            record = self.get(identity)
            if record['state'] == 'queued':
                await enqueue(identity)
            return record
        if not self.reserve_active(identity):
            raise JobError(429, 'Busy or rate limited')
        try:
            self.charge_rate()
        except JobError:
            self.release_active(identity)
            raise
        now = self.clock()
        record = {'id':identity, 'state':'queued', 'createdAt':now, 'expiresAt':now+RETENTION_SECONDS,
                  'deadline':now+JOB_TIMEOUT, 'payload':payload, 'digest':digest}
        if not self.store.put('job:'+identity, record, skip_if_exists=True):
            record = self.get(identity)
            if record['digest'] != digest:
                raise JobError(409, 'Request ID already belongs to different parameters')
        # If delivery is uncertain, keep the same ID/reservation. A repeated CPU
        # spawn is safe because execute() atomically claims the GPU invocation.
        try:
            await enqueue(identity)
        except Exception:
            raise JobError(503, 'Submission not confirmed; recover using the same request ID') from None
        return record

    async def execute(self, identity, invoke):
        identity = job_id(identity)
        record = self.get(identity)
        if record['state'] != 'queued' or not self.store.put('execution:'+identity, True, skip_if_exists=True):
            return {'id':identity, 'duplicate':True}
        record['state'] = 'running'; self.store.put('job:'+identity, record)
        temporary = None
        try:
            remaining = record['deadline']-self.clock()
            if remaining <= 0:
                raise TimeoutError()
            output = await asyncio.wait_for(invoke(record['payload'],identity), timeout=remaining)
            data, metadata = (output['audio'],output['metadata']) if isinstance(output,dict) else output
            if metadata.get('voice') != record['payload']['voice'] or (record['payload']['mode'] == 'custom' and metadata.get('speaker') != record['payload']['speaker']):
                raise ValueError('Output voice mismatch')
            validate_audio(data, metadata)
            if self.clock() > record['deadline']:
                raise TimeoutError()
            self.directory.mkdir(parents=True, exist_ok=True)
            temporary = self.directory/(identity+'.partial')
            temporary.write_bytes(data)
            temporary.replace(self.directory/(identity+'.wav')); temporary = None
            self.commit()
            record['state'] = 'complete'; record['metadata'] = metadata
            self.store.put('job:'+identity, record)
        except (Exception, asyncio.CancelledError):
            if temporary: temporary.unlink(missing_ok=True)
            record['state'] = 'failed'; record['error'] = 'Generation failed'
            self.store.put('job:'+identity, record)
        finally:
            self.release_active(identity)
        return {'id':identity, 'state':record['state']}

    def public(self, record, download_origin):
        value = {k:record[k] for k in ('id','state','createdAt','expiresAt')}
        value['downloadURL'] = download_origin.rstrip('/')+'/v1/jobs/'+record['id']+'/audio'
        value['downloadToken'] = self.token(record)
        if record.get('error'): value['error'] = record['error']
        return value

    async def download(self, identity, authorization, wait):
        record = self.authenticate_download(identity, authorization)
        deadline = time.monotonic()+wait
        while record['state'] in ('queued','running') and time.monotonic() < deadline:
            await asyncio.sleep(min(1,max(0,deadline-time.monotonic())))
            record = self.authenticate_download(identity, authorization)
        if record['state'] in ('queued','running'):
            return record, None
        if record['state'] == 'failed':
            raise JobError(503, 'Generation failed')
        self.reload()
        data = (self.directory/(job_id(identity)+'.wav')).read_bytes()
        validate_audio(data,record['metadata'])
        return record, data

    def cleanup(self):
        self.reload()
        removed = 0
        for key, record in list(self.store.items()):
            if not isinstance(key,str) or not key.startswith('job:') or record['expiresAt'] > self.clock():
                continue
            identity = job_id(record['id'])
            for suffix in ('.wav','.partial'):
                (self.directory/(identity+suffix)).unlink(missing_ok=True)
            self.store.pop('execution:'+identity,None); self.store.pop(key,None); removed += 1
        if removed: self.commit()
        return {'expiredJobsRemoved':removed}


class LegacyJobGuard:
    """Share one durable admission slot with older synchronous clients."""
    def __init__(self, jobs):
        self.jobs, self.owner = jobs, None

    def enter(self):
        identity = 'legacy:'+uuid.uuid4().hex
        if not self.jobs.reserve_active(identity): return False
        try: self.jobs.charge_rate()
        except JobError:
            self.jobs.release_active(identity); return False
        self.owner = identity
        return True

    def leave(self):
        if self.owner: self.jobs.release_active(self.owner)
        self.owner = None


def create_download_api(jobs):
    from fastapi import FastAPI, Request
    from fastapi.responses import JSONResponse, Response
    api = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

    @api.get('/v1/jobs/{identity}/audio')
    async def audio(identity:str, request:Request):
        headers = {'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}
        try:
            values = request.headers.getlist('authorization')
            if len(values) != 1: raise JobError(403,'Unauthorized')
            raw_wait = request.query_params.get('wait','0')
            if not re.fullmatch(r'\d{1,3}',raw_wait) or not 0 <= int(raw_wait) <= 120:
                raise JobError(400,'Invalid wait')
            record, data = await jobs.download(identity, values[0], int(raw_wait))
            if data is None:
                return JSONResponse({'id':record['id'],'state':record['state']},status_code=202,
                                    headers={**headers,'Retry-After':'5'})
            headers.update(audio_headers(record))
            status = 200
            requested_range = request.headers.get('range')
            if requested_range and request.headers.get('if-range',headers['ETag']) == headers['ETag']:
                match = re.fullmatch(r'bytes=(\d+)-(\d*)',requested_range)
                if not match: raise JobError(416,'Unsupported range')
                first = int(match[1]); last = int(match[2]) if match[2] else len(data)-1
                if not 0 <= first <= last < len(data): raise JobError(416,'Invalid range')
                headers['Content-Range'] = f'bytes {first}-{last}/{len(data)}'
                data = data[first:last+1]; status = 206
            return Response(data,status_code=status,media_type='audio/wav',headers=headers)
        except JobError as error:
            return JSONResponse({'error':error.message},status_code=error.status,headers=headers)
        except Exception:
            return JSONResponse({'error':'Result unavailable'},status_code=503,headers=headers)
    return api
