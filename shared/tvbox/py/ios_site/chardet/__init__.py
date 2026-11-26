"""chardet-compatible detect(): UTF-8/16, GB18030, Big5 (original implementation for i短剧, GPL-3.0)."""

import _idj_text

__version__ = "5.2.0"
_LANGUAGE = {"gb18030": "Chinese", "big5": "Chinese"}
_NAMES = {"gb18030": "GB2312", "big5": "Big5", "utf-8-sig": "UTF-8-SIG", "utf-16": "UTF-16", "utf-32": "UTF-32"}


def detect(byte_str, should_rename_legacy=False):
    if not isinstance(byte_str, (bytes, bytearray)):
        raise TypeError("Expected object of type bytes or bytearray, got: %s" % type(byte_str))
    encoding, confidence = _idj_text.detect(bytes(byte_str))
    return {
        "encoding": _NAMES.get(encoding, encoding), "confidence": confidence, "language": _LANGUAGE.get(encoding, ""),
    }


def detect_all(byte_str, ignore_threshold=False, should_rename_legacy=False):
    return [detect(byte_str)]


class UniversalDetector:
    def __init__(self, *args, **kwargs):
        self.reset()

    def reset(self):
        self._data = bytearray()
        self.done = False
        self.result = {"encoding": None, "confidence": 0.0, "language": None}

    def feed(self, byte_str):
        self._data += byte_str

    def close(self):
        self.done = True
        self.result = detect(bytes(self._data))
        return self.result
