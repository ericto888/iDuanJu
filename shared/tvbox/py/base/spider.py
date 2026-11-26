# -*- coding: utf-8 -*-
"""Base class TVBox Python spiders extend (`from base.spider import Spider`).

Shared by Android (Chaquopy) and iOS (embedded CPython). `requests` and `lxml` are the real packages on Android and
API-compatible shims on iOS, so this file only uses their common surface. Own code, GPL-3.0.
"""
import json
import re
import types

import _idj_host

_EMOJI = re.compile('[\U0001F600-\U0001F64F\U0001F300-\U0001F5FF\U0001F680-\U0001F6FF\U0001F1E0-\U0001F1FF]')
_TAG = re.compile('<[^>]*?>')


def _host(name, **args):
    reply = json.loads(_idj_host.call(name, json.dumps(args, ensure_ascii=False)))
    if reply.get('e') is not None:
        raise RuntimeError(reply['e'])
    return reply.get('v')


class Spider:
    """Every content method is optional; results may be dicts (encoded by idj_runner) or JSON strings."""

    siteKey = ''

    def __init__(self):
        self.extend = ''

    # -- contract -----------------------------------------------------------------------------------------------------
    def init(self, extend=''):
        pass

    def getName(self):
        return ''

    def getDependence(self):
        return []

    def homeContent(self, filter):
        return {}

    def homeVideoContent(self):
        return {}

    def categoryContent(self, tid, pg, filter, extend):
        return {}

    def detailContent(self, ids):
        return {}

    def searchContent(self, key, quick, pg='1'):
        return {}

    def playerContent(self, flag, id, vipFlags):
        return {}

    def liveContent(self, url):
        return ''

    def localProxy(self, param):
        return None

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return ''

    def destroy(self):
        pass

    # -- helpers ------------------------------------------------------------------------------------------------------
    def setExtendInfo(self, extend):
        self.extend = extend

    def fetch(self, url, params=None, cookies=None, headers=None, timeout=10, verify=True, stream=False, allow_redirects=True):
        import requests
        rsp = requests.get(url, params=params, cookies=cookies, headers=headers, timeout=timeout, verify=verify, stream=stream,
                           allow_redirects=allow_redirects)
        rsp.encoding = 'utf-8'
        return rsp

    def post(self, url, params=None, data=None, json=None, cookies=None, headers=None, timeout=10, verify=True, stream=False,
             allow_redirects=True):
        import requests
        rsp = requests.post(url, params=params, data=data, json=json, cookies=cookies, headers=headers, timeout=timeout,
                            verify=verify, stream=stream, allow_redirects=allow_redirects)
        rsp.encoding = 'utf-8'
        return rsp

    def postJson(self, url, json, headers=None, cookies=None, timeout=10):
        return self.post(url, json=json, headers=headers, cookies=cookies, timeout=timeout)

    def html(self, content):
        from lxml import etree
        return etree.HTML(content)

    def xpText(self, root, expr):
        found = root.xpath(expr)
        return found[0] if found else ''

    def regStr(self, reg='', src='', group=1):
        # both historic argument orders exist: regStr(reg, src) and regStr(src=…, reg=…)
        m = re.search(reg, src)
        return m.group(group) if m else ''

    def removeHtmlTags(self, src):
        return _TAG.sub('', src)

    def cleanText(self, src):
        return _EMOJI.sub('', src)

    def str2json(self, text):
        return json.loads(text)

    def json2str(self, value):
        return json.dumps(value, ensure_ascii=False)

    def getProxyUrl(self, local=True):
        return _host('proxyUrl', local=bool(local), kind='py', siteKey=self.siteKey)

    def getCache(self, key):
        text = _host('local.get', ns=self.siteKey or 'py', k=str(key))
        if text in (None, ''):
            return None
        try:
            return json.loads(text)
        except ValueError:
            return text

    def setCache(self, key, value):
        _host('local.set', ns=self.siteKey or 'py', k=str(key), v=value if isinstance(value, str) else json.dumps(value, ensure_ascii=False))
        return 'succeed'

    def delCache(self, key):
        _host('local.delete', ns=self.siteKey or 'py', k=str(key))
        return 'succeed'

    def log(self, msg):
        _host('log', m=msg if isinstance(msg, str) else json.dumps(msg, ensure_ascii=False, default=str))

    def loadModule(self, name, fileName=None):
        """Import another spider script by http(s) address (dependency of the running script)."""
        url = fileName or name
        if not re.match(r'^https?://', url):
            raise RuntimeError('只支持通过网址加载依赖脚本：' + str(url))
        module = types.ModuleType(re.sub(r'\W', '_', name))
        exec(compile(self.fetch(url).text, url, 'exec'), module.__dict__)
        return module

    def loadSpider(self, name):
        return self.loadModule(name).Spider()
