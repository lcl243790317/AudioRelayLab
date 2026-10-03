# SPDX-License-Identifier: GPL-3.0-only
"""Separate-process adapter for the pinned, unmodified Seed-VC v2 project."""
import hashlib
import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent

class SeedBackend:
    engine = "Seed-VC v2"
    def __init__(self):
        lock = json.loads((ROOT / "upstream-lock.json").read_text())
        source = ROOT / ".runtime" / ("seed-vc-" + lock["revision"])
        if not (source / "inference_v2.py").is_file():
            raise RuntimeError("请先运行 server/setup.ps1 安装固定版本 AI 引擎")
        os.environ["HF_HUB_CACHE"] = str(ROOT / ".runtime/hf-cache")
        os.environ["HF_HOME"] = str(ROOT / ".runtime/hf-home")
        os.environ["HF_HUB_DOWNLOAD_TIMEOUT"] = "120"
        sys.path.insert(0, str(source))
        os.chdir(source)  # Upstream configuration paths are relative to its own root.
        import torch
        import inference_v2
        import imageio_ffmpeg
        from pydub import AudioSegment
        AudioSegment.converter = imageio_ffmpeg.get_ffmpeg_exe()
        self.torch = torch
        self.device = inference_v2.device
        self.model = inference_v2.load_v2_models(SimpleNamespace(
            ar_checkpoint_path=None, cfm_checkpoint_path=None, compile=False))
        self.lock = lock
        self.dtype = torch.float16

    def convert(self, source:Path, reference:Path, destination:Path, settings:dict, cancelled):
        import numpy as np
        import soundfile as sf
        if cancelled.is_set():
            raise InterruptedError("已取消")
        with self.torch.inference_mode():
            generator = self.model.convert_voice_with_streaming(
                source_audio_path=str(source), target_audio_path=str(reference),
                diffusion_steps=settings["steps"], length_adjust=1.0,
                intelligebility_cfg_rate=settings.get("intelligibility", 0.7),
                similarity_cfg_rate=settings.get("similarity", 0.7),
                top_p=settings.get("topP", 0.9), temperature=settings.get("temperature", 0.85),
                repetition_penalty=settings.get("repetitionPenalty", 1.0),
                convert_style=True, anonymization_only=False,
                device=self.device, dtype=self.dtype, stream_output=True)
            full_audio = None
            for _, result in generator:
                if cancelled.is_set():
                    raise InterruptedError("已取消")
                if result is not None:
                    full_audio = result
        if cancelled.is_set():
            raise InterruptedError("已取消")
        if full_audio is None:
            raise RuntimeError("AI 模型没有生成音频")
        rate, samples = full_audio
        samples = np.asarray(samples, dtype=np.float32).reshape(-1)
        if samples.size < rate / 5 or not np.isfinite(samples).all():
            raise RuntimeError("AI 模型生成了无效音频")
        peak = float(np.max(np.abs(samples)))
        if peak < 0.0001:
            raise RuntimeError("AI 输出为空或静音")
        if peak > 0.98:
            samples *= 0.98 / peak
        sf.write(str(destination), samples, rate, subtype="PCM_16")
        return {"engine":self.engine, "sourceRevision":self.lock["revision"],
                "device":str(self.device), "sampleRate":int(rate),
                "duration":float(samples.size/rate), "outputPeakBeforeNormalization":peak,
                "sha256":hashlib.sha256(destination.read_bytes()).hexdigest(),
                "settings":settings}
