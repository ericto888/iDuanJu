"""Transport adapter: sends prepared requests through the host (original implementation for i短剧, GPL-3.0)."""

from __future__ import annotations

import time
from io import BytesIO

from _idj_http import HostError, exchange, is_timeout, is_tls

from .exceptions import ConnectionError, ConnectTimeout, InvalidURL, ReadTimeout, SSLError
from .models import Response
from .structures import CaseInsensitiveDict
from .utils import urldefragauth

DEFAULT_POOLBLOCK = False
DEFAULT_POOLSIZE = 10
DEFAULT_RETRIES = 0
DEFAULT_POOL_TIMEOUT = None


class RawHeaders(CaseInsensitiveDict):
    """Multi-value header view of `response.raw`."""

    def __init__(self, pairs):
        self._pairs = list(pairs)
        super().__init__()
        for key, value in self._pairs:
            self[key] = "%s, %s" % (self[key], value) if key in self else value

    def getlist(self, name, default=()):
        name = name.lower()
        found = [v for k, v in self._pairs if k.lower() == name]
        return found if found else list(default)

    get_all = getheaders = getallmatchingheaders = iget = getlist

    def iteritems(self):
        return iter(self._pairs)


class RawResponse:
    """Buffered stand-in for urllib3's response: `response.raw`."""

    def __init__(self, status, reason, pairs, body, url):
        self.status = status
        self.reason = reason
        self.headers = self.msg = RawHeaders(pairs)
        self.version = 11
        self.decode_content = True
        self._url = url
        self._body = body
        self._fp = BytesIO(body)

    @property
    def data(self):
        return self._body

    @property
    def closed(self):
        return self._fp.closed

    def readable(self):
        return True

    def read(self, amt=None, decode_content=None, cache_content=False):
        if self._fp.closed:
            return b""
        return self._fp.read() if amt is None else self._fp.read(amt)

    read1 = read

    def readline(self, *args):
        return self._fp.readline(*args)

    def readinto(self, buffer):
        return self._fp.readinto(buffer)

    def stream(self, amt=2 ** 16, decode_content=None):
        while True:
            chunk = self.read(amt)
            if not chunk:
                return
            yield chunk

    read_chunked = stream

    def tell(self):
        return self._fp.tell()

    def getheader(self, name, default=None):
        return self.headers.get(name, default)

    def getheaders(self):
        return list(self.headers.items())

    def info(self):
        return self.headers

    def geturl(self):
        return self._url

    def isclosed(self):
        return self._fp.closed

    def close(self):
        self._fp.close()

    def release_conn(self):
        pass

    def drain_conn(self):
        pass

    def __iter__(self):
        return self.stream(128)


def _reason(status):
    from http import HTTPStatus

    try:
        return HTTPStatus(status).phrase
    except ValueError:
        return ""


class BaseAdapter:
    def send(self, request, stream=False, timeout=None, verify=True, cert=None, proxies=None):
        raise NotImplementedError

    def close(self):
        raise NotImplementedError


class HTTPAdapter(BaseAdapter):
    """Sends requests through the host. Pool and retry settings are accepted and kept, the host manages connections."""

    def __init__(self, pool_connections=DEFAULT_POOLSIZE, pool_maxsize=DEFAULT_POOLSIZE, max_retries=DEFAULT_RETRIES,
                 pool_block=DEFAULT_POOLBLOCK):
        self.max_retries = max_retries
        self.config = {}
        self.proxy_manager = {}
        self.poolmanager = None
        self._pool_connections = pool_connections
        self._pool_maxsize = pool_maxsize
        self._pool_block = pool_block
        # Subclasses override this to pass an SSL context; it has nothing to configure here.
        self.init_poolmanager(pool_connections, pool_maxsize, block=pool_block)

    def init_poolmanager(self, connections, maxsize, block=DEFAULT_POOLBLOCK, **pool_kwargs):
        self._pool_kwargs = pool_kwargs

    def proxy_manager_for(self, proxy, **proxy_kwargs):
        raise NotImplementedError("requests（iOS 版）不支持代理 proxy_manager_for()")

    def cert_verify(self, conn, url, verify, cert):
        pass

    def add_headers(self, request, **kwargs):
        pass

    def request_url(self, request, proxies):
        return request.path_url

    def build_connection_pool_key_attributes(self, request, verify, cert=None):
        return {}, {}

    def build_response(self, req, resp):
        response = Response()
        response.status_code = resp.status
        response.headers = CaseInsensitiveDict(resp.headers.items())
        response._encoding_from_headers()
        response.raw = resp
        response.reason = resp.reason
        response.url = req.url
        response.request = req
        response.connection = self
        response.cookies.extract(resp.headers.getlist("set-cookie"), req.url)
        return response

    def send(self, request, stream=False, timeout=None, verify=True, cert=None, proxies=None):
        if cert:
            raise NotImplementedError("requests（iOS 版）不支持客户端证书 cert=")
        url = urldefragauth(request.url)  # credentials travel in the Authorization header
        self.add_headers(request, stream=stream, timeout=timeout, verify=verify, cert=cert, proxies=proxies)
        started = time.monotonic()
        try:
            status, _, pairs, body = exchange(
                request.method, url, request.headers, request.body_bytes(), timeout,
                True if verify is None else bool(verify),
            )
        except HostError as exc:
            raise _translate(exc, request) from exc
        response = self.build_response(request, RawResponse(status, _reason(status), pairs, body, request.url))
        response._elapsed = time.monotonic() - started
        response.content  # already in memory
        response.raw = RawResponse(status, response.reason, pairs, body, request.url)
        return response

    def close(self):
        pass


def _translate(error, request):
    """HostError -> requests exception."""
    message = error.message
    where = "%s（%s）" % (message, request.url)
    low = message.lower()
    if is_timeout(message):
        kind = ConnectTimeout if "connect" in low and "read" not in low or "连接超时" in message else ReadTimeout
    elif is_tls(message):
        kind = SSLError
    elif "unsupported url" in low or "invalid url" in low or "无效的 url" in low or "无效 url" in low:
        kind = InvalidURL
    else:
        kind = ConnectionError
    return kind(where, request=request)


def __getattr__(name):
    if name == "Retry":
        from urllib3.util.retry import Retry

        return Retry
    if name == "PoolManager":
        from urllib3.poolmanager import PoolManager

        return PoolManager
    raise AttributeError("module 'requests.adapters' has no attribute %r" % name)
