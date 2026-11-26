"""Cookie jar (original implementation for i短剧, GPL-3.0).

Follows the rules scripts can observe in the stdlib jar (suffix domain match, path prefix match, expiry, secure) without
importing `http.cookiejar`, which would drag in sockets.
"""

from __future__ import annotations

import re
import time
from collections.abc import MutableMapping
from urllib.parse import urlsplit


class CookieConflictError(RuntimeError):
    """Several cookies match; be more specific with domain and path."""


_MONTHS = {m: i + 1 for i, m in enumerate("jan feb mar apr may jun jul aug sep oct nov dec".split())}
_DATE = re.compile(r"(\d{1,2})[\s-]+([A-Za-z]{3})[a-z]*[\s-]+(\d{2,4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?")
_ASCTIME = re.compile(r"([A-Za-z]{3})\s+(\d{1,2})\s+(\d{1,2}):(\d{2}):(\d{2})\s+(\d{4})")


def _timestamp(text):
    """HTTP date -> seconds since the epoch, or None."""
    from calendar import timegm

    found = _DATE.search(text)
    if found:
        day, month, year, hour, minute, second = found.groups()
    else:
        found = _ASCTIME.search(text)
        if not found:
            return None
        month, day, hour, minute, second, year = found.groups()
    number = _MONTHS.get(month.lower()[:3])
    if not number:
        return None
    year = int(year)
    if year < 100:
        year += 2000 if year < 70 else 1900
    try:
        return timegm((year, number, int(day), int(hour), int(minute), int(second or 0)))
    except (ValueError, OverflowError):
        return None


class Cookie:
    """One cookie, with the attributes of http.cookiejar.Cookie."""

    def __init__(self, version, name, value, port, port_specified, domain, domain_specified, domain_initial_dot, path,
                 path_specified, secure, expires, discard, comment, comment_url, rest, rfc2109=False):
        self.version = version
        self.name = name
        self.value = value
        self.port = port
        self.port_specified = port_specified
        self.domain = (domain or "").lower()
        self.domain_specified = domain_specified
        self.domain_initial_dot = domain_initial_dot
        self.path = path
        self.path_specified = path_specified
        self.secure = secure
        self.expires = int(float(expires)) if expires is not None else None
        self.discard = discard
        self.comment = comment
        self.comment_url = comment_url
        self.rfc2109 = rfc2109
        self._rest = dict(rest or {})

    def has_nonstandard_attr(self, name):
        return name in self._rest

    def get_nonstandard_attr(self, name, default=None):
        return self._rest.get(name, default)

    def set_nonstandard_attr(self, name, value):
        self._rest[name] = value

    def is_expired(self, now=None):
        return self.expires is not None and self.expires <= (time.time() if now is None else now)

    def __copy__(self):
        clone = Cookie.__new__(Cookie)
        clone.__dict__.update(self.__dict__)
        clone._rest = dict(self._rest)
        return clone

    def __repr__(self):
        return "Cookie(name=%r, value=%r, domain=%r, path=%r)" % (self.name, self.value, self.domain, self.path)

    def __str__(self):
        return "<Cookie %s=%s for %s%s>" % (self.name, self.value, self.domain, self.path)


def create_cookie(name, value, **kwargs):
    """Cookie from keyword arguments; an empty domain means "every host"."""
    fields = {
        "version": 0, "name": name, "value": value, "port": None, "domain": "", "path": "/", "secure": False,
        "expires": None, "discard": True, "comment": None, "comment_url": None, "rest": {"HttpOnly": None},
        "rfc2109": False,
    }
    unknown = set(kwargs) - set(fields)
    if unknown:
        raise TypeError("create_cookie() got unexpected keyword arguments: %s" % sorted(unknown))
    fields.update(kwargs)
    fields["port_specified"] = bool(fields["port"])
    fields["domain_specified"] = bool(fields["domain"])
    fields["domain_initial_dot"] = (fields["domain"] or "").startswith(".")
    fields["path_specified"] = bool(fields["path"])
    return Cookie(**fields)


