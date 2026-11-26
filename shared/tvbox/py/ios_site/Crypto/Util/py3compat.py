"""Names older scripts import from Crypto.Util.py3compat (original implementation for i短剧, GPL-3.0)."""

from io import BytesIO, StringIO


def b(s):
    return s.encode("latin-1")


def bchr(s):
    return bytes([s])


def bstr(s):
    return bytes(s, "latin-1") if isinstance(s, str) else bytes(s)


def bord(s):
    return s


def tobytes(s, encoding="latin-1"):
    return s.encode(encoding) if isinstance(s, str) else bytes(s)


def tostr(bs):
    return bs.decode("latin-1")


def is_native_int(x):
    return isinstance(x, int)


def is_string(x):
    return isinstance(x, str)


def is_bytes(x):
    return isinstance(x, (bytes, bytearray, memoryview))


def byte_string(s):
    return isinstance(s, bytes)
