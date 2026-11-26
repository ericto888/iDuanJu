"""Connection pools bound to one host (original implementation for i短剧, GPL-3.0)."""

from urllib.parse import urlsplit

from .poolmanager import PoolManager


class HTTPConnectionPool(PoolManager):
    scheme = "http"

    def __init__(self, host, port=None, headers=None, **conn_kw):
        super().__init__(headers=headers, **conn_kw)
        self.host = host
        self.port = port

    def urlopen(self, method, url, *args, **kwargs):
        if url.startswith("/"):
            host = "[%s]" % self.host if ":" in self.host else self.host
            url = "%s://%s%s%s" % (self.scheme, host, ":%d" % self.port if self.port else "", url)
        return super().urlopen(method, url, *args, **kwargs)

    def close(self):
        pass


class HTTPSConnectionPool(HTTPConnectionPool):
    scheme = "https"


def connection_from_url(url, **kw):
    parts = urlsplit(url)
    kind = HTTPSConnectionPool if parts.scheme == "https" else HTTPConnectionPool
    return kind(parts.hostname, parts.port, **kw)
