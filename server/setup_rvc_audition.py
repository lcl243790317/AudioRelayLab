# SPDX-License-Identifier: GPL-3.0-only
"""Reproduce the isolated audition environment from refinement-lock.json."""
import hashlib
import json
import shutil
import subprocess
import sys
import sysconfig
import urllib.parse
import urllib.request
import venv
import zipfile
from pathlib import Path

ROOT=Path(__file__).resolve().parent
RUNTIME=ROOT/'.runtime/refinement'
LOCK=json.loads((ROOT/'refinement-lock.json').read_text(encoding='utf-8'))

def digest(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def download(url,target,expected):
    target.parent.mkdir(parents=True,exist_ok=True)
    if not target.exists():
        temporary=target.with_suffix(target.suffix+'.part')
        with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'AudioRelayLab'}),timeout=120) as response,temporary.open('wb') as stream:
            shutil.copyfileobj(response,stream)
        if digest(temporary)!=expected:raise ValueError('Download hash mismatch: '+target.name)
        temporary.replace(target)
    if digest(target)!=expected:raise ValueError('Existing file hash mismatch: '+target.name)
    print('Verified '+target.name,flush=True)


def main():
    import torch,numpy,transformers,imageio_ffmpeg
    for actual,expected in [(torch.__version__,'2.5.1+cu124'),(numpy.__version__,'1.26.4'),(transformers.__version__,'4.46.3')]:
        if actual!=expected:raise ValueError('Run from the verified Seed-VC environment; expected '+expected+', got '+actual)
    RUNTIME.mkdir(parents=True,exist_ok=True)
    env=RUNTIME/'venv'
    if not (env/'Scripts/python.exe').is_file():venv.EnvBuilder(with_pip=True).create(env)
    (env/'Lib/site-packages/seed-evaluation.pth').write_text(sysconfig.get_paths()['purelib']+'\n',encoding='utf-8')
    python=env/'Scripts/python.exe'
    packages=[name+'=='+version for name,version in LOCK['extraDependencies'].items()]
    subprocess.run([str(python),'-m','pip','install','--no-deps']+packages,check=True)
    shutil.copy2(imageio_ffmpeg.get_ffmpeg_exe(),env/'Scripts/ffmpeg.exe')
    rev=LOCK['rvcRevision'];archive=RUNTIME/'rvc-source.zip'
    download('https://codeload.github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI/zip/'+rev,archive,LOCK['rvcSourceZipSHA256'])
    source=RUNTIME/('Retrieval-based-Voice-Conversion-WebUI-'+rev)
    if not source.exists():
        with zipfile.ZipFile(archive) as z:
            for entry in z.infolist():
                if not (RUNTIME/entry.filename).resolve().is_relative_to(RUNTIME.resolve()):raise ValueError('Invalid source archive path')
            z.extractall(RUNTIME)
    for item in LOCK['auditionDownloads']:
        target=RUNTIME/item['localName']
        if not target.resolve().is_relative_to(RUNTIME.resolve()):raise ValueError('Invalid locked download path')
        url='https://huggingface.co/'+item['repository']+'/resolve/'+item['revision']+'/'+urllib.parse.quote(item['path'])
        download(url,target,item['sha256'])
    with zipfile.ZipFile(RUNTIME/'yaorao.zip') as z:
        matches=[name for name in z.namelist() if name.endswith('/yaoraoFor.pth')]
        if len(matches)!=1:raise ValueError('Expected the original fusion checkpoint')
        target=RUNTIME/'yaorao.pth'
        data=z.read(matches[0]);expected=next(v['sha256'] for v in LOCK['files'] if v.get('localName')=='yaorao.pth')
        if hashlib.sha256(data).hexdigest()!=expected:raise ValueError('Voice checkpoint hash mismatch')
        if not target.exists():target.write_bytes(data)
        if digest(target)!=expected:raise ValueError('Existing fusion checkpoint changed')
    print('Audition environment ready. Production service and voice list unchanged.')

if __name__=='__main__':main()
