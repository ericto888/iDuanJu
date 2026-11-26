"""Exception hierarchy (original implementation for i短剧, GPL-3.0)."""

from json import JSONDecodeError as _JSONDecodeError


class RequestException(IOError):
    """Base of everything requests raises."""

    def __init__(self, *args, **kwargs):
        response = kwargs.pop("response", None)
        self.response = response
        self.request = kwargs.pop("request", None)
        if response is not None and not self.request and hasattr(response, "request"):
            self.request = response.request
        super().__init__(*args, **kwargs)


class InvalidJSONError(RequestException):
    pass


class JSONDecodeError(InvalidJSONError, _JSONDecodeError):
    """The body is not valid JSON."""

    def __init__(self, *args, **kwargs):
        _JSONDecodeError.__init__(self, *args)
        InvalidJSONError.__init__(self, *self.args, **kwargs)

    def __reduce__(self):
        return _JSONDecodeError.__reduce__(self)


class HTTPError(RequestException):
    pass


class ConnectionError(RequestException):
    pass


class ProxyError(ConnectionError):
    pass


class SSLError(ConnectionError):
    pass


class Timeout(RequestException):
    pass


class ConnectTimeout(ConnectionError, Timeout):
    pass


class ReadTimeout(Timeout):
    pass


class URLRequired(RequestException):
    pass


class TooManyRedirects(RequestException):
    pass


class MissingSchema(RequestException, ValueError):
    pass


class InvalidSchema(RequestException, ValueError):
    pass


class InvalidURL(RequestException, ValueError):
    pass


class InvalidHeader(RequestException, ValueError):
    pass


class InvalidProxyURL(InvalidURL):
    pass


class ChunkedEncodingError(RequestException):
    pass


class ContentDecodingError(RequestException):
    pass


class StreamConsumedError(RequestException, TypeError):
    pass


class RetryError(RequestException):
    pass


class UnrewindableBodyError(RequestException):
    pass


class RequestsWarning(Warning):
    pass


class FileModeWarning(RequestsWarning, DeprecationWarning):
    pass


class RequestsDependencyWarning(RequestsWarning):
    pass
