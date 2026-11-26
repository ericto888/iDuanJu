"""Routes `urllib.request` through the host's `http` function (original code for i短剧, GPL-3.0).

`install()` swaps the HTTP/HTTPS handlers urllib builds its openers from, so `urlopen`, `build_opener`, `Request`,
cookie processors, redirects and HTTPError keep their stdlib behaviour. `urllib.request` is heavy and most scripts never
use it, so the swap happens when it is first imported. Nothing here needs `ssl` or `socket` by itself.
"""

from __future__ import annotations

import sys
from io import BytesIO

_saved = None
_hook = None


class HostResponse(BytesIO):
    """What urllib handlers expect from http.client.HTTPResponse, fully buffered."""

    def __init__(self, status, reason, headers, body, url):
        super().__init__(body)
        self.status = self.code = status
        self.reason = reason
        self.msg = reason  # urllib uses .msg as the reason phrase
        self.headers = headers
        self.url = url
        self.version = 11
        self.length = len(body)
        self.chunked = False
        self.will_close = True

    def info(self):
        return self.headers

    def geturl(self):
        return self.url

    def getcode(self):
        return self.code

    def getheader(self, name, default=None):
        values = self.headers.get_all(name)
        return ", ".join(values) if values else default

    def getheaders(self):
        return list(self.headers.items())

    def isclosed(self):
        return self.closed

    def read(self, amt=-1):
        if self.closed:
            return b""
        return super().read(-1 if amt is None else amt)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def _reason(status):
    from http import HTTPStatus

    try:
        return HTTPStatus(status).phrase
    except ValueError:
        return ""


def _verifies(context):
    """Should certificates be checked? Honours contexts and the usual "unverified" monkey patch."""
    if context is not None:
        return bool(getattr(context, "verify_mode", 1))
    ssl = sys.modules.get("ssl")
    if ssl is None:
        return True
    factory = getattr(ssl, "_create_default_https_context", None)
    return factory is None or factory is not getattr(ssl, "_create_unverified_context", None)


def _timeout(value):
    if isinstance(value, (int, float)):
        return value
    socket = sys.modules.get("socket")
    default = socket.getdefaulttimeout() if socket is not None and hasattr(socket, "getdefaulttimeout") else None
    return default or None


def _body(data):
    if data is None or isinstance(data, bytes):
        return data
    if hasattr(data, "read"):
        data = data.read()
        return data.encode("utf-8") if isinstance(data, str) else data
    if isinstance(data, (bytearray, memoryview)):
        return bytes(data)
    return b"".join(data)


def _regzip(content):
    """The script asked for gzip itself and will decompress: give it what it asked for."""
    import zlib

    packer = zlib.compressobj(1, zlib.DEFLATED, 31)
    return packer.compress(content) + packer.flush()


def open_request(req, context=None):
    """Perform a urllib.request.Request; returns HostResponse or raises URLError."""
    import http.client
    from urllib.error import URLError

    from _idj_http import HostError, exchange, is_timeout

    headers = dict(req.unredirected_hdrs)
    headers.update({k: v for k, v in req.headers.items() if k not in headers})
    headers = {name.title(): value for name, value in headers.items()}
    if headers.get("Host", "").lower() == (req.host or "").lower():
        headers.pop("Host", None)
    headers.pop("Connection", None)
    wants_gzip = "gzip" in str(headers.get("Accept-Encoding", "")).lower()
    url = req.full_url.partition("#")[0]
    try:
        status, _, pairs, content = exchange(
            req.get_method(), url, headers, _body(req.data), _timeout(getattr(req, "timeout", None)),
            _verifies(context),
        )
    except HostError as exc:
        reason = TimeoutError(exc.message) if is_timeout(exc.message) else OSError(exc.message)
        raise URLError(reason) from exc
    message = http.client.HTTPMessage()
    for name, value in pairs:
        low = name.lower()
        if low == "content-encoding" and value.strip().lower() not in ("", "identity"):
            # The host has already decoded the body.
            if not (wants_gzip and "gzip" in value.lower() and content[:2] != b"\x1f\x8b"):
                continue
            content = _regzip(content)
        elif low in ("content-length", "transfer-encoding"):
            continue
        message[name] = value
    message["Content-Length"] = str(len(content))
    return HostResponse(status, _reason(status), message, content, req.full_url)


