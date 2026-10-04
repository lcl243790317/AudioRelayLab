# SPDX-License-Identifier: GPL-3.0-only
"""Private HTTPS text-to-WAV client; never logs credentials or text."""
import argparse
import array
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import time
import urllib.parse
import uuid
import wave
import httpx
from revoice_contract import validate_output_duration
from revoice_contract import custom_task
from revoice_registry import PresetRegistry

ROOT = Path(__file__).resolve().parent
DEFAULT_CONFIG = ROOT/'.private/modal-client.json'
MAX_WAV_BYTES = 10*1024*1024


class ClientError(RuntimeError):
    pass


def read_config(path=DEFAULT_CONFIG):
    env_fields = {'endpoint':'AUDIOLAB_MODAL_URL','proxyTokenID':'MODAL_PROXY_TOKEN_ID',
                  'proxyTokenSecret':'MODAL_PROXY_TOKEN_SECRET','apiKey':'AUDIOLAB_API_KEY'}
    stored = json.loads(Path(path).read_text(encoding='utf-8-sig')) if Path(path).is_file() else {}
    config = {name:os.environ.get(variable) or stored.get(name) for name,variable in env_fields.items()}
    if not all(isinstance(value,str) and value for value in config.values()):
        raise ClientError('Modal client credentials are not configured')
    validate_endpoint(config['endpoint'])
    return config


def validate_endpoint(url):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme!='https' or not parsed.hostname or not parsed.hostname.endswith('.modal.run')
            or parsed.username or parsed.password or parsed.port not in (None,443) or parsed.query or parsed.fragment):
        raise ClientError('Expected a private HTTPS Modal endpoint')
    return parsed


def auth_headers(config):
    return {'Modal-Key':config['proxyTokenID'],'Modal-Secret':config['proxyTokenSecret'],
            'X-AudioRelay-Key':config['apiKey']}


@dataclass
class HTTPResult:
    status: int
    data: bytes
    headers: dict
    seconds: float


def request(config, method, path, *, body=None, headers=None):
    origin=validate_endpoint(config['endpoint'])
    url=config['endpoint'].rstrip('/')+'/'+path.lstrip('/')
    started=time.perf_counter()
    credential_headers=auth_headers(config) if headers is None else headers
    try:
        with httpx.Client(timeout=httpx.Timeout(180,connect=30),follow_redirects=False) as client:
            for _ in range(8):
                if time.perf_counter()-started>900:
                    raise ClientError('Cloud request exceeded its total time limit')
                with client.stream(method,url,json=body,headers=credential_headers) as response:
                    if response.status_code==303:
                        destination=urllib.parse.urlsplit(urllib.parse.urljoin(url,response.headers.get('location','')))
                        # Modal long-request result polling must stay on the same HTTPS origin.
                        if (destination.scheme,destination.hostname,destination.port or 443)!=(origin.scheme,origin.hostname,origin.port or 443) or destination.username or destination.password:
                            raise ClientError('Refusing a redirect that could expose credentials')
                        url=urllib.parse.urlunsplit(destination);method='GET';body=None
                        continue
                    received=bytearray()
                    for chunk in response.iter_bytes():
                        if len(received)+len(chunk)>MAX_WAV_BYTES:
                            raise ClientError('Response is too large')
                        received.extend(chunk)
                    return HTTPResult(response.status_code,bytes(received),dict(response.headers),time.perf_counter()-started)
            raise ClientError('Too many result redirects')
    except httpx.HTTPError:
        raise ClientError('HTTPS connection failed; the request was not automatically retried') from None


