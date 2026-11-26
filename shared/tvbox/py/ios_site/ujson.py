"""ujson-compatible API over the stdlib json module (original implementation for i短剧, GPL-3.0)."""

import json as _json
from json import JSONDecodeError

__version__ = "5.10.0"


def dumps(obj, ensure_ascii=True, encode_html_chars=False, escape_forward_slashes=True, indent=0, sort_keys=False,
          allow_nan=True, reject_bytes=True, default=None, separators=None, **kwargs):
    if separators is None:
        separators = (",", ":") if not indent else (",", ": ")
    text = _json.dumps(
        obj, ensure_ascii=ensure_ascii, indent=indent or None, sort_keys=sort_keys, allow_nan=allow_nan,
        default=default, separators=separators,
    )
    if escape_forward_slashes:
        text = text.replace("/", "\\/")
    if encode_html_chars:
        text = text.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    return text


def loads(s, **kwargs):
    return _json.loads(s, **kwargs)


def dump(obj, fp, **kwargs):
    fp.write(dumps(obj, **kwargs))


def load(fp, **kwargs):
    return loads(fp.read(), **kwargs)


encode = dumps
decode = loads
