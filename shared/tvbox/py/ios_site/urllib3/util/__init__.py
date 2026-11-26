"""urllib3.util names (original implementation for i短剧, GPL-3.0)."""

from .retry import Retry
from .timeout import Timeout
from .url import Url, parse_url

__all__ = ["Retry", "Timeout", "Url", "parse_url", "make_headers", "create_urllib3_context"]


def __getattr__(name):
    if name in ("create_urllib3_context", "ssl_wrap_socket", "SSLContext", "PROTOCOL_TLS", "resolve_cert_reqs"):
        from . import ssl_

        return getattr(ssl_, name)
    if name == "make_headers":
        from .. import make_headers

        return make_headers
    if name == "ssl_":
        import importlib

        return importlib.import_module("urllib3.util.ssl_")
    raise AttributeError("module 'urllib3.util' has no attribute %r" % name)
