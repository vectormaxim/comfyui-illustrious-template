#!/usr/bin/env python3
"""Self-check: the pod's boot stream (src/ishikawa_boot), no pod needed.

Part 1 drives BootStream in-process against a temp log and fake sparse staging files.
Part 2 starts a real Jupyter server (only if jupyter_server is installed; skipped otherwise) with the extension enabled
and checks the token is required and the frames arrive over a real websocket.

Run: python3 tools/test_boot_stream.py        (stdlib only for part 1)
"""
import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src"))
from ishikawa_boot.stream import BootStream, PING_EVERY_S  # noqa: E402


class CoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.log = os.path.join(self.tmp, "comfyui.log")
        self.models = os.path.join(self.tmp, "models", "checkpoints")
        os.makedirs(self.models)

    def append(self, text):
        with open(self.log, "ab") as f:
            f.write(text.encode())

    def stream(self):
        return BootStream(self.log, [os.path.join(self.tmp, "models", "*")])

    def test_late_joiner_gets_the_whole_log_then_appended_text(self):
        self.append("one\ntwo\n")
        s = self.stream()
        self.assertEqual(s.poll(100), [{"type": "log", "offset": 0, "text": "one\ntwo\n"}])
        self.append("three\n")
        self.assertEqual(s.poll(101), [{"type": "log", "offset": 8, "text": "three\n"}])

    def test_offset_counts_bytes_and_never_splits_a_character(self):
        self.append("✅ ok\n")
        with open(self.log, "ab") as f:
            f.write("é".encode()[:1])  # half a character at the end of the file
        s = self.stream()
        first = s.poll(1)[0]
        self.assertEqual(first["text"], "✅ ok\n")
        with open(self.log, "ab") as f:
            f.write("é".encode()[1:] + b"x")
        second = s.poll(2)[0]
        self.assertEqual((second["offset"], second["text"]), (len("✅ ok\n".encode()), "éx"))

    def test_log_that_starts_over_is_sent_again_from_zero(self):
        self.append("long old text\n")
        s = self.stream()
        s.poll(1)
        os.unlink(self.log)
        self.append("new\n")
        self.assertEqual(s.poll(2), [{"type": "log", "offset": 0, "text": "new\n"}])

    def test_progress_reports_allocated_bytes_not_apparent_size(self):
        p = os.path.join(self.models, ".civitai-2822349-ab12cd.part")
        with open(p, "wb") as f:
            f.truncate(5 * 1024 ** 3)  # sparse: 5 GiB apparent, nothing allocated
            f.seek(0)
            f.write(b"x" * 1_000_000)
        want = os.stat(p).st_blocks * 512
        self.assertLess(want, 10_000_000)
        frames = [f for f in self.stream().poll(50) if f["type"] == "progress"]
        self.assertEqual(frames, [{"type": "progress", "file": "2822349", "key": "ab12cd", "bytes": want, "t": 50}])

    def test_progress_only_while_it_grows_and_about_every_two_seconds(self):
        p = os.path.join(self.models, ".civitai-7-k.part")
        with open(p, "wb") as f:
            f.write(b"x" * 100_000)
        s = self.stream()
        self.assertEqual(len([f for f in s.poll(10) if f["type"] == "progress"]), 1)
        with open(p, "ab") as f:
            f.write(b"y" * 100_000)
        self.assertEqual(s.poll(10.5), [])  # too soon: nothing due
        self.assertEqual(len([f for f in s.poll(13) if f["type"] == "progress"]), 1)
        self.assertEqual([f for f in s.poll(16) if f["type"] == "progress"], [])  # no growth, no report

    def test_a_ping_comes_at_least_every_30_seconds_when_nothing_happens(self):
        s = self.stream()
        t, last, gaps = 0, None, []
        while t < 300:
            if any(f["type"] == "ping" for f in s.poll(t)):
                if last is not None:
                    gaps.append(t - last)
                last = t
            t += 0.5
        self.assertTrue(gaps)
        self.assertLessEqual(max(gaps), 30)
        self.assertGreaterEqual(min(gaps), PING_EVERY_S)

    def test_end_when_comfyui_is_ready_and_nothing_after(self):
        self.append("starting\n")
        s = self.stream()
        s.poll(1)
        self.append("  ComfyUI is ready   https://x-8188.proxy.runpod.net\n")
        frames = s.poll(2)
        self.assertEqual([f["type"] for f in frames], ["log", "end"])
        self.assertTrue(s.ended)
        self.append("more\n")
        self.assertEqual(s.poll(3), [])

    def test_joining_after_ready_gets_the_log_then_the_end(self):
        self.append("a\nComfyUI is ready\n")
        self.assertEqual([f["type"] for f in self.stream().poll(1)], ["log", "end"])


