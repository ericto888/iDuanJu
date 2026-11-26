"""Exception names of urllib3 (original implementation for i短剧, GPL-3.0)."""


class HTTPError(Exception):
    pass


class HTTPWarning(Warning):
    pass


class PoolError(HTTPError):
    def __init__(self, pool, message):
        self.pool = pool
        super().__init__("%s: %s" % (pool, message))


class RequestError(PoolError):
    def __init__(self, pool, url, message):
        self.url = url
        super().__init__(pool, message)


class SSLError(HTTPError):
    pass


class ProxyError(HTTPError):
    def __init__(self, message, error=None):
        super().__init__(message, error)
        self.original_error = error


class DecodeError(HTTPError):
    pass


class ProtocolError(HTTPError):
    pass


ConnectionError = ProtocolError


class MaxRetryError(RequestError):
    def __init__(self, pool, url, reason=None):
        self.reason = reason
        super().__init__(pool, url, "Max retries exceeded with url: %s (Caused by %r)" % (url, reason))


class HostChangedError(RequestError):
    def __init__(self, pool, url, retries=3):
        super().__init__(pool, url, "Tried to open a foreign host with url: %s" % url)
        self.retries = retries


class TimeoutStateError(HTTPError):
    pass


class TimeoutError(HTTPError):
    pass


class ReadTimeoutError(TimeoutError, RequestError):
    pass


class ConnectTimeoutError(TimeoutError):
    pass


class NewConnectionError(HTTPError):
    def __init__(self, conn, message):
        self.conn = conn
        super().__init__("%s: %s" % (conn, message))


class NameResolutionError(NewConnectionError):
    pass


class EmptyPoolError(PoolError):
    pass


class FullPoolError(PoolError):
    pass


class ClosedPoolError(PoolError):
    pass


class LocationValueError(ValueError, HTTPError):
    pass


class LocationParseError(LocationValueError):
    def __init__(self, location):
        super().__init__("Failed to parse: %s" % location)
        self.location = location


class URLSchemeUnknown(LocationValueError):
    def __init__(self, scheme):
        super().__init__("Not supported URL scheme %s" % scheme)
        self.scheme = scheme


class ResponseError(HTTPError):
    GENERIC_ERROR = "too many error responses"
    SPECIFIC_ERROR = "too many {status_code} error responses"


class SecurityWarning(HTTPWarning):
    pass


class InsecureRequestWarning(SecurityWarning):
    pass


class NotOpenSSLWarning(SecurityWarning):
    pass


class SystemTimeWarning(SecurityWarning):
    pass


class InsecurePlatformWarning(SecurityWarning):
    pass


class SNIMissingWarning(HTTPWarning):
    pass


class DependencyWarning(HTTPWarning):
    pass


class SubjectAltNameWarning(SecurityWarning):
    pass


class ResponseNotChunked(ProtocolError, ValueError):
    pass


class BodyNotHttplibCompatible(HTTPError):
    pass


class IncompleteRead(HTTPError):
    pass


class InvalidChunkLength(HTTPError):
    pass


class InvalidHeader(HTTPError):
    pass


class ProxySchemeUnknown(AssertionError, URLSchemeUnknown):
    pass


class ProxySchemeUnsupported(ValueError):
    pass


class HeaderParsingError(HTTPError):
    pass


class UnrewindableBodyError(HTTPError):
    pass
