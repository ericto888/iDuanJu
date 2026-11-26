"""Multi-value header mapping (original implementation for i短剧, GPL-3.0)."""

from collections.abc import MutableMapping


class HTTPHeaderDict(MutableMapping):
    """Case-insensitive headers; repeated names are kept and joined with ", " on access."""

    def __init__(self, headers=None, **kwargs):
        self._store = {}  # lower name -> [name, value, value…]
        if headers is not None:
            self.extend(headers)
        if kwargs:
            self.extend(kwargs)

    def __setitem__(self, key, value):
        self._store[key.lower()] = [key, value]

    def __getitem__(self, key):
        return ", ".join(self._store[key.lower()][1:])

    def __delitem__(self, key):
        del self._store[key.lower()]

    def __contains__(self, key):
        return isinstance(key, str) and key.lower() in self._store

    def __iter__(self):
        return iter([entry[0] for entry in self._store.values()])

    def __len__(self):
        return len(self._store)

    def __eq__(self, other):
        try:
            other = other if isinstance(other, HTTPHeaderDict) else HTTPHeaderDict(other)
        except (TypeError, ValueError):
            return NotImplemented
        return {k: v[1:] for k, v in self._store.items()} == {k: v[1:] for k, v in other._store.items()}

    def add(self, key, value, *, combine=False):
        entry = self._store.setdefault(key.lower(), [key])
        if combine and len(entry) > 1:
            entry[-1] = "%s, %s" % (entry[-1], value)
        else:
            entry.append(value)

    def extend(self, *args, **kwargs):
        for other in args:
            if isinstance(other, HTTPHeaderDict):
                pairs = list(other.iteritems())
            elif hasattr(other, "items"):
                pairs = list(other.items())
            else:
                pairs = list(other)
            for key, value in pairs:
                self.add(key, value)
        for key, value in kwargs.items():
            self.add(key, value)

    def getlist(self, key, default=()):
        entry = self._store.get(key.lower())
        return list(entry[1:]) if entry else list(default)

    getheaders = getallmatchingheaders = iget = get_all = getlist

    def discard(self, key):
        self._store.pop(key.lower(), None)

    def iteritems(self):
        for entry in self._store.values():
            for value in entry[1:]:
                yield entry[0], value

    def itermerged(self):
        for entry in self._store.values():
            yield entry[0], ", ".join(entry[1:])

    def items(self):
        return list(self.iteritems())

    def copy(self):
        return HTTPHeaderDict(self)

    def __repr__(self):
        return "HTTPHeaderDict(%s)" % dict(self.itermerged())


class RecentlyUsedContainer(dict):
    pass
