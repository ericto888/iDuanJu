"""parse_url (original implementation for i短剧, GPL-3.0)."""

from typing import NamedTuple, Optional
from urllib.parse import urlsplit

from ..exceptions import LocationParseError


class Url(NamedTuple):
    scheme: Optional[str] = None
    auth: Optional[str] = None
    host: Optional[str] = None
    port: Optional[int] = None
    path: Optional[str] = None
    query: Optional[str] = None
    fragment: Optional[str] = None

    @property
    def hostname(self):
        return self.host

    @property
    def request_uri(self):
        return (self.path or "/") + ("?" + self.query if self.query is not None else "")

    @property
    def netloc(self):
        if self.host is None:
            return None
        return "%s:%d" % (self.host, self.port) if self.port else self.host

    @property
    def url(self):
        out = ""
        if self.scheme is not None:
            out += self.scheme + "://"
        if self.auth is not None:
            out += self.auth + "@"
        out += (self.netloc or "") + (self.path or "")
        if self.query is not None:
            out += "?" + self.query
        if self.fragment is not None:
            out += "#" + self.fragment
        return out

    def __str__(self):
        return self.url


def parse_url(url):
    if not url:
        return Url()
    text = url if "://" in url or url.startswith(("/", "?", "#")) else "//" + url
    try:
        parts = urlsplit(text)
        port = parts.port
    except ValueError as exc:
        raise LocationParseError(url) from exc
    auth = parts.netloc.rpartition("@")[0] or None
    host = parts.hostname
    if host and ":" in host:
        host = "[%s]" % host
    return Url(
        parts.scheme.lower() or None, auth, host or None, port, parts.path or None,
        parts.query if "?" in text else None, parts.fragment if "#" in text else None,
    )
