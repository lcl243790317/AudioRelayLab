"""Actual child-process cleanup tests; these do not execute Swift or Simulator."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("recorded_ui", Path(__file__).resolve().parents[1] / "scripts/run-recorded-ui-tests.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
STUB = """import signal,time
for name in ('SIGINT','SIGTERM','SIGBREAK'):
    if hasattr(signal,name):
        signal.signal(getattr(signal,name),signal.SIG_IGN)
print('ready',flush=True)
while True: time.sleep(.05)
"""
TEMP_BASE = Path(__file__).resolve().parents[1] / "dist"


class RecordedUIProcessTests(unittest.TestCase):
    def child(self):
        process = module.start_process([sys.executable, "-u", "-c", STUB], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(process.stdout.readline().strip(), "ready")
        self.addCleanup(lambda: module.stop_process(process, (.1, .1, 1)))
        self.addCleanup(process.stdout.close)
        self.addCleanup(process.stderr.close)
        return process

    def test_unresponsive_recorder_is_stopped_within_bound_without_stopping_other_child(self):
        first, other = self.child(), self.child()
        started = time.monotonic()
        self.assertTrue(module.stop_process(first, (.1, .1, 1)))
        self.assertLess(time.monotonic() - started, 3)
        self.assertIsNotNone(first.poll())
        self.assertIsNone(other.poll())

    def test_completed_child_is_preserved_and_never_signaled(self):
        process = module.start_process([sys.executable, "-c", "raise SystemExit(7)"])
        self.assertEqual(process.wait(timeout=5), 7)
        self.assertFalse(module.stop_process(process, (.1, .1, 1)))
        self.assertEqual(process.returncode, 7)

    def test_original_test_failure_survives_recorder_cleanup_and_video_failure(self):
        TEMP_BASE.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="recorded-ui-", dir=TEMP_BASE) as directory:
            self.assertTrue(Path(directory).resolve().is_relative_to(TEMP_BASE.resolve()))
            def invalid(video):
                raise ValueError("deliberately invalid fixture")
            code = module.run_recorded([sys.executable, "-c", "import time;time.sleep(.3);raise SystemExit(7)"],
                [sys.executable, "-u", "-c", STUB], Path(directory) / "recording.log", Path(directory) / "bad.mp4",
                validator=invalid, limits=(.1, .1, 1))
            self.assertEqual(code, 7)
            self.assertIn("Recording validation failed", (Path(directory) / "recording.log").read_text())

    def test_invalid_recording_prevents_successful_command_from_becoming_success(self):
        TEMP_BASE.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="recorded-ui-", dir=TEMP_BASE) as directory:
            self.assertTrue(Path(directory).resolve().is_relative_to(TEMP_BASE.resolve()))
            def invalid(video):
                raise ValueError("deliberately invalid fixture")
            code = module.run_recorded([sys.executable, "-c", "import time;time.sleep(.3)"],
                [sys.executable, "-u", "-c", STUB], Path(directory) / "recording.log", Path(directory) / "bad.mp4",
                validator=invalid, limits=(.1, .1, 1))
            self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
