"""simplejson name for the stdlib json module (i短剧, GPL-3.0)."""

from json import JSONDecodeError, JSONDecoder, JSONEncoder
from json import dump as _dump
from json import dumps as _dumps
from json import load, loads

__version__ = "3.19.3"
_EXTRA = ("ignore_nan", "use_decimal", "namedtuple_as_object", "tuple_as_array", "bigint_as_string", "encoding",
          "item_sort_key", "for_json", "int_as_string_bitcount", "iterable_as_array")


def _options(kwargs):
    if kwargs.get("ignore_nan") or kwargs.get("bigint_as_string") or kwargs.get("int_as_string_bitcount"):
        raise NotImplementedError("simplejson（iOS 版）不支持 ignore_nan / bigint_as_string")
    return {k: v for k, v in kwargs.items() if k not in _EXTRA}


def dumps(obj, *args, **kwargs):
    return _dumps(obj, *args, **_options(kwargs))


def dump(obj, fp, *args, **kwargs):
    return _dump(obj, fp, *args, **_options(kwargs))