def morsel_to_cookie(morsel):
    """http.cookies.Morsel -> Cookie."""
    expires = None
    if morsel["max-age"]:
        try:
            expires = int(time.time() + int(morsel["max-age"]))
        except ValueError:
            raise TypeError("max-age: %s must be integer" % morsel["max-age"]) from None
    elif morsel["expires"]:
        expires = _timestamp(morsel["expires"])
    return create_cookie(
        morsel.key, morsel.value, domain=morsel["domain"], path=morsel["path"] or "/", secure=bool(morsel["secure"]),
        expires=expires, discard=False, comment=morsel["comment"] or None, rest={"HttpOnly": morsel["httponly"]},
    )


def _host(url):
    return (urlsplit(url).hostname or "").lower()


def _parse_set_cookie(header, url):
    """One Set-Cookie header value -> Cookie, or None when it is malformed or not allowed for this host."""
    first, *attributes = header.split(";")
    name, eq, value = first.partition("=")
    name, value = name.strip(), value.strip() if eq else None
    if not name:
        return None
    parts = urlsplit(url)
    host = (parts.hostname or "").lower()
    known = {}
    for item in attributes:
        key, sep, data = item.partition("=")
        known[key.strip().lower()] = data.strip() if sep else None
    domain = (known.get("domain") or "").strip('"').lower()
    specified = bool(domain)
    if specified:
        if not domain.startswith("."):
            domain = "." + domain
        if not ("." + host).endswith(domain) or ("." not in domain[1:] and domain[1:] != host):
            return None
    else:
        domain = host
    path = known.get("path")
    path_specified = bool(path) and path.startswith("/")
    if not path_specified:
        path = (parts.path or "/").rpartition("/")[0] or "/"
    expires, discard = None, True
    if known.get("max-age"):
        try:
            expires, discard = int(time.time() + float(known["max-age"].strip('"'))), False
        except (ValueError, OverflowError):
            pass
    if discard and known.get("expires"):
        expires = _timestamp(known["expires"])
        discard = expires is None
    return Cookie(
        version=0, name=name, value=value, port=None, port_specified=False, domain=domain, domain_specified=specified,
        domain_initial_dot=specified, path=path, path_specified=path_specified, secure="secure" in known,
        expires=expires, discard=discard, comment=known.get("comment"), comment_url=None,
        rest={"HttpOnly": None} if "httponly" in known else {},
    )


