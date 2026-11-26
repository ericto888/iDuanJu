"""requests-compatible API for i短剧 spiders on iOS.

Original implementation (GPL-3.0) on top of the host's `http` function; not a copy of Requests.
"""

from . import adapters, auth, compat, cookies, exceptions, hooks, models, sessions, status_codes, structures, utils
from .__version__ import __author__, __build__, __description__, __license__, __title__, __url__, __version__
from .api import delete, get, head, options, patch, post, put, request
from .exceptions import (
    ConnectionError, ConnectTimeout, FileModeWarning, HTTPError, JSONDecodeError, ReadTimeout, RequestException,
    Timeout, TooManyRedirects, URLRequired,
)
from .models import PreparedRequest, Request, Response
from .sessions import Session, session
from .status_codes import codes

__all__ = [
    "request", "get", "options", "head", "post", "put", "patch", "delete", "Session", "session", "Request", "Response",
    "PreparedRequest", "codes", "RequestException", "HTTPError", "ConnectionError", "Timeout", "ReadTimeout",
    "ConnectTimeout", "TooManyRedirects", "URLRequired", "JSONDecodeError",
]


def __getattr__(name):
    # `requests.packages.urllib3.disable_warnings()` works without an explicit import.
    if name in ("packages", "urllib3", "certs"):
        import importlib

        module = importlib.import_module("urllib3" if name == "urllib3" else "requests." + name)
        globals()[name] = module
        return module
    raise AttributeError("module 'requests' has no attribute %r" % name)
