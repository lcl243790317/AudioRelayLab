# SPDX-License-Identifier: GPL-3.0-only
"""Actual local GPU/CPU inference; does not prove subjective voice naturalness."""
import argparse
import json
import sys
import threading
import time
from pathlib import Path
from conversion_profiles import MODES, conversion_settings
from seed_backend import ROOT, SeedBackend

if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=MODES, action="append", help="可多次指定；默认自然说话")
    parser.add_argument("--voice", action="append", help="音色 ID；默认全部已配置音色")
    parser.add_argument("--source", type=Path, default=ROOT / ".private/references/male-test-source.wav")
    parser.add_argument("--output", type=Path, default=ROOT.parent / "dist/ai-samples")
    args = parser.parse_args()
    source, output = args.source.resolve(), args.output.resolve()
    if not source.is_file(): parser.error("原声音频不存在，请用 --source 指定本地录音")
    profiles = json.loads((ROOT / ".private/voices.json").read_text(encoding="utf-8-sig"))
    if args.voice:
        unknown = set(args.voice) - {p["id"] for p in profiles}
        if unknown: parser.error("未配置的音色 ID：" + ", ".join(sorted(unknown)))
        profiles = [p for p in profiles if p["id"] in args.voice]
    output.mkdir(parents=True, exist_ok=True)
    source_bytes = source.read_bytes()
    (output / "input-original.wav").write_bytes(source_bytes)
    backend = SeedBackend()
    results = []
    for mode in args.mode or ["naturalSpeech"]:
        for profile in profiles:
            started = time.perf_counter()
            settings = conversion_settings(profile, mode)
            path = output / (mode + "-" + profile["id"] + ".wav")
            result = backend.convert(source, ROOT / ".private/references" / profile["reference"],
                                     path, settings, threading.Event())
            result.update(name=profile["name"], file=path.name, conversionSeconds=time.perf_counter()-started,
                          referenceOrigin=profile["referenceOrigin"])
            results.append(result)
            print(json.dumps(result, ensure_ascii=False), flush=True)
    evidence = {"torchVersion":backend.torch.__version__, "cudaAvailable":backend.torch.cuda.is_available(),
                "deviceName":backend.torch.cuda.get_device_name(0) if backend.torch.cuda.is_available() else "CPU",
                "inputOrigin":"User-selected local audio" if source.name != "male-test-source.wav" else
                              "Microsoft Kangkang / Windows local synthetic Mandarin; no human recording",
                "sourceBytes":len(source_bytes), "results":results}
    (output / "actual-inference.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")
