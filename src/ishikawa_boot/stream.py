"""The boot stream's source: what a booting pod says about itself, as frames (ishikawa tests/mocks/BOOT_STREAM.md).

Pure and synchronous, so it runs in-process against a temp log and fake staging files (tools/test_boot_stream.py).
`BootStream.poll(now)` returns the frames due at `now`; the Jupyter handler (handler.py) calls it on a timer and writes them.
Standard library only.
"""
import glob
import json
import os
import re

LOG_PATH = "/workspace/comfyui.log"
READY = "ComfyUI is ready"
PROGRESS_EVERY_S = 2   # per file, while it grows
PING_EVERY_S = 20      # RunPod's proxy cuts a silent connection at 100 s; the format promises one at least every 30 s
STAGING = re.compile(r"^\.civitai-([^-]+)-(.+)\.part$")


def staging_dirs():
    """Where the downloader's `.civitai-<file>-<key>.part` files live: the model folders under the volume root."""
    root = os.environ.get("PERSIST_ROOT") or "/workspace"
    return [os.path.join(root, "models", "*"), os.path.join(root, "ComfyUI", "models", "*")]


def allocated_bytes(path):
    """Bytes really written, not the apparent size: aria2c makes the file nearly full-size at once and fills it in."""
    return os.stat(path).st_blocks * 512


class BootStream:
    def __init__(self, log_path=None, dirs=None):
        self.log_path = log_path or os.environ.get("ISHIKAWA_BOOT_LOG") or LOG_PATH
        self.dirs = dirs if dirs is not None else staging_dirs()
        self.offset = 0          # bytes of the log already sent
        self.sent_at = None      # when the last frame went out
        self.reported = {}       # staging file -> (bytes, when) last sent
        self.ended = False

    def _read_log(self):
        try:
            size = os.path.getsize(self.log_path)
        except OSError:
            return None
        if size < self.offset:   # the log started over: say so by sending it again from 0
            self.offset = 0
        if size == self.offset:
            return None
        with open(self.log_path, "rb") as f:
            f.seek(self.offset)
            raw = f.read(size - self.offset)
        text = None
        for cut in range(0, 4):  # never end inside a multi-byte character; the rest goes in the next frame
            try:
                text = raw[:len(raw) - cut].decode("utf-8")
                raw = raw[:len(raw) - cut]
                break
            except UnicodeDecodeError:
                continue
        if text is None:
            raw = raw.decode("utf-8", "replace").encode("utf-8")
            text = raw.decode("utf-8")
        if not raw:
            return None
        frame = {"type": "log", "offset": self.offset, "text": text}
        self.offset += len(raw)
        return frame

    def _progress(self, now):
        out = []
        seen = set()
        for pattern in self.dirs:
            for path in glob.glob(os.path.join(pattern, ".civitai-*.part")):
                m = STAGING.match(os.path.basename(path))
                if not m or path in seen:
                    continue
                seen.add(path)
                try:
                    got = allocated_bytes(path)
                except OSError:
                    continue
                last = self.reported.get(path)
                if last and (got == last[0] or now - last[1] < PROGRESS_EVERY_S):
                    continue
                self.reported[path] = (got, now)
                out.append({"type": "progress", "file": m.group(1), "key": m.group(2), "bytes": got, "t": int(now)})
        for gone in set(self.reported) - seen:
            del self.reported[gone]
        return out

    def poll(self, now):
        """The frames due at `now` (epoch seconds), possibly none. After an `end` frame there are none."""
        if self.ended:
            return []
        frames = []
        log = self._read_log()
        if log:
            frames.append(log)
        frames += self._progress(now)
        if log and READY in log["text"]:
            frames.append({"type": "end"})
            self.ended = True
        elif not frames and (self.sent_at is None or now - self.sent_at >= PING_EVERY_S):
            frames.append({"type": "ping", "t": int(now)})
        if frames:
            self.sent_at = now
        return frames


def encode(frame):
    return json.dumps(frame, separators=(",", ":"))
