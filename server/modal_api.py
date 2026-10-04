# SPDX-License-Identifier: GPL-3.0-only
"""CPU-only authenticated router. Importing this module never imports torch or Qwen."""
import asyncio
from collections import deque
import hashlib
import hmac
import json
import logging
import time
import uuid
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from revoice_contract import text_for_synthesis, custom_task, public_speakers
from revoice_registry import PresetRegistry

MAX_BODY_BYTES = 8192
LOG = logging.getLogger('audiorelaylab.cloud')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON field')
        result[key] = value
    return result


def validate_request(body, registry):
    if not isinstance(body, dict) or set(body) != {'voice', 'text'}:
        raise ValueError('Only voice and text are accepted')
    preset = registry.get(body['voice'], cloud=True)
    text = text_for_synthesis(body['text'])
    text.encode('utf-8')
    if any(ord(c)<32 and c not in '\r\n\t' for c in text):
        raise ValueError('Invalid text control characters')
    return preset, text


def validate_custom_request(body):
    if not isinstance(body, dict) or not {'speaker', 'text'} <= set(body) or set(body) - {'speaker', 'text', 'instruction'}:
        raise ValueError('Only speaker, text and instruction are accepted')
    return custom_task(body['speaker'], body['text'], body.get('instruction', ''))


class RequestGuard:
    """Singleton CPU-container guard; resets on container restart (documented)."""
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.starts = deque()
        self.active = False

    def enter(self):
        now = self.clock()
        while self.starts and self.starts[0] <= now-3600:
            self.starts.popleft()
        if self.active or len(self.starts) >= 180 or sum(t > now-60 for t in self.starts) >= 12:
            return False
        self.active = True
        self.starts.append(now)
        return True

    def leave(self):
        self.active = False


class AuthMiddleware:
    def __init__(self, app, key):
        self.app, self.key = app, key.encode('utf-8')

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http':
            await self.app(scope, receive, send)
            return
        supplied = [v for k, v in scope['headers'] if k.lower() == b'x-audiorelay-key']
        if len(supplied) != 1 or not hmac.compare_digest(supplied[0], self.key):
            await JSONResponse({'error': 'Unauthorized'}, status_code=403,
                               headers={'Cache-Control': 'no-store'})(scope, receive, send)
            return
        await self.app(scope, receive, send)


def create_api(worker, api_key, registry=None, guard=None, custom_worker=None):
    if not isinstance(api_key, str) or len(api_key) < 32:
        raise RuntimeError('Required application secret is missing or invalid')
    registry, guard = registry or PresetRegistry(), guard or RequestGuard()
    api = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    api.add_middleware(AuthMiddleware, key=api_key)

    @api.middleware('http')
    async def no_store(request, call_next):
        response = await call_next(request)
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        return response

    @api.get('/v1/health')
    async def health():
        # Health checks intentionally never touch or warm the GPU worker.
        return {'status': 'ok', 'backend': 'Modal Qwen3-TTS 1.7B', 'voices': len(registry.public_voices()),
                'capabilities': {'presetTTS': True, 'customTTS': custom_worker is not None, 'textOnly': True},
                'limits': {'textCharacters': 1000, 'instructionCharacters': 500, 'outputSeconds': 180}}

    @api.get('/v1/voices')
    async def voices():
        return {'voices': registry.public_voices()}

    @api.get('/v1/speakers')
    async def speakers():
        return {'speakers': public_speakers()}

    @api.post('/v1/tts')
    async def synthesize(request: Request):
        return await synthesize_request(request, 'preset')

    @api.post('/v1/tts/custom')
    async def synthesize_custom(request: Request):
        return await synthesize_request(request, 'custom')

    async def synthesize_request(request: Request, mode):
        request_id = uuid.uuid4().hex
        try:
            if request.headers.get('content-type', '').split(';')[0].strip().lower() != 'application/json':
                return JSONResponse({'error': 'Expected JSON'}, status_code=415)
            lengths = request.headers.getlist('content-length')
            if len(lengths) > 1:
                raise ValueError('Ambiguous body length')
            if lengths:
                size = int(lengths[0])
                if size < 0:
                    raise ValueError('Invalid body length')
                if size > MAX_BODY_BYTES:
                    return JSONResponse({'error': 'Body too large'}, status_code=413)
            data = bytearray()
            async for chunk in request.stream():
                if len(data)+len(chunk) > MAX_BODY_BYTES:
                    return JSONResponse({'error': 'Body too large'}, status_code=413)
                data.extend(chunk)
            body = json.loads(data.decode('utf-8'), object_pairs_hook=unique_object)
            if mode == 'custom':
                values = validate_custom_request(body)
                voice, variant, speaker, text = 'custom', 'custom', values['speaker'], values['text']
                if custom_worker is None:
                    return JSONResponse({'error': 'Custom synthesis is unavailable'}, status_code=503)
            else:
                preset, text = validate_request(body, registry)
                voice, variant, speaker = preset.id, preset.variant, preset.speaker or ''
        except (ValueError, TypeError, UnicodeError):
            return JSONResponse({'error': 'Invalid text or voice request'}, status_code=400)
        if not guard.enter():
            return JSONResponse({'error': 'Busy or rate limited'}, status_code=429, headers={'Retry-After': '10'})
        task = asyncio.create_task(custom_worker(speaker, text, values['instruction'], request_id) if mode == 'custom'
                                   else worker(voice, text, request_id))
        try:
            # If a client disconnects, keep the gate until the one dispatched generation finishes.
            result = await asyncio.shield(task)
            data, metadata = result['audio'], result['metadata']
            if (hashlib.sha256(data).hexdigest() != metadata['sha256'] or metadata['voice'] != voice
                    or (mode == 'custom' and metadata.get('speaker') != speaker)):
                raise RuntimeError('Worker result integrity mismatch')
            headers = {'X-Request-ID': request_id, 'X-Audio-SHA256': metadata['sha256'],
                       'X-Audio-Sample-Rate': str(metadata['sampleRate']),
                       'X-Audio-Duration': str(metadata['outputDuration']),
                       'X-Generation-Seconds': str(metadata['generationSeconds']),
                       'X-Model-Load-Seconds': str(metadata['modelLoadSeconds']),
                       'X-Worker-Session': metadata['sessionID'],
                       'X-Model-Variant': variant, 'X-Voice-ID': voice,
                       'X-Speaker-ID': speaker, 'X-Generation-Mode': mode,
                       'X-Model-Revision': registry.lock['models'][variant]['revision'],
                       'Content-Disposition': 'attachment; filename="revoice.wav"'}
            LOG.info(json.dumps(dict(requestID=request_id, voice=voice, speaker=speaker, textCharacterCount=len(text),
                                     modelVariant=variant, generationSeconds=metadata['generationSeconds'],
                                     outputDuration=metadata['outputDuration'], status='complete')))
            return Response(data, media_type='audio/wav', headers=headers)
        except asyncio.CancelledError:
            task.add_done_callback(lambda finished: (finished.exception() if not finished.cancelled() else None, guard.leave()))
            raise
        except Exception as error:
            LOG.warning(json.dumps(dict(requestID=request_id, voice=voice, textCharacterCount=len(text),
                                        modelVariant=variant, status='failed', errorType=type(error).__name__)))
            return JSONResponse({'error': 'Generation failed', 'requestID': request_id}, status_code=503)
        finally:
            if task.done():
                guard.leave()

    return api
