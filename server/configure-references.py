# SPDX-License-Identifier: GPL-3.0-only
"""Verify pinned official demo references; keep custom voices and original source files."""
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def configure():
    import librosa
    import numpy as np
    import soundfile as sf
    lock = json.loads((ROOT / "reference-lock.json").read_text(encoding="utf-8-sig"))
    references = [dict(id="female-natural",name="自然女声 · 中文",repository="QwenAudio/CosyVoice",
        revision=lock["revision"],path=lock["path"],sha256=lock["sha256"],license=lock["license"])] + lock["additionalReferences"]
    folder = ROOT / ".private/references"
    folder.mkdir(parents=True,exist_ok=True)
    config = ROOT / ".private/voices.json"
    profiles = json.loads(config.read_text(encoding="utf-8-sig")) if config.is_file() else []
    known = {p["id"] for p in references} | {"female-clear","female-warm"}
    custom = [p for p in profiles if p["id"] not in known]
    defaults=[]
    for ref in references:
        original = folder / (ref["id"]+"-official"+Path(ref["path"]).suffix)
        if ref["id"]=="female-natural" and not original.is_file() and (folder/"cosyvoice-female.wav").is_file():
            original.write_bytes((folder/"cosyvoice-female.wav").read_bytes())
        if not original.is_file():
            url="https://raw.githubusercontent.com/"+ref["repository"]+"/"+ref["revision"]+"/"+ref["path"]
            with urllib.request.urlopen(url,timeout=120) as response:
                data=response.read(4*1024*1024+1)
            if len(data)>4*1024*1024: raise RuntimeError("参考文件异常过大")
            original.write_bytes(data)
        if hashlib.sha256(original.read_bytes()).hexdigest()!=ref["sha256"]:
            raise RuntimeError("官方参考文件校验失败："+ref["id"])
        samples,rate=sf.read(original,dtype="float32")
        if samples.ndim>1: samples=samples.mean(axis=1)
        if rate!=22050: samples=librosa.resample(samples,orig_sr=rate,target_sr=22050)
        samples,_=librosa.effects.trim(samples,top_db=35)
        samples=samples[:12*22050]
        if samples.size<22050 or not np.isfinite(samples).all(): raise RuntimeError("参考音频无效")
        peak=float(np.max(np.abs(samples)))
        if peak>.98: samples*=.98/peak
        filename=ref["id"]+"-pcm.wav"
        sf.write(folder/filename,samples,22050,subtype="PCM_16")
        origin=ref["repository"]+" 官方公开示例 / "+ref["path"]+"（本机测试参考）"
        defaults.append(dict(id=ref["id"],name=ref["name"],reference=filename,referenceOrigin=origin,
            referenceSHA256=ref["sha256"],modes={}))
    temporary=config.with_suffix(".tmp")
    temporary.write_text(json.dumps(defaults+custom,ensure_ascii=False,indent=2),encoding="utf-8")
    temporary.replace(config)
    print("已配置 "+str(len(defaults))+" 个独立参考音色；已有自定义音色保留。",flush=True)
    for p in defaults: print(p["id"]+" / "+p["name"],flush=True)

if __name__=="__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    configure()
