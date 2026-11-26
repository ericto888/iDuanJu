"""cachetools-compatible API: LRUCache, FIFOCache, TTLCache, cached (original implementation for i短剧, GPL-3.0)."""

from __future__ import annotations

import functools
import time
from collections import OrderedDict
from collections.abc import MutableMapping

from . import keys

__version__ = "5.5.0"
__all__ = ["Cache", "FIFOCache", "LRUCache", "TTLCache", "cached", "cachedmethod", "keys"]

_MISSING = object()


class Cache(MutableMapping):
    """Bounded mapping; subclasses choose what popitem() evicts."""

    def __init__(self, maxsize, getsizeof=None):
        self._maxsize = maxsize
        self._getsizeof = getsizeof
        self._items = OrderedDict()
        self._sizes = {}
        self._total = 0

    @staticmethod
    def getsizeof(value):
        return 1

    @property
    def maxsize(self):
        return self._maxsize

    @property
    def currsize(self):
        return self._total

    def _measure(self, value):
        return self._getsizeof(value) if self._getsizeof else 1

    def __missing__(self, key):
        raise KeyError(key)

    def __getitem__(self, key):
        try:
            return self._items[key]
        except KeyError:
            return self.__missing__(key)

    def __setitem__(self, key, value):
        size = self._measure(value)
        if size > self._maxsize:
            raise ValueError("value too large")
        if key in self._items:
            self._total -= self._sizes[key]
        while self._total + size > self._maxsize:
            self.popitem()
        self._items[key] = value
        self._sizes[key] = size
        self._total += size

    def __delitem__(self, key):
        del self._items[key]
        self._total -= self._sizes.pop(key)

    def __contains__(self, key):
        return key in self._items

    def __iter__(self):
        return iter(list(self._items))

    def __len__(self):
        return len(self._items)

    def get(self, key, default=None):
        return self[key] if key in self else default

    def pop(self, key, default=_MISSING):
        if key in self:
            value = self[key]
            del self[key]
            return value
        if default is _MISSING:
            raise KeyError(key)
        return default

    def popitem(self):
        try:
            key = next(iter(self._items))
        except StopIteration:
            raise KeyError("%s is empty" % type(self).__name__) from None
        value = self._items[key]
        Cache.__delitem__(self, key)
        return key, value

    def setdefault(self, key, default=None):
        if key not in self:
            self[key] = default
        return self[key]

    def __repr__(self):
        return "%s(%r, maxsize=%r, currsize=%r)" % (
            type(self).__name__, list(self._items.items()), self._maxsize, self.currsize,
        )


class FIFOCache(Cache):
    """Evicts the oldest entry."""


class LRUCache(Cache):
    """Evicts the least recently used entry."""

    def __getitem__(self, key):
        value = super().__getitem__(key)
        if key in self._items:
            self._items.move_to_end(key)
        return value

    def __setitem__(self, key, value):
        super().__setitem__(key, value)
        self._items.move_to_end(key)


class TTLCache(LRUCache):
    """LRU cache whose entries expire `ttl` seconds after they were set."""

    def __init__(self, maxsize, ttl, timer=time.monotonic, getsizeof=None):
        super().__init__(maxsize, getsizeof)
        self._ttl = ttl
        self._timer = timer
        self._expires = {}

    @property
    def ttl(self):
        return self._ttl

    @property
    def timer(self):
        return self._timer

    @property
    def currsize(self):
        self.expire()
        return self._total

    def _alive(self, key):
        return key in self._items and self._timer() < self._expires[key]

    def __contains__(self, key):
        return self._alive(key)

    def __getitem__(self, key):
        if not self._alive(key):
            return self.__missing__(key)
        return super().__getitem__(key)

    def __setitem__(self, key, value):
        self.expire()
        super().__setitem__(key, value)
        self._expires[key] = self._timer() + self._ttl

    def __delitem__(self, key):
        alive = self._alive(key)
        if key not in self._items:
            raise KeyError(key)
        Cache.__delitem__(self, key)
        del self._expires[key]
        if not alive:
            raise KeyError(key)

    def __iter__(self):
        return iter([k for k in list(self._items) if self._alive(k)])

    def __len__(self):
        return sum(1 for k in self._items if self._alive(k))

    def popitem(self):
        self.expire()
        key, value = super().popitem()
        self._expires.pop(key, None)
        return key, value

    def expire(self, time=None):
        now = self._timer() if time is None else time
        gone = []
        for key in [k for k, at in self._expires.items() if at <= now]:
            gone.append((key, self._items[key]))
            Cache.__delitem__(self, key)
            del self._expires[key]
        return gone


def cached(cache, key=keys.hashkey, lock=None, info=False):
    """Decorator that stores results in `cache` (None disables caching)."""

    def decorator(func):
        guard = lock if lock is not None else _NoLock()

        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            if cache is None:
                return func(*args, **kwargs)
            k = key(*args, **kwargs)
            with guard:
                value = cache.get(k, _MISSING)
            if value is not _MISSING:
                return value
            value = func(*args, **kwargs)
            try:
                with guard:
                    return cache.setdefault(k, value)
            except ValueError:  # value too large
                return value

        def clear():
            if cache is not None:
                with guard:
                    cache.clear()

        wrapper.cache = cache
        wrapper.cache_key = key
        wrapper.cache_lock = lock
        wrapper.cache_clear = clear
        return wrapper

    return decorator


def cachedmethod(cache, key=keys.methodkey, lock=None):
    """Like cached(), with `cache(self)` returning the cache object."""

    def decorator(method):
        @functools.wraps(method)
        def wrapper(self, *args, **kwargs):
            store = cache(self)
            if store is None:
                return method(self, *args, **kwargs)
            k = key(self, *args, **kwargs)
            with lock(self) if lock is not None else _NoLock():
                value = store.get(k, _MISSING)
            if value is not _MISSING:
                return value
            value = method(self, *args, **kwargs)
            try:
                with lock(self) if lock is not None else _NoLock():
                    return store.setdefault(k, value)
            except ValueError:
                return value

        wrapper.cache = cache
        return wrapper

    return decorator


class _NoLock:
    def __enter__(self):
        return self

    def __exit__(self, *args):
        return None
