"""The websocket handler: Jupyter's own authentication, then BootStream's frames on a timer until the end frame."""
import time

from jupyter_server.base.handlers import JupyterHandler
from tornado import web
from tornado.ioloop import PeriodicCallback
from tornado.websocket import WebSocketHandler

from ishikawa_boot.stream import BootStream, encode

TICK_MS = 500


class BootStreamHandler(JupyterHandler, WebSocketHandler):
    """Jupyter's token (`Authorization: token ...` or `?token=`) or session is required; no user, no upgrade."""

    def check_origin(self, origin=None):
        return True  # a script client sends none; the token is what protects it

    def get(self, *args, **kwargs):
        if self.current_user is None:
            raise web.HTTPError(403)
        return WebSocketHandler.get(self, *args, **kwargs)

    def open(self, *args, **kwargs):
        self.stream_state = BootStream()
        self.timer = PeriodicCallback(self.tick, TICK_MS)
        self.timer.start()
        self.tick()

    def tick(self):
        for frame in self.stream_state.poll(time.time()):
            try:
                self.write_message(encode(frame))
            except Exception:
                self.timer.stop()
                return
        if self.stream_state.ended:
            self.timer.stop()
            self.close()

    def on_message(self, message):
        pass

    def on_close(self):
        timer = getattr(self, "timer", None)
        if timer:
            timer.stop()
