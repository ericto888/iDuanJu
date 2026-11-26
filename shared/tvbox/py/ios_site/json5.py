"""json5-compatible API over the host's lenient JSON parser (original implementation for i短剧, GPL-3.0)."""

import json as _json

__version__ = "0.9.25"


def loads(s, *, encoding=None, cls=None, object_hook=None, parse_float=None, parse_int=None, parse_constant=None,
          strict=True, object_pairs_hook=None, allow_duplicate_keys=True, **kwargs):
    from _idj_bridge import HostError, call

    if isinstance(s, (bytes, bytearray)):
        s = bytes(s).decode(encoding or "utf-8")
    elif not isinstance(s, str):
        raise TypeError("the JSON5 object must be str, bytes or bytearray, not %s" % type(s).__name__)
    if not s.strip():
        raise ValueError("Empty strings are not legal JSON5")
    try:
        value = call("json5", s=s)
    except HostError as exc:
        raise ValueError(exc.message) from exc
    if object_hook or object_pairs_hook or parse_float or parse_int or parse_constant or cls:
        # Plain JSON now: let the stdlib apply the hooks.
        return _json.loads(
            _json.dumps(value), cls=cls, object_hook=object_hook, parse_float=parse_float, parse_int=parse_int,
            parse_constant=parse_constant, object_pairs_hook=object_pairs_hook,
        )
    return value


def load(fp, **kwargs):
    return loads(fp.read(), **kwargs)


def dumps(obj, *, quote_keys=False, trailing_commas=True, allow_duplicate_keys=True, quote_style=None, **kwargs):
    """Strict JSON, which is valid JSON5."""
    return _json.dumps(obj, **kwargs)


def dump(obj, fp, **kwargs):
    fp.write(dumps(obj, **kwargs))
