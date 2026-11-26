"""certifi-compatible names; certificates are checked by the host (original implementation for i短剧, GPL-3.0)."""

import os as _os

__version__ = "2024.08.30"
__all__ = ["where", "contents"]


def where():
    """Path handed to `verify=` or an SSL context; nothing reads it."""
    return _os.path.join(_os.path.dirname(__file__), "cacert.pem")


def contents():
    raise NotImplementedError("certifi（iOS 版）不带 CA 证书，证书由系统校验")
