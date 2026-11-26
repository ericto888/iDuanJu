# -*- coding: utf-8 -*-
"""`from base.localProxy import Proxy`: address of the app's loopback proxy. Own code, GPL-3.0."""
import json
import re

import _idj_host


class Proxy:
    @staticmethod
    def getUrl(local=True):
        reply = json.loads(_idj_host.call('proxyUrl', json.dumps({'local': bool(local), 'kind': 'py'})))
        return (reply.get('v') or '').split('?')[0]

    @staticmethod
    def getPort():
        m = re.search(r':(\d+)/', Proxy.getUrl(True))
        return int(m.group(1)) if m else 0
