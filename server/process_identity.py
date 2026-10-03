# SPDX-License-Identifier: GPL-3.0-only
"""Identity for stopping only this project's processes, even after PID reuse."""
import json
import os
from pathlib import Path

def save_identity(path: Path):
    result = {"processID":os.getpid()}
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.GetCurrentProcess.restype = wintypes.HANDLE
        created, exited, system, user = (wintypes.FILETIME() for _ in range(4))
        kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
        if not kernel.GetProcessTimes(kernel.GetCurrentProcess(), *(ctypes.byref(v) for v in (created,exited,system,user))):
            raise ctypes.WinError(ctypes.get_last_error())
        # FILETIME starts in 1601; .NET DateTime ticks start in year 1.
        result["startTicks"] = (created.dwHighDateTime << 32) + created.dwLowDateTime + 504911232000000000
    path.write_text(json.dumps(result),encoding="utf-8")
