"""CI-only loopback HTTPS fixture for real iOS URLSession download callbacks.

The disposable Simulator trusts an ephemeral local certificate. This script and
its fake task token never enter the App or replace production TLS validation.
"""
import argparse
import hashlib
import io
import json
import math
import re
import signal
import ssl
import struct
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


def audio():
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(24000)
        wav.writeframes(b"".join(struct.pack("<h", round(6000 * math.sin(2 * math.pi * 220 * i / 24000)))
                                for i in range(24000)))
    return output.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--certificate", type=Path, required=True)
    parser.add_argument("--private-key", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    content = audio()
    digest = hashlib.sha256(content).hexdigest()
    counts = {"successfulDownloads": 0, "pendingResponses": 0, "refusedRequests": 0, "longTermCredentialHeadersSeen": False}
    attempts = {}
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *values):
            pass

        def do_GET(self):
            path = urlsplit(self.path).path
            if path == "/ready":
                self.send_response(204)
                self.end_headers()
                return
            matched = re.fullmatch(r"/v1/jobs/([0-9a-f]{32})/audio", path)
            long_keys = any(self.headers.get(k) for k in ["Modal-Key", "Modal-Secret", "X-AudioRelay-Key"])
            authorized = self.headers.get("Authorization") == "Bearer " + "a" * 64
            with lock:
                counts["longTermCredentialHeadersSeen"] |= long_keys
                if not matched or not authorized or long_keys:
                    counts["refusedRequests"] += 1
            if not matched or not authorized or long_keys:
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            task_id = matched.group(1)
            with lock:
                attempts[task_id] = attempts.get(task_id, 0) + 1
                pending = task_id.startswith("20200000") and attempts[task_id] == 1
                counts["pendingResponses" if pending else "successfulDownloads"] += 1
            if pending:
                payload = json.dumps({"id": task_id, "state": "running"}).encode()
                self.send_response(202)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            self.send_response(200)
            headers = {"Content-Type": "audio/wav", "Content-Length": str(len(content)),
                       "Cache-Control": "no-store", "X-Audio-SHA256": digest, "X-Audio-Sample-Rate": "24000",
                       "X-Audio-Duration": "1", "X-Generation-Seconds": "0.1", "X-Voice-ID": "custom",
                       "X-Speaker-ID": "Serena", "X-Generation-Mode": "custom", "X-Model-Variant": "custom",
                       "X-Model-Revision": "a" * 40, "X-Request-ID": matched.group(1)}
            for key, value in headers.items():
                self.send_header(key, value)
            self.end_headers()
            try:
                self.wfile.write(content)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.certificate, args.private_key)
    server.socket = context.wrap_socket(server.socket, server_side=True)

    def stop(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    print("CI loopback HTTPS download fixture ready", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(dict(counts, sampleRate=24000, duration=1,
                                              fixtureOnly=True, productionTLSChanged=False), indent=2) + "\n",
                               encoding="utf-8")


if __name__ == "__main__":
    main()
