"""Run the real test command; bound recorder cleanup and preserve its exit status."""
import argparse
import os
from pathlib import Path
import re
import signal
import subprocess
import sys


def start_process(command, **kwargs):
    # Signals only reach the process group created for this child.
    options = ({"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW}
               if os.name == "nt" else {"start_new_session": True})
    return subprocess.Popen(command, stdin=subprocess.DEVNULL, **options, **kwargs)


def stop_process(process, limits=(20, 5, 5)):
    if process.poll() is not None:
        return False
    forced = False
    for number, timeout in enumerate(limits):
        if process.poll() is not None:
            break
        try:
            if os.name == "nt":
                if number == 0:
                    process.send_signal(signal.CTRL_BREAK_EVENT)
                else:
                    process.kill()
            else:
                os.killpg(process.pid, (signal.SIGINT, signal.SIGTERM, signal.SIGKILL)[number])
        except ProcessLookupError:
            pass
        except OSError:
            # A Windows process without a console cannot receive CTRL_BREAK.
            if number != 0:
                raise
        try:
            process.wait(timeout=timeout)
            break
        except subprocess.TimeoutExpired:
            forced = True
    if process.poll() is None:
        raise RuntimeError("owned child did not terminate within the cleanup limit")
    return forced


def validate_video(video, ffmpeg="ffmpeg"):
    result = subprocess.run([str(ffmpeg), "-nostdin", "-v", "error", "-progress", "pipe:1", "-nostats",
                             "-i", str(video), "-map", "0:v:0", "-frames:v", "1", "-f", "null", "-"],
                            capture_output=True, text=True, timeout=30, check=True)
    if not any(int(count) > 0 for count in re.findall(r"^frame=(\d+)\s*$", result.stdout, re.M)):
        raise ValueError("recording has no decodable video frame")


def run_recorded(command, recorder_command, recording_log, video, *, validator=validate_video, limits=(20, 5, 5), protect_cleanup=False):
    recording_log = Path(recording_log)
    recording_log.parent.mkdir(parents=True, exist_ok=True)
    with recording_log.open("w", encoding="utf-8") as output:
        recorder = start_process(recorder_command, stdout=output, stderr=subprocess.STDOUT)
        tests = None
        try:
            tests = start_process(command)
            code = tests.wait()
        finally:
            previous = []
            if protect_cleanup:
                previous = [(value, signal.signal(value, signal.SIG_IGN)) for value in (signal.SIGTERM, signal.SIGINT)]
            try:
                if tests is not None and tests.poll() is None:
                    stop_process(tests, limits)
                forced = stop_process(recorder, limits)
                output.write(f"\nRecorder cleanup: forced={forced}; exit={recorder.returncode}\n")
                output.flush()
            finally:
                for value, handler in previous:
                    signal.signal(value, handler)
        # A recording problem cannot turn a failing test command into success.
        try:
            validator(video)
        except Exception as error:
            output.write(f"Recording validation failed: {type(error).__name__}\n")
            if isinstance(error, subprocess.CalledProcessError) and error.stderr:
                output.write(str(error.stderr)[-2000:] + "\n")
            output.flush()
            return code if code != 0 else 1
        return code


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--video", required=True, type=Path)
    parser.add_argument("--recording-log", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("the actual xcodebuild command is required")
    args.video.parent.mkdir(parents=True, exist_ok=True)
    # Job cancellation enters the same bounded cleanup as a normal test exit.
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        return run_recorded(command, ["xcrun", "simctl", "io", args.simulator, "recordVideo", "--codec=h264", str(args.video)],
                            args.recording_log, args.video, protect_cleanup=True)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