class RequestsCookieJar(MutableMapping):
    """Cookie jar with a dict interface (names -> values)."""

    def __init__(self, policy=None):
        self._cookies = {}  # (domain, path, name) -> Cookie
        self._policy = policy

    # -- cookie level ------------------------------------------------------------------------------------------------
    def _all(self):
        return list(self._cookies.values())

    def __iter__(self):
        return iter(self._all())

    def __len__(self):
        return len(self._cookies)

    def set_cookie(self, cookie, *args, **kwargs):
        value = cookie.value
        if isinstance(value, str) and value.startswith('"') and value.endswith('"'):
            cookie.value = value.replace('\\"', "")
        self._cookies[(cookie.domain, cookie.path, cookie.name)] = cookie

    def set_cookie_if_ok(self, cookie, request=None):
        self.set_cookie(cookie)

    def extract(self, headers, url):
        """Store the cookies of Set-Cookie header values received from `url`."""
        for header in headers:
            cookie = _parse_set_cookie(header, url)
            if cookie is None:
                continue
            if cookie.is_expired():
                self._cookies.pop((cookie.domain, cookie.path, cookie.name), None)
            else:
                self.set_cookie(cookie)

    def extract_cookies(self, response, request):
        """CookieJar API: response needs `.info()` (or `.headers`), request a URL."""
        headers = response.info() if hasattr(response, "info") else response.headers
        values = headers.get_all("Set-Cookie", []) if hasattr(headers, "get_all") else headers.getlist("set-cookie")
        url = request.get_full_url() if hasattr(request, "get_full_url") else getattr(request, "url", request)
        self.extract(values or (), url)

    def matching(self, url):
        """Cookies to send to `url`, longest path first."""
        parts = urlsplit(url)
        host = "." + (parts.hostname or "").lower()
        path = parts.path or "/"
        secure = parts.scheme.lower() in ("https", "wss")
        now = time.time()
        out = []
        for cookie in self._all():
            if cookie.is_expired(now):
                continue
            if cookie.secure and not secure:
                continue
            domain = cookie.domain
            if domain and not host.endswith(domain if domain.startswith(".") else "." + domain):
                continue
            scope = cookie.path or "/"
            if path != scope and not (
                path.startswith(scope) and (scope.endswith("/") or path[len(scope):len(scope) + 1] == "/")
            ):
                continue
            out.append(cookie)
        out.sort(key=lambda c: -len(c.path or ""))
        return out

    def header(self, url):
        """Cookie header for `url`, or None."""
        pairs = []
        for cookie in self.matching(url):
            pairs.append(cookie.name if cookie.value is None else "%s=%s" % (cookie.name, cookie.value))
        return "; ".join(pairs) or None

    def add_cookie_header(self, request):
        """CookieJar API for urllib requests."""
        value = self.header(request.get_full_url())
        if value and not request.has_header("Cookie"):
            request.add_unredirected_header("Cookie", value)

    def clear(self, domain=None, path=None, name=None):
        if domain is None and path is None and name is None:
            self._cookies.clear()
            return
        if domain is None or (name is not None and path is None):
            raise ValueError("domain (and path) must be given to remove a cookie by path or name")
        hits = [
            key for key in self._cookies
            if key[0] == domain and (path is None or key[1] == path) and (name is None or key[2] == name)
        ]
        if not hits:
            raise KeyError((domain, path, name))
        for key in hits:
            del self._cookies[key]

    def clear_session_cookies(self):
        for key, cookie in list(self._cookies.items()):
            if cookie.discard:
                del self._cookies[key]

    def clear_expired_cookies(self):
        for key, cookie in list(self._cookies.items()):
            if cookie.is_expired():
                del self._cookies[key]

    def get_policy(self):
        return self._policy

    def set_policy(self, policy):
        self._policy = policy

    # -- dict level --------------------------------------------------------------------------------------------------
    def _pick(self, name, domain=None, path=None):
        return [
            c for c in self._all()
            if c.name == name and (domain is None or c.domain == domain) and (path is None or c.path == path)
        ]

    def _find(self, name, domain=None, path=None):
        found = self._pick(name, domain, path)
        if not found:
            raise KeyError("name=%r, domain=%r, path=%r" % (name, domain, path))
        return found[0].value

    def _find_no_duplicates(self, name, domain=None, path=None):
        found = [c for c in self._pick(name, domain, path) if c.value is not None]
        if len(found) > 1:
            raise CookieConflictError("There are multiple cookies with name, %r" % name)
        if not found:
            raise KeyError("name=%r, domain=%r, path=%r" % (name, domain, path))
        return found[0].value

    def get(self, name, default=None, domain=None, path=None):
        try:
            return self._find_no_duplicates(name, domain, path)
        except KeyError:
            return default

    def set(self, name, value, **kwargs):
        if value is None:
            for cookie in self._pick(name, kwargs.get("domain"), kwargs.get("path")):
                self._cookies.pop((cookie.domain, cookie.path, cookie.name), None)
            return None
        cookie = morsel_to_cookie(value) if hasattr(value, "coded_value") else create_cookie(name, value, **kwargs)
        self.set_cookie(cookie)
        return cookie

    def __getitem__(self, name):
        return self._find_no_duplicates(name)

    def __setitem__(self, name, value):
        self.set(name, value)

    def __delitem__(self, name):
        for cookie in self._pick(name):
            del self._cookies[(cookie.domain, cookie.path, cookie.name)]

    def __contains__(self, name):
        if isinstance(name, Cookie):
            return name in self._cookies.values()
        return any(c.name == name for c in self._cookies.values())

    def iterkeys(self):
        return iter(self.keys())

    def keys(self):
        return [c.name for c in self._all()]

    def itervalues(self):
        return iter(self.values())

    def values(self):
        return [c.value for c in self._all()]

    def iteritems(self):
        return iter(self.items())

    def items(self):
        return [(c.name, c.value) for c in self._all()]

    def list_domains(self):
        return list(dict.fromkeys(c.domain for c in self._all()))

    def list_paths(self):
        return list(dict.fromkeys(c.path for c in self._all()))

    def multiple_domains(self):
        seen = set()
        for cookie in self._all():
            if cookie.domain is not None and cookie.domain in seen:
                return True
            seen.add(cookie.domain)
        return False

    def get_dict(self, domain=None, path=None):
        return {
            c.name: c.value for c in self._all()
            if (domain is None or c.domain == domain) and (path is None or c.path == path)
        }

    def update(self, other=(), **kwargs):
        from copy import copy

        if isinstance(other, RequestsCookieJar) or _is_std_jar(other):
            for cookie in other:
                self.set_cookie(copy(cookie))
        else:
            pairs = other.items() if hasattr(other, "items") else other
            for name, value in pairs:
                self.set(name, value)
        for name, value in kwargs.items():
            self.set(name, value)

    def copy(self):
        clone = RequestsCookieJar(self._policy)
        clone.update(self)
        return clone

    def __eq__(self, other):
        return self is other

    __hash__ = None

    def __repr__(self):
        return "<RequestsCookieJar[%s]>" % ", ".join(repr(c) for c in self._all())