# ---- part 2: a real Jupyter server -----------------------------------------------------------------------------------

def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def ws_connect(port, path, headers):
    """A minimal client: returns (status line, socket) after the upgrade request."""
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    req = [f"GET {path} HTTP/1.1", f"Host: 127.0.0.1:{port}", "Upgrade: websocket", "Connection: Upgrade",
           f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13"] + [f"{k}: {v}" for k, v in headers.items()]
    s.sendall(("\r\n".join(req) + "\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    return head.split(b"\r\n")[0].decode(), s, rest


def read_frame(sock, buf):
    """One websocket text frame -> (payload or None on close, remaining bytes)."""
    def need(n):
        nonlocal buf
        while len(buf) < n:
            chunk = sock.recv(65536)
            if not chunk:
                raise EOFError
            buf += chunk
    need(2)
    op, ln = buf[0] & 0x0F, buf[1] & 0x7F
    pos = 2
    if ln == 126:
        need(4); ln = int.from_bytes(buf[2:4], "big"); pos = 4
    elif ln == 127:
        need(10); ln = int.from_bytes(buf[2:10], "big"); pos = 10
    need(pos + ln)
    payload, buf = buf[pos:pos + ln], buf[pos + ln:]
    return (None if op == 8 else payload.decode()), buf


@unittest.skipUnless(shutil.which("jupyter") or (Path(sys.executable).parent / "jupyter").exists(), "jupyter_server not installed")
class JupyterTest(unittest.TestCase):
    TOKEN = "s3cret"

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.log = os.path.join(self.tmp, "comfyui.log")
        Path(self.log).write_text("hello\n")
        cfgdir = os.path.join(self.tmp, "cfg", "jupyter_server_config.d")
        os.makedirs(cfgdir)
        shutil.copy(REPO / "src" / "jupyter_config" / "ishikawa_boot.json", cfgdir)
        self.port = free_port()
        jupyter = shutil.which("jupyter") or str(Path(sys.executable).parent / "jupyter")
        env = dict(os.environ, JUPYTER_CONFIG_DIR=os.path.join(self.tmp, "cfg"), JUPYTER_RUNTIME_DIR=self.tmp,
                   JUPYTER_DATA_DIR=self.tmp, PYTHONPATH=str(REPO / "src"), ISHIKAWA_BOOT_LOG=self.log, PERSIST_ROOT=self.tmp)
        self.proc = subprocess.Popen([jupyter, "server", f"--port={self.port}", "--ip=127.0.0.1", "--no-browser",
                                      f"--ServerApp.token={self.TOKEN}", f"--ServerApp.root_dir={self.tmp}"],
                                     env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.proc.wait)
        self.addCleanup(self.proc.terminate)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.2)

    def test_refused_without_the_token_and_streams_with_it(self):
        status, s, _ = ws_connect(self.port, "/ishikawa/boot", {})
        s.close()
        self.assertNotIn("101", status)
        status, s, _ = ws_connect(self.port, "/ishikawa/boot", {"Authorization": "token wrong"})
        s.close()
        self.assertNotIn("101", status)

        status, s, rest = ws_connect(self.port, "/ishikawa/boot", {"Authorization": f"token {self.TOKEN}"})
        self.addCleanup(s.close)
        self.assertIn("101", status)
        msg, buf = read_frame(s, rest)
        self.assertEqual(json.loads(msg), {"type": "log", "offset": 0, "text": "hello\n"})
        with open(self.log, "a") as f:
            f.write("ComfyUI is ready\n")
        msg, buf = read_frame(s, buf)
        self.assertEqual(json.loads(msg)["offset"], 6)
        msg, buf = read_frame(s, buf)
        self.assertEqual(json.loads(msg), {"type": "end"})
        msg, buf = read_frame(s, buf)
        self.assertIsNone(msg)  # the socket then closes


if __name__ == "__main__":
    unittest.main()
