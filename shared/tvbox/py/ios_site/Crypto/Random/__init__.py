"""Random bytes (original implementation for i短剧, GPL-3.0)."""

from os import urandom

__all__ = ["new", "get_random_bytes"]


class _UrandomRNG:
    def read(self, n):
        return urandom(n)

    def flush(self):
        pass

    def reinit(self):
        pass

    def close(self):
        pass


def new(*args, **kwargs):
    return _UrandomRNG()


def atfork():
    pass


get_random_bytes = urandom
