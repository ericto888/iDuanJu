"""Stand-in for shared/tvbox/py/idj_runner.py in TVBoxPythonTests (same three functions)."""
import json
import types

import _idj_host

_spiders = {}


def load(key, source, ext):
    module = types.ModuleType("spider_" + key)
    exec(compile(source, key + ".py", "exec"), module.__dict__)
    spider = module.Spider()
    if hasattr(spider, "init"):
        spider.init(ext)
    _spiders[key] = spider


def call(key, method, args_json):
    return json.dumps(getattr(_spiders[key], method)(*json.loads(args_json)), ensure_ascii=False)


def unload(key):
    spider = _spiders.pop(key, None)
    if spider is not None and hasattr(spider, "destroy"):
        spider.destroy()