class _ImportHook:
    """Patches urllib.request as soon as it has been imported."""

    def find_spec(self, name, path=None, target=None):
        if name != "urllib.request":
            return None
        _unhook()
        from importlib.util import find_spec

        spec = find_spec(name)
        if spec is not None and spec.loader is not None:
            spec.loader = _PatchingLoader(spec.loader)
        return spec


class _PatchingLoader:
    def __init__(self, inner):
        self._inner = inner

    def __getattr__(self, name):
        return getattr(self._inner, name)

    def create_module(self, spec):
        create = getattr(self._inner, "create_module", None)
        return create(spec) if create else None

    def exec_module(self, module):
        module.__spec__.loader = module.__loader__ = self._inner
        self._inner.exec_module(module)
        _patch(module)


def _unhook():
    global _hook
    if _hook in sys.meta_path:
        sys.meta_path.remove(_hook)
    _hook = None


def install():
    """Idempotent. When scripts import urllib.request, `socket` must be importable (real or idj_compat's stub)."""
    global _hook
    if _saved is not None or _hook is not None:
        return
    module = sys.modules.get("urllib.request")
    if module is not None:
        _patch(module)
    else:
        _hook = _ImportHook()
        sys.meta_path.insert(0, _hook)


def _patch(target):
    global _saved
    if _saved is not None:
        return
    no_timeout = getattr(sys.modules.get("socket"), "_GLOBAL_DEFAULT_TIMEOUT", None)

    class HTTPHandler(target.AbstractHTTPHandler):
        """http:// through the host."""

        def __init__(self, debuglevel=None):
            super().__init__(debuglevel or 0)

        def http_open(self, req):
            return open_request(req)

        http_request = target.AbstractHTTPHandler.do_request_

    class HTTPSHandler(target.AbstractHTTPHandler):
        """https:// through the host."""

        def __init__(self, debuglevel=None, context=None, check_hostname=None):
            super().__init__(debuglevel or 0)
            self._context = context
            self._check_hostname = check_hostname

        def https_open(self, req):
            return open_request(req, self._context)

        https_request = target.AbstractHTTPHandler.do_request_

    class ProxyHandler(target.ProxyHandler):
        """Proxies are not available on iOS: requests go out directly."""

        def __init__(self, proxies=None):
            super().__init__({})

    def build_opener(*handlers):
        opener = original_build(*handlers)
        have = any(hasattr(h, "https_open") for h in opener.handlers)
        if not have:  # http.client without TLS support leaves the HTTPS handler out
            opener.add_handler(HTTPSHandler())
        return opener

    def urlopen(url, data=None, timeout=no_timeout, *, context=None, **ignored):
        if context is not None:
            return build_opener(HTTPSHandler(context=context)).open(url, data, timeout)
        if target._opener is None:
            target._opener = build_opener()
        return target._opener.open(url, data, timeout)

    original_build = target.build_opener
    names = ("HTTPHandler", "HTTPSHandler", "ProxyHandler", "build_opener", "urlopen", "_opener")
    _saved = {name: getattr(target, name, None) for name in names}
    for item in (HTTPHandler, HTTPSHandler, ProxyHandler):
        item.__module__ = "urllib.request"
    target.HTTPHandler = HTTPHandler
    target.HTTPSHandler = HTTPSHandler
    target.ProxyHandler = ProxyHandler
    target.build_opener = build_opener
    target.urlopen = urlopen
    target._opener = None


def uninstall():
    """Restore the stdlib handlers (used by the tests)."""
    global _saved
    _unhook()
    if _saved is None:
        return
    import urllib.request as target

    for name, value in _saved.items():
        if value is None and name != "_opener":
            if hasattr(target, name):
                delattr(target, name)
        else:
            setattr(target, name, value)
    _saved = None
