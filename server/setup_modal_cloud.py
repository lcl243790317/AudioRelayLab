# SPDX-License-Identifier: GPL-3.0-only
"""Authorized, private deployment bootstrap. Requires an existing Modal login."""
import argparse
import datetime
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import modal
from revoice_registry import PresetRegistry, digest

ROOT=Path(__file__).resolve().parent
CONFIG=ROOT/'.private/modal-client.json'
STATE=ROOT/'.private/modal-deployment-state.json'
PROXY_NAME='audiorelaylab-ios-prod'


def save_private(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    temporary=path.with_suffix('.json.part')
    temporary.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    if os.name!='nt':temporary.chmod(0o600)
    temporary.replace(path)


def bootstrap():
    if subprocess.run(['git','-c','safe.directory='+ROOT.parent.as_posix(),'check-ignore','--quiet',str(CONFIG)],
                      cwd=ROOT.parent).returncode:
        raise RuntimeError('Private credential path is not gitignored')
    # Test login before creating any credential, cloud resource, build or GPU.
    workspace=modal.Workspace.from_context();workspace.hydrate()
    from modal_app import app,assets,prepare_models,api,APP_NAME,SECRET_NAME,REFERENCE_ROOT
    registry=PresetRegistry()
    references={p.reference_id:registry.verify_reference(p.reference_id,ROOT.parent/'dist/revoice-expanded')
                for p in registry.presets.values() if p.enabled and p.variant=='base'}
    config=json.loads(CONFIG.read_text(encoding='utf-8')) if CONFIG.exists() else {}
    state=json.loads(STATE.read_text(encoding='utf-8')) if STATE.exists() else {}
    if state.get('secretCreated') and not config.get('apiKey'):
        raise RuntimeError('The saved application key is missing; recover it or rotate it explicitly')
    try:
        existing=modal.App.lookup(APP_NAME)
    except modal.exception.NotFoundError:
        existing=None
    if existing and state.get('appID')!=existing.app_id:
        raise RuntimeError('A deployment with this name already exists without this project ownership record')
    config.setdefault('apiKey',secrets.token_urlsafe(48))
    save_private(CONFIG,config)
    names=[secret.name for secret in modal.Secret.objects.list()]
    if SECRET_NAME in names:
        if not state.get('secretCreated'):
            raise RuntimeError('Existing application secret has no local project ownership record')
    else:
        modal.Secret.objects.create(SECRET_NAME,{'AUDIOLAB_API_KEY':config['apiKey']},allow_existing=False)
        state['secretCreated']=True;save_private(STATE,state)
    if not config.get('proxyTokenID'):
        if any(t.name==PROXY_NAME for t in workspace.proxy_tokens.list()):
            raise RuntimeError('Existing named proxy token has no local secret; rotate it explicitly')
        token=workspace.proxy_tokens.create(name=PROXY_NAME)
        config.update(proxyTokenID=token.token_id,proxyTokenSecret=token.token_secret)
        save_private(CONFIG,config)
        state['proxyCreated']=True;save_private(STATE,state)
    # Upload only accepted fixed identities; files never enter the image/source repository.
    pending=[]
    for name,(audio,_) in references.items():
        entry=registry.references[name]
        for field in ('audioFile','metadataFile'):
            local=audio.parent/entry[field]
            remote=REFERENCE_ROOT.removeprefix('/assets')+'/'+entry[field]
            try:
                current=b''.join(assets.read_file(remote))
            except (modal.exception.NotFoundError,FileNotFoundError):
                pending.append((local,remote));continue
            import hashlib
            if hashlib.sha256(current).hexdigest()!=digest(local):
                raise RuntimeError('Existing private reference differs from its identity lock')
    if pending:
        with assets.batch_upload(force=False) as upload:
            for local,remote in pending:upload.put_file(local,remote)
    # Recreate also prevents old/new GPU pools overlapping during future redeployments.
    app.deploy(strategy='recreate')
    state.update(appID=app.app_id,appName=APP_NAME,gpuSnapshot=os.environ.get('AUDIOLAB_GPU_SNAPSHOT')=='1',
                 updatedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
    save_private(STATE,state)
    prepared=prepare_models.remote()
    config['endpoint']=api.get_web_url()
    save_private(CONFIG,config)
    state.update(endpoint=config['endpoint'],models=prepared,realGPUTests='not yet run')
    save_private(STATE,state)
    print(json.dumps(dict(appName=APP_NAME,appURL=app.get_dashboard_url(),endpoint=config['endpoint'],
                         variants=prepared['variants'],acceptedVoices=[v['id'] for v in registry.public_voices()]),ensure_ascii=False))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-auth',action='store_true',help='Read-only login check; creates no cloud resources')
    parser.add_argument('--gpu-snapshot', choices=['on', 'off'], default='off')
    args=parser.parse_args()
    os.environ['AUDIOLAB_GPU_SNAPSHOT'] = '1' if args.gpu_snapshot == 'on' else '0'
    try:
        if args.check_auth:
            modal.Workspace.from_context().hydrate()
            print('Modal login is configured; no cloud resources created.')
        else:
            with modal.enable_output():
                bootstrap()
    except modal.exception.AuthError:
        print('Modal login is required. Run the isolated environment python -m modal token new; no deployment was created.',file=sys.stderr)
        raise SystemExit(2) from None


if __name__=='__main__':main()
