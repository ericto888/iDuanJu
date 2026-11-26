"""Cache key functions (original implementation for i短剧, GPL-3.0)."""

__all__ = ["hashkey", "methodkey", "typedkey"]

_MARK = object()


class _Key(tuple):
    """Tuple that caches its hash."""

    def __hash__(self):
        value = self.__dict__.get("value")
        if value is None:
            value = self.__dict__["value"] = tuple.__hash__(self)
        return value


def hashkey(*args, **kwargs):
    if kwargs:
        return _Key(args + (_MARK,) + tuple(x for pair in sorted(kwargs.items()) for x in pair))
    return _Key(args)


def methodkey(self, *args, **kwargs):
    return hashkey(*args, **kwargs)


def typedkey(*args, **kwargs):
    key = hashkey(*args, **kwargs)
    return _Key(tuple(key) + tuple(type(v) for v in args) + tuple(type(v) for _, v in sorted(kwargs.items())))
