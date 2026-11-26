"""Data structures (original implementation for i短剧, GPL-3.0)."""

from collections.abc import Mapping, MutableMapping


class CaseInsensitiveDict(MutableMapping):
    """Dict with case-insensitive string keys that remembers the case of the last key set."""

    def __init__(self, data=None, **kwargs):
        self._store = {}
        self.update({} if data is None else data, **kwargs)

    def __setitem__(self, key, value):
        self._store[key.lower()] = (key, value)

    def __getitem__(self, key):
        return self._store[key.lower()][1]

    def __delitem__(self, key):
        del self._store[key.lower()]

    def __iter__(self):
        return iter([key for key, _ in self._store.values()])

    def __len__(self):
        return len(self._store)

    def lower_items(self):
        return ((low, pair[1]) for low, pair in self._store.items())

    def __eq__(self, other):
        if not isinstance(other, Mapping):
            return NotImplemented
        return dict(self.lower_items()) == dict(CaseInsensitiveDict(other).lower_items())

    def copy(self):
        return CaseInsensitiveDict(self._store.values())

    def __repr__(self):
        return str(dict(self.items()))


class LookupDict(dict):
    """Attribute and item access; unknown items give None."""

    def __init__(self, name=None):
        self.name = name
        super().__init__()

    def __repr__(self):
        return "<lookup '%s'>" % self.name

    def __getitem__(self, key):
        return self.__dict__.get(key, None)

    def get(self, key, default=None):
        return self.__dict__.get(key, default)
