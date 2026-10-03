# SPDX-License-Identifier: GPL-3.0-only
"""Run the pinned, unmodified official inference paths; one GPU model set at a time."""
import gc
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path
from types import SimpleNamespace
from conversion_profiles import DEFAULTS, conversion_settings

ROOT = Path(__file__).resolve().parent

class SeedBackend:
    engine = "Seed-VC V1 / V2 / F0"
    def __init__(self):
        self.lock = json.loads((ROOT / "upstream-lock.json").read_text())
        source = ROOT / ".runtime" / ("seed-vc-" + self.lock["revision"])
        if not (source / "inference.py").is_file():
            raise RuntimeError("请先运行 server/setup.ps1 安装固定版本 AI 引擎")
        os.environ["HF_HUB_CACHE"] = str(ROOT / ".runtime/hf-cache")
        os.environ["HF_HOME"] = str(ROOT / ".runtime/hf-home")
        os.environ["HF_HUB_DOWNLOAD_TIMEOUT"] = "120"
        os.environ["HF_HUB_ETAG_TIMEOUT"] = "120"
        sys.path.insert(0, str(source))
        # Short cache paths are required for the official F0 filename on Windows.
        self.work = ROOT / ".runtime/f0"
        self.work.mkdir(exist_ok=True)
        shutil.copytree(source / "configs", self.work / "configs", dirs_exist_ok=True)
        os.chdir(self.work)
        import torch
        import inference
        self.torch = torch
        self.device = inference.device
        self.fp16 = torch.cuda.is_available()
        self.inference = inference
        self.models = None
        self.kind = ""

    def arguments(self, source, reference, output, settings):
        f0 = settings["mode"] == "preserveProsody"
        return SimpleNamespace(source=str(source), target=str(reference), output=str(output),
            f0_condition=f0, auto_f0_adjust=f0, semi_tone_shift=settings["pitchShift"],
            diffusion_steps=settings["steps"], length_adjust=1.0, inference_cfg_rate=settings["intelligibility"],
            fp16=self.fp16, checkpoint=None, config=None)

    def prepare(self, settings, cancelled):
        if cancelled.is_set(): raise InterruptedError("已取消")
        mode = settings["mode"]
        kind = "v2" if mode in ("balancedV2", "timbrePriority") else ("f0" if mode == "preserveProsody" else "speech")
        if self.kind == kind and self.models is not None: return
        self.models = None
        self.kind = ""
        gc.collect()
        if self.torch.cuda.is_available(): self.torch.cuda.empty_cache()
        if kind == "v2":
            import inference_v2
            self.models = inference_v2.load_v2_models(SimpleNamespace(ar_checkpoint_path=None,cfm_checkpoint_path=None,compile=False))
            import imageio_ffmpeg
            from pydub import AudioSegment
            AudioSegment.converter = imageio_ffmpeg.get_ffmpeg_exe()
        else:
            self.models = self.inference.load_models(self.arguments("", "", self.work, settings))
        self.kind = kind
        self.engine = {"v2":"Seed-VC V2 / ASTRAL", "f0":"Seed-VC F0 / RMVPE", "speech":"Seed-VC Speech / Whisper-small"}[kind]
        if cancelled.is_set(): raise InterruptedError("已取消")

    def convert(self, source:Path, reference:Path, destination:Path, settings:dict, cancelled):
        import numpy as np
        import soundfile as sf
        mode = settings.get("mode", "preserveProsody")
        # Independent validation also protects direct local use of this adapter.
        if mode not in DEFAULTS: raise ValueError("不支持此转换方式")
        safe = conversion_settings({"modes":{mode:{k:settings[k] for k in DEFAULTS[mode] if k in settings}}},mode)
        # Source content is retained in every mode; expression rewriting is disabled.
        settings = safe
        self.prepare(settings,cancelled)
        render = destination.parent / ".render"
        produced = None
        try:
            with self.torch.inference_mode():
                if self.kind == "v2":
                    full = None
                    generator = self.models.convert_voice_with_streaming(source_audio_path=str(source),target_audio_path=str(reference),
                        diffusion_steps=settings["steps"],length_adjust=1.0,
                        intelligebility_cfg_rate=settings["intelligibility"],similarity_cfg_rate=settings["similarity"],
                        top_p=settings["topP"],temperature=settings["temperature"],repetition_penalty=settings["repetitionPenalty"],
                        convert_style=False,anonymization_only=False,device=self.device,
                        dtype=self.torch.float16 if self.fp16 else self.torch.float32,stream_output=True)
                    for _,audio in generator:
                        if cancelled.is_set(): raise InterruptedError("已取消")
                        if audio is not None: full = audio
                    if full is None: raise RuntimeError("V2 模型未返回完整音频")
                    rate,samples = full
                    samples = np.asarray(samples)
                    if np.issubdtype(samples.dtype,np.integer): samples = samples.astype(np.float32)/32768
                else:
                    render.mkdir(exist_ok=True)
                    args = self.arguments(source,reference,render,settings)
                    produced = render / f"vc_{source.name.split('.')[0]}_{reference.name.split('.')[0]}_1.0_{settings['steps']}_{settings['intelligibility']}.wav"
                    loader = self.inference.load_models
                    try:
                        self.inference.load_models = lambda _: self.models
                        self.inference.main(args)
                    finally:
                        self.inference.load_models = loader
                    samples,rate = sf.read(produced,dtype="float32")
            if cancelled.is_set(): raise InterruptedError("已取消")
            samples = np.asarray(samples,dtype=np.float32).reshape(-1)
            if rate not in (22050,44100) or samples.size < rate/5 or not np.isfinite(samples).all():
                raise RuntimeError("AI 模型生成了无效音频")
            source_info = sf.info(source)
            source_seconds = source_info.frames/source_info.samplerate
            # Official mel framing can lose a few milliseconds at the end, not a spoken word.
            expected = round(source_seconds*rate)
            if abs(samples.size-expected) <= rate*.05:
                samples = np.pad(samples[:expected],(0,max(0,expected-samples.size)))
            if not .3 <= samples.size/rate <= 60:
                raise RuntimeError("模型输出长度异常，请重试或选择保留语调")
            peak = float(np.max(np.abs(samples)))
            if peak < .0001: raise RuntimeError("AI 输出为空或静音")
            if peak > .98: samples *= .98/peak
            sf.write(destination,samples,rate,subtype="PCM_16")
        except BaseException:
            destination.unlink(missing_ok=True)
            raise
        finally:
            if produced is not None: produced.unlink(missing_ok=True)
            if render.is_dir() and not any(render.iterdir()): render.rmdir()
        if cancelled.is_set():
            destination.unlink(missing_ok=True)
            raise InterruptedError("已取消")
        return {"engine":self.engine,"sourceRevision":self.lock["revision"],"device":str(self.device),
                "sampleRate":int(rate),"duration":float(samples.size/rate),"outputPeakBeforeNormalization":peak,
                "sha256":hashlib.sha256(destination.read_bytes()).hexdigest(),
                "settings":dict({k:settings[k] for k in ("steps","intelligibility","similarity","pitchShift")},
                    convertStyle=0,lengthAdjust=1.0,sourcePitchGuidance=int(mode=="preserveProsody"),
                    autoPitchAdjust=int(mode=="preserveProsody")),
                "conversionMode":mode}
