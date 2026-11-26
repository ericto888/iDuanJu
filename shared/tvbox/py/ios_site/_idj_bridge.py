"""Bridge to the native script host (`_idj_host`).

Original code for i短剧 (GPL-3.0). See shared/tvbox/HOST_ABI.md for the wire format:
`_idj_host.call(name, args_json)` returns `{"v": value}` or `{"e": "message"}`; binary values travel as Base64.
"""

from __future__ import annotations

from binascii import Error as _B64Error
from binascii import a2b_base64, b2a_base64
from json import dumps as _dumps
from json import loads as _loads

__all__ = ["HostError", "call", "b64e", "b64d", "scrub"]

_native = None


class HostError(RuntimeError):
    """The native host answered `{"e": ...}` (or is not reachable at all)."""

    def __init__(self, message, function=""):
        super().__init__(message)
        self.message = message
        self.function = function

    def __str__(self):
        return "%s: %s" % (self.function, self.message) if self.function else str(self.message)


def _host():
    global _native
    if _native is None:
        try:
            import _idj_host
        except ImportError as exc:
            raise HostError("_idj_host 不可用（脚本未在 i短剧 宿主内运行）: %s" % exc) from exc
        _native = _idj_host
    return _native


def scrub(text):
    """Join surrogate pairs and replace lone surrogates, which cannot be carried as UTF-8."""
    return text.encode("utf-16-le", "surrogatepass").decode("utf-16-le", "replace")


def call(name, /, **args):
    """Call host function `name`; returns the decoded `v`, raises HostError for `e`."""
    native = _host()
    payload = _dumps(args, ensure_ascii=False)
    try:
        raw = native.call(name, payload)
    except UnicodeEncodeError:
        raw = native.call(name, scrub(payload))
    try:
        reply = _loads(raw)
    except ValueError as exc:
        raise HostError("宿主返回了无效 JSON: %s" % exc, name) from exc
    if not isinstance(reply, dict):
        raise HostError("宿主返回了无效结果: %.80r" % (raw,), name)
    error = reply.get("e")
    if error is not None:
        raise HostError(str(error), name)
    return reply.get("v")


def b64e(data):
    """bytes-like -> Base64 text."""
    return b2a_base64(bytes(data), newline=False).decode("ascii")


def b64d(text):
    """Base64 text (or None) -> bytes."""
    if not text:
        return b""
    try:
        return a2b_base64(text)
    except _B64Error as exc:
        raise HostError("宿主返回了无效 Base64: %s" % exc) from exc
