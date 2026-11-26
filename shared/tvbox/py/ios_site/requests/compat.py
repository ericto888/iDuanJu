"""Names scripts import from requests.compat (original implementation for i短剧, GPL-3.0)."""

import json
from collections import OrderedDict
from collections.abc import Callable, Mapping, MutableMapping
from io import StringIO
from json import JSONDecodeError
from urllib.parse import (
    quote, quote_plus, unquote, unquote_plus, urldefrag, urlencode, urljoin, urlparse, urlsplit, urlunparse,
)

complexjson = json
builtin_str = str
str = str
bytes = bytes
basestring = (str, bytes)
numeric_types = (int, float)
integer_types = (int,)
is_py2 = False
is_py3 = True
has_simplejson = False


def getproxies():
    return {}


def proxy_bypass(host):
    return False


def __getattr__(name):
    if name == "cookielib":
        import http.cookiejar as cookielib

        return cookielib
    if name == "Morsel":
        from http.cookies import Morsel

        return Morsel
    if name == "chardet":
        import chardet

        return chardet
    raise AttributeError("module 'requests.compat' has no attribute %r" % name)
