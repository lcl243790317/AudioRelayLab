# SPDX-License-Identifier: GPL-3.0-only
"""Keep the user's LAN service alive and restart an unexpectedly exited worker."""
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from process_identity import save_identity

ROOT = Path(__file__).resolve().parent

def main():
    logs = ROOT / ".logs"
    logs.mkdir(exist_ok=True)
    save_identity(ROOT / ".private/supervisor-process.json")
    failures = []
    with (logs / "supervisor.log").open("a",encoding="utf-8") as audit:
        while True:
            with (logs / "service.log").open("ab") as output, (logs / "service-error.log").open("ab") as errors:
                child = subprocess.Popen([sys.executable,"-u","-X","utf8",str(ROOT/"app.py")],
                    cwd=ROOT,stdout=output,stderr=errors,
                    creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
                audit.write(f"{datetime.now().isoformat()} started worker launcher={child.pid}\n"); audit.flush()
                code = child.wait()
            audit.write(f"{datetime.now().isoformat()} worker exited code={code}\n"); audit.flush()
            now = time.monotonic()
            failures = [t for t in failures if now-t < 600]
            failures.append(now)
            if len(failures) >= 5:
                audit.write("Too many failures; run server/run.ps1 -Restart after checking service-error.log.\n")
                return
            time.sleep(min(30,2**len(failures)))

if __name__ == "__main__":
    main()