def validate_wav(result, preset):
    if result.status!=200:
        raise ClientError('Cloud service returned HTTP '+str(result.status))
    if result.headers.get('content-type','').split(';')[0]!='audio/wav':
        raise ClientError('Expected a WAV response')
    sha=hashlib.sha256(result.data).hexdigest()
    if sha!=result.headers.get('x-audio-sha256'):
        raise ClientError('Audio hash mismatch')
    try:
        with wave.open(io.BytesIO(result.data)) as audio:
            rate,frames=audio.getframerate(),audio.getnframes()
            if rate!=24000 or audio.getnchannels()!=1 or audio.getsampwidth()!=2:
                raise ClientError('Unexpected WAV format')
            samples=array.array('h',audio.readframes(frames))
            if sys.byteorder!='little':samples.byteswap()
        duration=frames/rate;validate_output_duration(duration)
        if len(samples)!=frames or max(abs(value) for value in samples)/32768<.0001:
            raise ClientError('Truncated or silent audio')
        if abs(float(result.headers['x-audio-duration'])-duration)>1/rate:
            raise ClientError('Output duration mismatch')
        if int(result.headers['x-audio-sample-rate'])!=rate or result.headers['x-model-variant']!=preset.variant:
            raise ClientError('Voice route or sample rate mismatch')
        if result.headers.get('x-voice-id',preset.id) != preset.id:
            raise ClientError('Voice identity mismatch')
        generation=float(result.headers['x-generation-seconds'])
        load=float(result.headers['x-model-load-seconds'])
    except (ValueError,KeyError,wave.Error,EOFError):
        raise ClientError('Invalid waveform or response metadata') from None
    return dict(voice=preset.id,variant=preset.variant,sampleRate=rate,outputDuration=duration,sha256=sha,
                totalSeconds=result.seconds,generationSeconds=generation,modelLoadSeconds=load,
                requestID=result.headers.get('x-request-id'),sessionID=result.headers.get('x-worker-session'))


def synthesize_custom(speaker, text, instruction, output, config=None):
    from types import SimpleNamespace
    values=custom_task(speaker,text,instruction)
    output=Path(output).resolve()
    if output.suffix.lower()!='.wav' or output.exists() or output.with_suffix('.json').exists():
        raise ClientError('Choose a new WAV output path')
    result=request(config or read_config(),'POST','v1/tts/custom',
                   body={k:values[k] for k in ('speaker','text','instruction')})
    metadata=validate_wav(result,SimpleNamespace(id='custom',variant='custom'))
    if result.headers.get('x-speaker-id')!=speaker or result.headers.get('x-generation-mode')!='custom':
        raise ClientError('Custom identity mismatch')
    metadata.update(speaker=speaker,generationMode='custom',modelRevision=result.headers.get('x-model-revision'))
    save_result(result,metadata,output)
    return metadata


def save_result(result,metadata,output):
    output=Path(output).resolve()
    if output.suffix.lower()!='.wav' or output.exists() or output.with_suffix('.json').exists():
        raise ClientError('Choose a new WAV output path')
    output.parent.mkdir(parents=True,exist_ok=True)
    temporary=output.parent/('.modal-'+uuid.uuid4().hex+'.wav.part')
    sidecar=temporary.with_suffix('.json.part');published=False
    try:
        temporary.write_bytes(result.data)
        sidecar.write_text(json.dumps(metadata,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        os.link(temporary,output);published=True
        os.link(sidecar,output.with_suffix('.json'))
    except BaseException:
        if published and output.exists() and os.path.samefile(temporary,output):output.unlink()
        raise
    finally:
        temporary.unlink(missing_ok=True);sidecar.unlink(missing_ok=True)


def synthesize(voice,text,output,config=None):
    preset=PresetRegistry().get(voice,cloud=True)
    text=preset.task(text)['text']
    output=Path(output)
    if output.suffix.lower()!='.wav' or output.exists() or output.with_suffix('.json').exists():
        raise ClientError('Existing audio will not be overwritten')
    result=request(config or read_config(),'POST','v1/tts',body=dict(voice=voice,text=text))
    metadata=validate_wav(result,preset)
    save_result(result,metadata,output)
    return metadata


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--voice',required=True);parser.add_argument('--text',required=True)
    parser.add_argument('--output');parser.add_argument('--config',default=str(DEFAULT_CONFIG))
    args=parser.parse_args()
    output=Path(args.output) if args.output else ROOT.parent/'dist/modal-client'/(uuid.uuid4().hex+'.wav')
    try:
        metadata=synthesize(args.voice,args.text,output,read_config(args.config))
    except (ClientError,ValueError) as error:
        parser.exit(1,str(error)+'\n')
    print('Saved:',output.resolve())
    print(json.dumps(metadata,ensure_ascii=False))


if __name__=='__main__':main()
