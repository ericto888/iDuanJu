"""Timeout settings holder (original implementation for i短剧, GPL-3.0)."""


class Timeout:
    DEFAULT_TIMEOUT = None

    def __init__(self, total=None, connect=None, read=None):
        self.total = total
        self._connect = connect
        self._read = read

    @classmethod
    def from_float(cls, timeout):
        return cls(read=timeout, connect=timeout)

    @property
    def connect_timeout(self):
        return self._connect if self._connect is not None else self.total

    @property
    def read_timeout(self):
        return self._read if self._read is not None else self.total

    def clone(self):
        return Timeout(self.total, self._connect, self._read)

    def __repr__(self):
        return "Timeout(connect=%r, read=%r, total=%r)" % (self._connect, self._read, self.total)
