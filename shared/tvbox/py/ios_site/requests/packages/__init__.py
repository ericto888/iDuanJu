"""`requests.packages.urllib3…` aliases (original implementation for i短剧, GPL-3.0)."""

import sys

import urllib3
import urllib3.connectionpool
import urllib3.exceptions
import urllib3.filepost
import urllib3.poolmanager
import urllib3.response
import urllib3.util.retry
import urllib3.util.ssl_
import urllib3.util.timeout
import urllib3.util.url

for _name in list(sys.modules):
    if _name == "urllib3" or _name.startswith("urllib3."):
        sys.modules["requests.packages." + _name] = sys.modules[_name]


def __getattr__(name):
    if name in ("chardet", "idna"):
        import importlib

        return importlib.import_module(name)
    raise AttributeError("module 'requests.packages' has no attribute %r" % name)
