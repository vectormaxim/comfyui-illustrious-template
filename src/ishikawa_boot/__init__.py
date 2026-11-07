"""Jupyter server extension: the pod's boot stream for ishikawa (websocket /ishikawa/boot on the Jupyter port).

Enabled by jupyter_server_config.d/ishikawa_boot.json. The format is in ishikawa's tests/mocks/BOOT_STREAM.md.
"""


def _jupyter_server_extension_points():
    return [{"module": "ishikawa_boot"}]


def _load_jupyter_server_extension(server_app):
    from tornado.web import url
    from ishikawa_boot.handler import BootStreamHandler

    web_app = server_app.web_app
    base = web_app.settings.get("base_url", "/")
    web_app.add_handlers(".*$", [url(base.rstrip("/") + "/ishikawa/boot", BootStreamHandler)])
    server_app.log.info("ishikawa_boot: boot stream at %sishikawa/boot", base)
