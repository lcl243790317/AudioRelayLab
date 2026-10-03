# SPDX-License-Identifier: GPL-3.0-only
"""Adapter for the pinned Seed-VC F0 model; preserve source content and pitch contour."""
import hashlib
import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent

class SeedBackend:
    engine = "Seed-VC F0 / RMVPE"
    def __init__(self):
        lock = json.loads((ROOT / "upstream-lock.json").read_text())
        source = ROOT / ".runtime" / ("seed-vc-" + lock["revision"])
        if not (source / "inference.py").is_file():
            raise RuntimeError("请先运行 server/setup.ps1 安装固定版本 AI 引擎")
        os.environ["HF_HUB_CACHE"] = str(ROOT / ".runtime/hf-cache")
        os.environ["HF_HOME"] = str(ROOT / ".runtime/hf-home")
        os.environ["HF_HUB_DOWNLOAD_TIMEOUT"] = "120"
        os.environ["HF_HUB_ETAG_TIMEOUT"] = "120"
        sys.path.insert(0, str(source))
        # Upstream's own HF helper uses ./checkpoints. Keep it below Windows MAX_PATH.
        work = ROOT / ".runtime/f0"
        work.mkdir(exist_ok=True)
        os.chdir(work)
        import torch
        import inference
        self.torch = torch
        self.device = inference.device
        self.fp16 = torch.cuda.is_available()
        self.inference = inference
        self.models = inference.load_models(self.arguments("", "", work, 30, 0.7))
        self.lock = lock

    def arguments(self, source, reference, output, steps, cfg):
        return SimpleNamespace(source=str(source), target=str(reference), output=str(output),
            f0_condition=True, auto_f0_adjust=True, semi_tone_shift=0,
            diffusion_steps=steps, length_adjust=1.0, inference_cfg_rate=cfg,
            fp16=self.fp16, checkpoint=None, config=None)

    def convert(self, source:Path, reference:Path, destination:Path, settings:dict, cancelled):
        import numpy as np
        import soundfile as sf
        if cancelled.is_set():
            raise InterruptedError("已取消")
        steps = int(settings["steps"])
        cfg = float(settings.get("intelligibility", 0.7))
        if not 10 <= steps <= 80 or not 0 <= cfg <= 1:
            raise ValueError("AI 推理参数超出支持范围")
        render = destination.parent / ".render"
        render.mkdir(exist_ok=True)
        args = self.arguments(source, reference, render, steps, cfg)
        produced = render / f"vc_{source.name.split('.')[0]}_{reference.name.split('.')[0]}_1.0_{steps}_{cfg}.wav"
        # This API calls load_models on each invocation. Reuse this worker's models
        # while running the unmodified official F0/length/chunk inference function.
        loader = self.inference.load_models
        try:
            self.inference.load_models = lambda _: self.models
            with self.torch.inference_mode():
                self.inference.main(args)
            if cancelled.is_set():
                raise InterruptedError("已取消")
            samples, rate = sf.read(produced, dtype="float32")
            samples = np.asarray(samples, dtype=np.float32).reshape(-1)
            if rate != 44100 or samples.size < rate / 5 or not np.isfinite(samples).all():
                raise RuntimeError("AI 模型生成了无效音频")
            peak = float(np.max(np.abs(samples)))
            if peak < 0.0001:
                raise RuntimeError("AI 输出为空或静音")
            if peak > 0.98:
                samples *= 0.98 / peak
            sf.write(str(destination), samples, rate, subtype="PCM_16")
        finally:
            self.inference.load_models = loader
            if produced.is_file():
                produced.unlink()
            if render.is_dir() and not any(render.iterdir()):
                render.rmdir()
        if cancelled.is_set():
            destination.unlink(missing_ok=True)
            raise InterruptedError("已取消")
        return {"engine":self.engine, "sourceRevision":self.lock["revision"],
                "device":str(self.device), "sampleRate":int(rate),
                "duration":float(samples.size/rate), "outputPeakBeforeNormalization":peak,
                "sha256":hashlib.sha256(destination.read_bytes()).hexdigest(),
                "settings":{"steps":steps, "inferenceCFG":cfg, "convertStyle":0,
                            "lengthAdjust":1, "sourcePitchGuidance":1, "autoPitchAdjust":1,
                            "pitchShift":0}}
