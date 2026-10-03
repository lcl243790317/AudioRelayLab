# SPDX-License-Identifier: GPL-3.0-only
"""Install a pinned, isolated revoice audition runtime; never modifies voice profiles."""
import argparse
import concurrent.futures
import hashlib
import json
import os
import shutil
import subprocess
import sysconfig
import time
import urllib.parse
import urllib.request
import venv
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT / '.runtime/revoice'
LOCK_PATH = ROOT / 'revoice-lock.json'

def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def download_ranges(url, partial, size):
    chunk = 16*1024*1024
    ranges = [(start,min(size-1,start+chunk-1)) for start in range(0,size,chunk)]
    with partial.open('wb') as stream: stream.truncate(size)
    def read_range(bounds):
        start,end = bounds
        for attempt in range(3):
            try:
                request = urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0','Range':f'bytes={start}-{end}'})
                with urllib.request.urlopen(request,timeout=120) as response:
                    expected = f'bytes {start}-{end}/{size}'
                    if response.status != 206 or response.headers.get('Content-Range') != expected:
                        raise ValueError('Server returned the wrong model range')
                    data = response.read(end-start+2)
                if len(data) != end-start+1: raise OSError('Incomplete model range')
                return start,data
            except (OSError,TimeoutError):
                if attempt==2:raise
                time.sleep(2)
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool, partial.open('r+b') as output:
        for future in concurrent.futures.as_completed([pool.submit(read_range,bounds) for bounds in ranges]):
            start,data = future.result();output.seek(start);output.write(data)
            done += len(data)
            if done//(1024**3) != (done-len(data))//(1024**3):
                print('Downloaded '+str(done//(1024**3))+' GiB / '+str(round(size/(1024**3),2))+' GiB',flush=True)

def download(repo, revision, item, cache):
    target = cache / item['sha256']
    if target.is_file():
        if target.stat().st_size != item['bytes'] or digest(target) != item['sha256']:
            raise ValueError('Existing cached file differs from the lock: '+item['path'])
        return target
    url = 'https://huggingface.co/'+repo+'/resolve/'+revision+'/'+urllib.parse.quote(item['path'])
    partial = target.with_suffix('.part')
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={'User-Agent':'AudioRelayLab/1.5.1'})
            if item['bytes'] > 100*1024*1024:
                download_ranges(url,partial,item['bytes'])
            else:
                with urllib.request.urlopen(request, timeout=120) as response, partial.open('wb') as output:
                    shutil.copyfileobj(response, output, length=4*1024*1024)
            if partial.stat().st_size != item['bytes'] or digest(partial) != item['sha256']:
                raise ValueError('Downloaded model hash mismatch: '+item['path'])
            partial.replace(target)
            print('Verified '+repo+'/'+item['path'], flush=True)
            return target
        except (OSError, TimeoutError):
            if attempt == 2: raise
            time.sleep(2)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--models-only', action='store_true')
    args = parser.parse_args()
    lock = json.loads(LOCK_PATH.read_text(encoding='utf-8-sig'))
    RUNTIME.mkdir(parents=True, exist_ok=True)
    if not args.models_only:
        import torch, numpy
        for name, actual in [('torch',torch.__version__),('numpy',numpy.__version__)]:
            if actual != lock['inheritedRuntime'][name]:
                raise ValueError('Run setup with the existing verified Seed-VC Python environment')
        env = RUNTIME / 'venv'
        if not (env/'Scripts/python.exe').is_file():
            venv.EnvBuilder(with_pip=True).create(env)
        (env/'Lib/site-packages/seed-readonly.pth').write_text(sysconfig.get_paths()['purelib']+'\n', encoding='utf-8')
        subprocess.run([str(env/'Scripts/python.exe'),'-m','pip','install','--no-deps']+
                       [name+'=='+version for name,version in lock['extraDependencies'].items()], check=True)
    cache = RUNTIME/'blobs'; cache.mkdir(exist_ok=True)
    unique = {}
    for model in lock['models'].values():
        for item in model['files']:
            unique.setdefault(item['sha256'], (model['repository'],model['revision'],item))
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        futures = [pool.submit(download,repo,rev,item,cache) for repo,rev,item in unique.values()]
        for future in concurrent.futures.as_completed(futures): future.result()
    for kind, model in lock['models'].items():
        for item in model['files']:
            target = RUNTIME/'models'/kind/item['path']
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                if digest(target) != item['sha256']: raise ValueError('Existing model changed: '+str(target))
            else:
                try: os.link(cache/item['sha256'], target)
                except OSError: shutil.copy2(cache/item['sha256'], target)
    print('All pinned audition models verified. No production voice was registered.', flush=True)

if __name__ == '__main__': main()
