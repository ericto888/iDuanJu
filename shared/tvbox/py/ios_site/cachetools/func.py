"""functools-style decorators (original implementation for i短剧, GPL-3.0)."""

import time
from threading import RLock

from . import FIFOCache, LRUCache, TTLCache, cached
from .keys import hashkey, typedkey

__all__ = ["fifo_cache", "lru_cache", "ttl_cache"]


def _decorate(make, maxsize, typed):
    key = typedkey if typed else hashkey
    if callable(maxsize):
        return cached(make(128), key, RLock())(maxsize)
    return lambda func: cached(make(float("inf") if maxsize is None else maxsize), key, RLock())(func)


def fifo_cache(maxsize=128, typed=False):
    return _decorate(FIFOCache, maxsize, typed)


def lru_cache(maxsize=128, typed=False):
    return _decorate(LRUCache, maxsize, typed)


def ttl_cache(maxsize=128, ttl=600, timer=time.monotonic, typed=False):
    return _decorate(lambda size: TTLCache(size, ttl, timer), maxsize, typed)
