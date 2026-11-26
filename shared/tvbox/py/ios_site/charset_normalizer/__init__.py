"""charset_normalizer-compatible minimum (original implementation for i短剧, GPL-3.0)."""

import _idj_text

__version__ = "3.4.0"


def detect(byte_str, should_rename_legacy=False, **kwargs):
    if not isinstance(byte_str, (bytes, bytearray)):
        raise TypeError("Expected object of type bytes or bytearray, got: %s" % type(byte_str))
    encoding, confidence = _idj_text.detect(bytes(byte_str))
    return {"encoding": encoding, "confidence": confidence, "language": ""}


class CharsetMatch:
    def __init__(self, data, encoding):
        self.raw = data
        self.encoding = encoding
        self.language = "Chinese" if encoding in ("gb18030", "big5") else "Unknown"

    def __str__(self):
        return _idj_text.decode(self.raw, self.encoding, "replace")

    def output(self, encoding="utf_8"):
        return str(self).encode(encoding, "replace")


class CharsetMatches(list):
    def best(self):
        return self[0] if self else None

    first = best


def from_bytes(sequences, *args, **kwargs):
    data = bytes(sequences)
    encoding = _idj_text.detect(data)[0]
    return CharsetMatches([CharsetMatch(data, encoding or "utf-8")])


def from_fp(fp, *args, **kwargs):
    return from_bytes(fp.read())


def from_path(path, *args, **kwargs):
    with open(path, "rb") as fp:
        return from_fp(fp)
