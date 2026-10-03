# SPDX-License-Identifier: GPL-3.0-only
"""Fetch the pinned public Chinese example, verify it, convert only its encoding."""
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    import soundfile as sf
    lock = json.loads((ROOT / "reference-lock.json").read_text(encoding="utf-8-sig"))
    url = "https://raw.githubusercontent.com/QwenAudio/CosyVoice/"+lock["revision"]+"/"+lock["path"]
    original = ROOT / ".private/references/cosyvoice-female.wav"
    if not original.is_file():
        urllib.request.urlretrieve(url,original)
    if hashlib.sha256(original.read_bytes()).hexdigest() != lock["sha256"]:
        raise RuntimeError("官方参考文件校验失败")
    samples, rate = sf.read(original)
    sf.write(ROOT / ".private/references/cosyvoice-female-pcm.wav",samples,rate,subtype="PCM_16")
    config = ROOT / ".private/voices.json"
    profiles = json.loads(config.read_text(encoding="utf-8-sig"))
    profiles[0].update(reference="cosyvoice-female-pcm.wav",
        referenceOrigin="QwenAudio / CosyVoice 官方中文示例（Apache-2.0 仓库；zero_shot_prompt.wav）")
    # Local synthetic references repeated words in real conversion/ASR checks.
    # Keep the artifacts for comparison, but exclude them from shipped defaults.
    profiles = [p for p in profiles if p["id"] not in ("female-clear", "female-warm")]
    config.write_text(json.dumps(profiles,ensure_ascii=False,indent=2),encoding="utf-8")
    print("官方中文女声参考已验证；默认列表仅包含通过当前对比的自然女声。")
