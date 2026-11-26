# -*- coding: utf-8 -*-
"""Runs TVBox Python spiders for the host (Android: Chaquopy, iOS: embedded CPython). Own code, GPL-3.0.

    load(key, source, ext, site_key='', url='')  run the script in a fresh module, instantiate `Spider`, call init(ext)
    call(key, method, args_json) -> str          content methods return JSON text ('' when the method is missing / empty);
                                                 localProxy returns {"code", "type", "b64", "headers"}
    unload(key)                                  destroy() and drop the instance

Errors are raised as RuntimeError with a short readable message that names the script line.
"""
import base64
import hashlib
import inspect
import json
import sys
import traceback
import types

_spiders = {}

# Host method name -> names a script may use for it, in order.
_ALIASES = {'proxyLocal': ('localProxy', 'proxyLocal'), 'isVideoFormat': ('isVideoFormat',), 'manualVideoCheck': ('manualVideoCheck',)}


def _explain(error):
    if isinstance(error, SyntaxError):
        return '语法错误（第 %s 行）：%s' % (error.lineno, error.msg)
    where = ''
    for frame in traceback.extract_tb(error.__traceback__):
        if frame.filename.startswith('spider:'):
            where = '（%s 第 %d 行）' % (frame.filename[7:], frame.lineno)
    if isinstance(error, ModuleNotFoundError):
        return '缺少 Python 模块 %s%s' % (error.name, where)
    text = str(error) or type(error).__name__
    return '%s：%s%s' % (type(error).__name__, text, where) if str(error) else text + where


def _fail(error):
    raise RuntimeError(_explain(error)) from None


def load(key, source, ext='', site_key='', url=''):
    unload(key)
    label = (url or site_key or key).split('?')[0].rsplit('/', 1)[-1] or 'script.py'
    name = 'idj_spider_' + hashlib.md5(key.encode('utf-8')).hexdigest()[:12]
    module = types.ModuleType(name)
    module.__file__ = label
    module.__dict__['__spider_url__'] = url
    sys.modules[name] = module
    try:
        exec(compile(source, 'spider:' + label, 'exec'), module.__dict__)
        cls = module.__dict__.get('Spider')
        if cls is None or (inspect.isclass(cls) and cls.__module__ != name and getattr(cls, '__module__', '') == 'base.spider'):
            own = [c for c in module.__dict__.values() if inspect.isclass(c) and c.__module__ == name and (hasattr(c, 'homeContent') or hasattr(c, 'liveContent'))]
            cls = own[0] if own else cls
        if cls is None:
            raise RuntimeError('脚本里没有 Spider 类')
        spider = cls()
        try:
            spider.siteKey = site_key or getattr(spider, 'siteKey', '')
        except AttributeError:
            pass
        _spiders[key] = spider
        init = getattr(spider, 'init', None)
        if init is not None:
            init(ext)
    except BaseException as error:  # SystemExit / KeyboardInterrupt from a script must not take the host down
        unload(key)
        _fail(error)


def _method(spider, name):
    for candidate in _ALIASES.get(name, (name,)):
        fn = getattr(spider, candidate, None)
        if callable(fn):
            return fn
    return None


def _fit(fn, args):
    """Drop trailing arguments an older script signature does not take (searchContent(key, quick) …)."""
    try:
        params = [p for p in inspect.signature(fn).parameters.values()]
    except (TypeError, ValueError):
        return args
    if any(p.kind == p.VAR_POSITIONAL for p in params):
        return args
    room = len([p for p in params if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD)])
    return args[:room]


def _bytes(value):
    if value is None:
        return b''
    if isinstance(value, (bytes, bytearray, memoryview)):
        return bytes(value)
    if isinstance(value, str):
        return value.encode('utf-8')
    read = getattr(value, 'read', None)
    if callable(read):
        return _bytes(read())
    return json.dumps(value, ensure_ascii=False).encode('utf-8')


def _action(spider, spec):
    """Old style third element {'url', 'header', 'param', 'type'}: the host fetches the address for the script."""
    import requests
    rsp = requests.get(spec['url'], headers=spec.get('header') or {}, params=spec.get('param') or None, timeout=15)
    return rsp.content


def _proxy(spider, result):
    if result is None:
        return ''
    if isinstance(result, str):
        result = [200, 'text/plain; charset=utf-8', result]
    if isinstance(result, dict):
        result = [result.get('code', 200), result.get('type', 'application/octet-stream'), result.get('content'), result.get('headers')]
    items = list(result) + [None] * 5
    code, mime, body, headers, flag = items[:5]
    if isinstance(body, dict) and body.get('url'):
        data = _action(spider, body)
    else:
        data = _bytes(body)
        if flag == 1 and isinstance(body, str):
            data = base64.b64decode(body.split('base64,', 1)[-1])
    if isinstance(headers, str):
        try:
            headers = json.loads(headers) if headers else {}
        except ValueError:
            headers = {}
    headers = {str(k): str(v) for k, v in dict(headers or {}).items()}
    return json.dumps({'code': int(code or 200), 'type': str(mime or 'application/octet-stream'),
                       'b64': base64.b64encode(data).decode('ascii'), 'headers': headers})


def call(key, method, args_json='[]'):
    spider = _spiders.get(key)
    if spider is None:
        raise RuntimeError('脚本还没有加载')
    fn = _method(spider, method)
    if fn is None:
        return ''
    try:
        result = fn(*_fit(fn, json.loads(args_json or '[]')))
        if method == 'proxyLocal':
            return _proxy(spider, result)
        if result is None:
            return ''
        if isinstance(result, bool):
            return 'true' if result else 'false'
        if isinstance(result, (bytes, bytearray)):
            return bytes(result).decode('utf-8', 'replace')
        return result if isinstance(result, str) else json.dumps(result, ensure_ascii=False, default=str)
    except BaseException as error:
        _fail(error)


def unload(key):
    spider = _spiders.pop(key, None)
    sys.modules.pop('idj_spider_' + hashlib.md5(key.encode('utf-8')).hexdigest()[:12], None)
    destroy = getattr(spider, 'destroy', None)
    if callable(destroy):
        try:
            destroy()
        except BaseException:
            pass
