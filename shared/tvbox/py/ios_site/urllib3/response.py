"""Buffered response object (original implementation for i短剧, GPL-3.0)."""

from __future__ import annotations

from io import BytesIO

from ._collections import HTTPHeaderDict


class HTTPResponse:
    def __init__(self, body=b"", headers=None, status=0, version=11, reason=None, preload_content=True,
                 decode_content=True, request_method=None, request_url=None, retries=None, **_):
        self.headers = headers if isinstance(headers, HTTPHeaderDict) else HTTPHeaderDict(headers)
        self.status = status
        self.version = version
        self.reason = reason
        self.retries = retries
        self.decode_content = decode_content
        self._url = request_url
        self._body = body if isinstance(body, bytes) else body.encode("utf-8")
        self._fp = BytesIO(self._body)

    @property
    def data(self):
        return self._body

    @property
    def url(self):
        return self._url

    @property
    def closed(self):
        return self._fp.closed

    def json(self):
        import json

        return json.loads(self._body.decode("utf-8"))

    def read(self, amt=None, decode_content=None, cache_content=False):
        if self._fp.closed:
            return b""
        return self._fp.read() if amt is None else self._fp.read(amt)

    read1 = read

    def readline(self, *args):
        return self._fp.readline(*args)

    def readinto(self, buffer):
        return self._fp.readinto(buffer)

    def readable(self):
        return True

    def stream(self, amt=2 ** 16, decode_content=None):
        while True:
            chunk = self.read(amt)
            if not chunk:
                return
            yield chunk

    read_chunked = stream

    def __iter__(self):
        return iter(self._fp)

    def tell(self):
        return self._fp.tell()

    def getheader(self, name, default=None):
        return self.headers.get(name, default)

    def getheaders(self):
        return self.headers

    def info(self):
        return self.headers

    def geturl(self):
        return self._url

    def get_redirect_location(self):
        return self.headers.get("location") if self.status in (301, 302, 303, 307, 308) else False

    def close(self):
        self._fp.close()

    def isclosed(self):
        return self._fp.closed

    def release_conn(self):
        pass

    def drain_conn(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


BaseHTTPResponse = HTTPResponse