def _is_std_jar(value):
    import sys

    module = sys.modules.get("http.cookiejar")
    return module is not None and isinstance(value, module.CookieJar)


def is_jar(value):
    return isinstance(value, RequestsCookieJar) or _is_std_jar(value)


def cookiejar_from_dict(cookie_dict, cookiejar=None, overwrite=True):
    if cookiejar is None:
        cookiejar = RequestsCookieJar()
    if cookie_dict is not None:
        names = {c.name for c in cookiejar}
        for name, value in dict(cookie_dict).items():
            if overwrite or name not in names:
                cookiejar.set_cookie(create_cookie(name, value))
    return cookiejar


def merge_cookies(cookiejar, cookies):
    """Add a dict or jar of cookies to `cookiejar`."""
    if not isinstance(cookiejar, RequestsCookieJar) and not _is_std_jar(cookiejar):
        raise ValueError("You can only merge into CookieJar")
    if isinstance(cookies, RequestsCookieJar) or _is_std_jar(cookies):
        for cookie in cookies:
            cookiejar.set_cookie(cookie)
    elif cookies:
        cookiejar_from_dict(cookies, cookiejar, overwrite=False)
    return cookiejar


def remove_cookie_by_name(cookiejar, name, domain=None, path=None):
    for cookie in list(cookiejar):
        if cookie.name == name and domain in (None, cookie.domain) and path in (None, cookie.path):
            cookiejar.clear(cookie.domain, cookie.path, cookie.name)


def get_cookie_header(jar, request):
    """Cookie header value for a request with `.url`."""
    if isinstance(jar, RequestsCookieJar):
        return jar.header(request.url)
    own = RequestsCookieJar()
    own.update(jar)
    return own.header(request.url)


def extract_cookies_to_jar(jar, request, response):
    """response: the raw object of a Response (`.headers.getlist`)."""
    headers = getattr(response, "headers", None)
    if headers is None or not hasattr(headers, "getlist"):
        return
    values = headers.getlist("set-cookie")
    if not values:
        return
    if isinstance(jar, RequestsCookieJar):
        jar.extract(values, request.url)
    else:
        own = RequestsCookieJar()
        own.extract(values, request.url)
        for cookie in own:
            jar.set_cookie(cookie)
