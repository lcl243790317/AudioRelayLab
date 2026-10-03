# SPDX-License-Identifier: GPL-3.0-only
"""Real local inference evidence; input/reference speech is generated on this PC."""
import json
import sys
import threading
import time
from pathlib import Path
from seed_backend import ROOT, SeedBackend

if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    started = time.perf_counter()
    backend = SeedBackend()
    loaded = time.perf_counter() - started
    output = ROOT.parent / "dist/ai-samples"
    output.mkdir(parents=True, exist_ok=True)
    source = ROOT / ".private/references/male-test-source.wav"
    (output / "male-source.wav").write_bytes(source.read_bytes())
    profiles = json.loads((ROOT / ".private/voices.json").read_text(encoding="utf-8-sig"))
    results = []
    for profile in profiles:
        before = time.perf_counter()
        path = output / (profile["id"] + ".wav")
        result = backend.convert(source, ROOT / ".private/references" / profile["reference"],
                                 path, profile, threading.Event())
        result.update(name=profile["name"], file=path.name, conversionSeconds=time.perf_counter()-before,
                      referenceOrigin=profile["referenceOrigin"])
        results.append(result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    evidence = {"modelLoadSeconds":loaded, "torchVersion":backend.torch.__version__,
                "cudaAvailable":backend.torch.cuda.is_available(),
                "deviceName":backend.torch.cuda.get_device_name(0) if backend.torch.cuda.is_available() else "CPU",
                "inputOrigin":"Microsoft Kangkang / Windows local synthetic Mandarin; no human recording",
                "results":results}
    (output / "actual-inference.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2),encoding="utf-8")
