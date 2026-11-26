"""Authentication helpers (original implementation for i短剧, GPL-3.0)."""

from _idj_bridge import b64e


def _bytes(value):
    if isinstance(value, bytes):
        return value
    value = str(value)
    try:
        return value.encode("latin-1")
    except UnicodeEncodeError:
        return value.encode("utf-8")


def _basic_auth_str(username, password):
    return "Basic " + b64e(_bytes(username) + b":" + _bytes(password))


class AuthBase:
    def __call__(self, r):
        raise NotImplementedError("Auth hooks must be callable.")


class HTTPBasicAuth(AuthBase):
    def __init__(self, username, password):
        self.username = username
        self.password = password

    def __eq__(self, other):
        return self.username == getattr(other, "username", None) and self.password == getattr(other, "password", None)

    def __ne__(self, other):
        return not self == other

    def __hash__(self):
        return hash((self.username, self.password))

    def __call__(self, r):
        r.headers["Authorization"] = _basic_auth_str(self.username, self.password)
        return r


class HTTPProxyAuth(HTTPBasicAuth):
    def __call__(self, r):
        r.headers["Proxy-Authorization"] = _basic_auth_str(self.username, self.password)
        return r


class HTTPDigestAuth(AuthBase):
    def __init__(self, username, password):
        self.username = username
        self.password = password

    def __call__(self, r):
        raise NotImplementedError("requests（iOS 版）不支持 HTTPDigestAuth")
