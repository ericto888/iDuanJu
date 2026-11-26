"""urllib3-compatible API for i短剧 spiders on iOS.

Original implementation (GPL-3.0) on top of the host's `http` function; not a copy of urllib3. Connection, pool, retry and
TLS settings are accepted so that scripts load; the host manages the connections.
"""

from __future__ import annotations

from . import exceptions
from ._collections import HTTPHeaderDict
from .exceptions import HTTPWarning
from .poolmanager import PoolManager, ProxyManager, proxy_from_url
from .response import BaseHTTPResponse, HTTPResponse
from .util.retry import Retry
from .util.timeout import Timeout

__version__ = "2.2.3"
__all__ = [
    "PoolManager", "ProxyManager", "HTTPResponse", "HTTPHeaderDict", "Retry", "Timeout", "disable_warnings",
    "add_stderr_logger", "request", "make_headers", "proxy_from_url", "exceptions", "encode_multipart_formdata",
]

_default_pool = None


def disable_warnings(category=HTTPWarning):
    """Nothing here warns."""


def add_stderr_logger(level=10):
    return None


def request(method, url, **kwargs):
    global _default_pool
    if _default_pool is None:
        _default_pool = PoolManager()
    return _default_pool.request(method, url, **kwargs)


def make_headers(keep_alive=None, accept_encoding=None, user_agent=None, basic_auth=None, proxy_basic_auth=None,
                 disable_cache=None):
    from _idj_bridge import b64e

    out = {}
    if accept_encoding:
        out["accept-encoding"] = accept_encoding if isinstance(accept_encoding, str) else (
            ",".join(accept_encoding) if isinstance(accept_encoding, (list, tuple)) else "gzip,deflate"
        )
    if user_agent:
        out["user-agent"] = user_agent
    if keep_alive:
        out["connection"] = "keep-alive"
    if basic_auth:
        out["authorization"] = "Basic " + b64e(basic_auth.encode("latin-1"))
    if proxy_basic_auth:
        out["proxy-authorization"] = "Basic " + b64e(proxy_basic_auth.encode("latin-1"))
    if disable_cache:
        out["cache-control"] = "no-cache"
    return out


def __getattr__(name):
    if name == "encode_multipart_formdata":
        from .filepost import encode_multipart_formdata

        return encode_multipart_formdata
    if name in ("HTTPConnectionPool", "HTTPSConnectionPool", "connection_from_url"):
        from . import connectionpool

        return getattr(connectionpool, name)
    if name in ("connectionpool", "filepost", "fields"):
        import importlib

        return importlib.import_module("urllib3." + ("filepost" if name == "fields" else name))
    raise AttributeError("module 'urllib3' has no attribute %r" % name)
