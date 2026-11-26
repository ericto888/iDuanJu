"""PoolManager.request through the host (original implementation for i短剧, GPL-3.0)."""

from __future__ import annotations

from urllib.parse import urlencode, urljoin, urlsplit

from _idj_http import HostError, exchange, is_timeout, is_tls

from ._collections import HTTPHeaderDict
from .exceptions import (
    ConnectTimeoutError, LocationValueError, MaxRetryError, NewConnectionError, SSLError, URLSchemeUnknown,
)
from .response import HTTPResponse

_IN_URL = frozenset(("DELETE", "GET", "HEAD", "OPTIONS"))
_REDIRECT = (301, 302, 303, 307, 308)


def _timeout(value):
    """float, Timeout or None -> seconds or tuple for the host call."""
    if value is None or isinstance(value, (int, float)):
        return value
    total = getattr(value, "total", None)
    if isinstance(total, (int, float)):
        return total
    parts = [getattr(value, n, None) for n in ("_connect", "_read")]
    parts = [p for p in parts if isinstance(p, (int, float))]
    return max(parts) if parts else None


def _redirects(redirect, retries):
    if not redirect or retries is False:
        return 0
    if isinstance(retries, int):
        return retries
    limit = getattr(retries, "redirect", None)
    if limit is False:
        return 0
    if limit is None:
        limit = getattr(retries, "total", None)
    return 3 if limit is None or limit is True else (0 if limit is False else int(limit))


class RequestMethods:
    def __init__(self, headers=None):
        self.headers = headers or {}

    def request(self, method, url, body=None, fields=None, headers=None, json=None, **urlopen_kw):
        method = method.upper()
        if json is not None and body is not None:
            raise TypeError("request got values for both 'body' and 'json' parameters which are mutually exclusive")
        headers = HTTPHeaderDict(self.headers if headers is None else headers)
        if json is not None:
            import json as _json

            body = _json.dumps(json, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            if "content-type" not in headers:
                headers["Content-Type"] = "application/json"
        if method in _IN_URL:
            return self.request_encode_url(method, url, fields, headers, body=body, **urlopen_kw)
        return self.request_encode_body(method, url, fields, headers, body=body, **urlopen_kw)

    def request_encode_url(self, method, url, fields=None, headers=None, **urlopen_kw):
        if fields:
            url += ("&" if "?" in url else "?") + urlencode(fields)
        return self.urlopen(method, url, headers=self.headers if headers is None else headers, **urlopen_kw)

    def request_encode_body(self, method, url, fields=None, headers=None, encode_multipart=True,
                            multipart_boundary=None, body=None, **urlopen_kw):
        headers = HTTPHeaderDict(self.headers if headers is None else headers)
        if fields:
            if body is not None:
                raise TypeError("request got values for both 'fields' and 'body', can only specify one.")
            if encode_multipart:
                from .filepost import encode_multipart_formdata

                body, content_type = encode_multipart_formdata(fields, multipart_boundary)
            else:
                body, content_type = urlencode(fields), "application/x-www-form-urlencoded"
            if "content-type" not in headers:
                headers["Content-Type"] = content_type
        return self.urlopen(method, url, body=body, headers=headers, **urlopen_kw)


class PoolManager(RequestMethods):
    def __init__(self, num_pools=10, headers=None, **connection_pool_kw):
        super().__init__(headers)
        self.connection_pool_kw = connection_pool_kw

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.clear()

    def clear(self):
        pass

    def _verify(self):
        mode = self.connection_pool_kw.get("cert_reqs")
        if mode is None:
            context = self.connection_pool_kw.get("ssl_context")
            mode = getattr(context, "verify_mode", None)
        return not (mode == "CERT_NONE" or (mode is not None and mode == 0))

    def urlopen(self, method, url, redirect=True, body=None, headers=None, retries=None, timeout=None,
                preload_content=True, decode_content=True, **_):
        method = method.upper()
        scheme = urlsplit(url).scheme.lower()
        if not scheme:
            raise LocationValueError("No host specified.")
        if scheme not in ("http", "https"):
            raise URLSchemeUnknown(scheme)
        headers = HTTPHeaderDict(self.headers if headers is None else headers)
        if hasattr(body, "read"):
            body = body.read()
        if isinstance(body, str):
            body = body.encode("utf-8")
        if retries is None:
            retries = self.connection_pool_kw.get("retries")
        if timeout is None:
            timeout = self.connection_pool_kw.get("timeout")
        left = _redirects(redirect, retries)
        while True:
            sent = dict(headers.itermerged())
            if "user-agent" not in headers:
                sent["User-Agent"] = "python-urllib3/2.2.3"
            try:
                status, _, pairs, content = exchange(method, url, sent, body, _timeout(timeout), self._verify())
            except HostError as exc:
                raise self._translate(exc, url) from exc
            response = HTTPResponse(content, HTTPHeaderDict(pairs), status, reason=_reason(status), request_url=url)
            target = response.headers.get("location") if status in _REDIRECT else None
            if not target or not redirect or retries is False:
                return response
            if left <= 0:
                raise MaxRetryError(self, url, "too many redirects")
            left -= 1
            following = urljoin(url, target)
            if status == 303 and method != "HEAD" or status in (301, 302) and method == "POST":
                method, body = "GET", None
                for name in ("content-type", "content-length", "transfer-encoding"):
                    headers.discard(name)
            if urlsplit(following).netloc != urlsplit(url).netloc:
                for name in ("authorization", "cookie", "proxy-authorization"):
                    headers.discard(name)
            url = following

    def _translate(self, error, url):
        message = error.message
        if is_timeout(message):
            reason = ConnectTimeoutError(self, message)
        elif is_tls(message):
            reason = SSLError(message)
        else:
            reason = NewConnectionError(self, message)
        return MaxRetryError(self, url, reason)

    def connection_from_url(self, url, pool_kwargs=None):
        from .connectionpool import connection_from_url

        return connection_from_url(url, **self.connection_pool_kw)


def _reason(status):
    from http import HTTPStatus

    try:
        return HTTPStatus(status).phrase
    except ValueError:
        return ""


class ProxyManager(PoolManager):
    """Proxies are not available: requests go out directly."""

    def __init__(self, proxy_url, num_pools=10, headers=None, proxy_headers=None, **connection_pool_kw):
        super().__init__(num_pools, headers, **connection_pool_kw)
        self.proxy = proxy_url


def proxy_from_url(url, **kw):
    return ProxyManager(proxy_url=url, **kw)
