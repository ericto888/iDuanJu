"""Pure-Python stand-in for the native `_idj_host` module (tests only, GPL-3.0)."""

import base64
import codecs
import hashlib
import hmac
import json
import re
import sys
import threading
import types
import zlib
from urllib.parse import urljoin

import _idj_css
import fake_crypto
import fake_dom
import fake_xpath


def b64d(text):
    return base64.b64decode(text) if text else b""


def b64e(data):
    return base64.b64encode(data).decode("ascii")


class HostFailure(Exception):
    pass


class _Adapter:
    """fake_dom for the CSS engine."""

    def __init__(self, xml):
        self.xml = xml

    tag = staticmethod(lambda n: fake_dom.local(n.tag))
    attr = staticmethod(lambda n, name: n.attrs.get(name))
    children = staticmethod(lambda n: n.elements())
    text = staticmethod(lambda n: n.string())
    key = staticmethod(id)

    @staticmethod
    def parent(n):
        return None if isinstance(n.parent, fake_dom.Document) else n.parent

    @staticmethod
    def container(n):
        return n.parent

    @staticmethod
    def descendants(n):
        return [d for d in n.descendants() if isinstance(d, fake_dom.Element)]

    @staticmethod
    def own_text(n):
        return "".join(c.data for c in n.children if isinstance(c, fake_dom.Text))

    @staticmethod
    def empty(n):
        return not any(
            isinstance(c, fake_dom.Element) or (isinstance(c, fake_dom.Text) and c.data.strip()) for c in n.children
        )


class FakeHost:
    def __init__(self):
        self.local = threading.local()
        self.select_includes_self = False
        self.reset()

    def reset(self):
        self.nodes = {}
        self.ids = {}
        self.next_id = 0
        self.calls = []
        self.requests = []
        self.routes = []
        self.logs = []
        self.storage = {}
        self.select_includes_self = False

    # -- entry points ------------------------------------------------------------------------------------------------
    def call(self, name, args_json):
        if not isinstance(name, str) or not isinstance(args_json, str):
            raise TypeError("call(str, str)")
        args_json.encode("utf-8")  # the C glue needs valid UTF-8
        args = json.loads(args_json)
        self.calls.append((name, args))
        try:
            handler = getattr(self, "do_" + name.replace(".", "_"), None)
            if handler is None:
                raise HostFailure("未知的宿主函数 " + name)
            return json.dumps({"v": handler(**args)}, ensure_ascii=False)
        except (HostFailure, ValueError, KeyError, fake_xpath.XPathFailure, AssertionError) as exc:
            return json.dumps({"e": str(exc) or type(exc).__name__}, ensure_ascii=False)

    def get_key(self):
        return getattr(self.local, "key", "")

    def set_key(self, key):
        self.local.key = key

    def install(self):
        module = types.ModuleType("_idj_host")
        module.call = self.call
        module.get_key = self.get_key
        module.set_key = self.set_key
        sys.modules["_idj_host"] = module
        return self

    def names(self):
        return [name for name, _ in self.calls]

    # -- http --------------------------------------------------------------------------------------------------------
    def on(self, url, body=b"", status=200, headers=None, method=None, handler=None, error=None):
        """Route: exact URL (query included) or a compiled regex."""
        self.routes.append((method, url, body, status, headers or {}, handler, error))

    def _answer(self, request):
        for method, url, body, status, headers, handler, error in reversed(self.routes):
            if method and method != request["method"]:
                continue
            if not (url.search(request["url"]) if hasattr(url, "search") else url == request["url"]):
                continue
            if error:
                raise HostFailure(error)
            if handler:
                out = handler(request)
                if not isinstance(out, dict):
                    out = {"body": out}
                status, headers, body = out.get("status", 200), out.get("headers", {}), out.get("body", b"")
            if isinstance(body, str):
                body = body.encode("utf-8")
            elif isinstance(body, (dict, list)):
                body = json.dumps(body, ensure_ascii=False).encode("utf-8")
            return status, headers, body
        raise HostFailure("无法连接到服务器：" + request["url"])

    def do_http(self, url, method="GET", headers=None, body=None, bodyB64=None, timeout=10000, redirect=True,
                verify=True, out="text", charset=None):
        for key, value in (headers or {}).items():
            assert isinstance(key, str) and isinstance(value, str), "请求头必须是字符串"
        assert isinstance(timeout, int)
        if not re.match(r"https?://[^/]", url):
            raise HostFailure("unsupported URL")
        request = {
            "url": url, "method": method, "headers": headers or {}, "timeout": timeout, "redirect": redirect,
            "verify": verify, "body": b64d(bodyB64) if bodyB64 is not None else (body.encode() if body else None),
        }
        self.requests.append(request)
        status, reply, data = self._answer(request)
        if redirect and status in (301, 302, 303, 307, 308):
            target = {k.lower(): v for k, v in reply.items()}["location"]
            return self.do_http(urljoin(url, target), "GET", headers, None, None, timeout, True, verify, out, charset)
        packed = {k: v if isinstance(v, list) else [v] for k, v in reply.items()}
        return {
            "code": status, "url": url, "headers": packed,
            "body": b64e(data) if out == "b64" else data.decode("utf-8", "replace"),
        }

    # -- html --------------------------------------------------------------------------------------------------------
    def _id(self, node):
        found = self.ids.get(id(node))
        if found is None:
            self.next_id += 1
            found = self.ids[id(node)] = self.next_id
            self.nodes[found] = node
        return found

    def _node(self, node_id):
        try:
            return self.nodes[node_id]
        except KeyError:
            raise HostFailure("节点已失效: %r" % node_id) from None

    @staticmethod
    def _doc(node):
        while node.parent is not None:
            node = node.parent
        return node

    def _xml(self, node):
        doc = self._doc(node)
        return isinstance(doc, fake_dom.Document) and doc.xml

    def do_html_load(self, html):
        return self._id(fake_dom.parse_html(html))

    def do_html_loadXml(self, xml):
        return self._id(fake_dom.parse_xml(xml))

    def do_html_select(self, ids, css):
        nodes = [self._node(i) for i in ids]
        if not nodes:
            return []
        found = _idj_css.select(
            _Adapter(self._xml(nodes[0])), nodes, css, include_self=self.select_includes_self and not isinstance(
                nodes[0], fake_dom.Document)
        )
        return [self._id(n) for n in found]

    def do_html_text(self, id):
        return " ".join(self._node(id).string().split())

    def do_html_html(self, id):
        node = self._node(id)
        return fake_dom.inner(node, self._xml(node))

    def do_html_outer(self, id):
        node = self._node(id)
        return fake_dom.serialize(node, self._xml(node))

    def do_html_attr(self, id, k):
        return self._node(id).attrs.get(k)

    def do_html_rel(self, id, op):
        node = self._node(id)
        if op == "children":
            return [self._id(n) for n in node.elements()]
        if op == "parent":
            return [self._id(node.parent)] if node.parent is not None else []
        kids = node.parent.elements() if node.parent is not None else [node]
        at = next(i for i, n in enumerate(kids) if n is node)
        if op == "next":
            return [self._id(n) for n in kids[at + 1:at + 2]]
        if op == "prev":
            return [self._id(n) for n in kids[max(at - 1, 0):at]]
        if op == "siblings":
            return [self._id(n) for n in kids if n is not node]
        raise HostFailure("未知关系 " + op)

    def do_html_xpath(self, id, q):
        value = fake_xpath.query(self._node(id), q)
        if not isinstance(value, list):
            return [{"s": fake_xpath.to_string(value)}]
        out = []
        for node in value:
            if isinstance(node, (fake_dom.Element, fake_dom.Comment)):
                out.append({"n": self._id(node)})
            else:
                out.append({"s": node.data})
        return out

    def do_html_info(self, id):
        node = self._node(id)
        text = tail = None
        if isinstance(node, fake_dom.Comment):
            return {"tag": "!comment", "attrs": {}, "text": node.data, "tail": None}
        parts = []
        for child in node.children:
            if not isinstance(child, fake_dom.Text):
                break
            parts.append(child.data)
        text = "".join(parts) if parts else None
        if node.parent is not None:
            kids = node.parent.children
            at = next(i for i, n in enumerate(kids) if n is node)
            if at + 1 < len(kids) and isinstance(kids[at + 1], fake_dom.Text):
                tail = kids[at + 1].data
        return {"tag": node.tag, "attrs": node.attrs, "text": text, "tail": tail}

    def do_html_childNodes(self, id):
        out = []
        for child in self._node(id).children:
            if isinstance(child, fake_dom.Element):
                out.append({"n": self._id(child)})
            elif isinstance(child, fake_dom.Text):
                out.append({"s": child.data})
            else:
                out.append({"c": child.data})
        return out

    def do_html_remove(self, ids, tail=False):
        for node in [self._node(i) for i in ids]:
            parent = node.parent
            if parent is None:
                continue
            at = next(i for i, n in enumerate(parent.children) if n is node)
            del parent.children[at]
            if tail and at < len(parent.children) and isinstance(parent.children[at], fake_dom.Text):
                del parent.children[at]
            node.parent = None
            # adjacent text nodes merge, as they do after a re-parse
            if 0 < at < len(parent.children):
                before, after = parent.children[at - 1], parent.children[at]
                if isinstance(before, fake_dom.Text) and isinstance(after, fake_dom.Text):
                    before.data += after.data
                    del parent.children[at]
        return None

    def do_html_setAttr(self, id, k, v):
        node = self._node(id)
        if v is None:
            node.attrs.pop(k, None)
        else:
            node.attrs[k] = v
        return None

    def do_html_setText(self, id, s):
        node = self._node(id)
        node.children = []
        if s:
            node.append(fake_dom.Text(s))
        return None

    # -- crypto ------------------------------------------------------------------------------------------------------
    def do_hash(self, alg, b64, hmacB64=None):
        if alg not in ("md5", "sha1", "sha256", "sha512"):
            raise HostFailure("未知算法 " + alg)
        data = b64d(b64)
        if hmacB64 is not None:
            return hmac.new(b64d(hmacB64), data, alg).hexdigest()
        return hashlib.new(alg, data).hexdigest()

    def do_cipher(self, alg, mode, pad, encrypt, keyB64, dataB64, ivB64=None, aadB64=None):
        iv = b64d(ivB64) if ivB64 is not None else None
        return b64e(fake_crypto.cipher(alg, mode, pad, encrypt, b64d(keyB64), iv, b64d(dataB64), b64d(aadB64)))

    def do_rsa(self, op, bits=None, **kwargs):
        if op == "generate":
            return fake_crypto.rsa_generate(bits)
        raise HostFailure("fake rsa: " + op)

    # -- the rest ----------------------------------------------------------------------------------------------------
    def do_gbk(self, op, s=None, b64=None):
        return b64e(s.encode("gb18030")) if op == "encode" else b64d(b64).decode("gb18030", "replace")

    def do_inflate(self, b64, kind):
        return b64e(zlib.decompress(b64d(b64), {"gzip": 31, "zlib": 15, "raw": -15}[kind]))

    def do_json5(self, s):
        return Json5(s).parse()

    def do_log(self, m):
        self.logs.append(m)
        return None


class Json5:
    """Tiny JSON5 reader."""

    def __init__(self, text):
        self.text, self.pos = text, 0

    def fail(self):
        raise HostFailure("JSON5 解析失败（位置 %d）" % self.pos)

    def skip(self):
        found = re.compile(r"(?:\s|//[^\n]*|/\*.*?\*/)*", re.S).match(self.text, self.pos)
        self.pos = found.end()

    def parse(self):
        value = self.value()
        self.skip()
        if self.pos != len(self.text):
            self.fail()
        return value

    def peek(self):
        self.skip()
        return self.text[self.pos:self.pos + 1]

    def value(self):
        ch = self.peek()
        if ch == "{":
            self.pos += 1
            out = {}
            while self.peek() != "}":
                key = self.string() if self.peek() in "'\"" else self.word()
                if self.peek() != ":":
                    self.fail()
                self.pos += 1
                out[key] = self.value()
                if self.peek() == ",":
                    self.pos += 1
                elif self.peek() != "}":
                    self.fail()
            self.pos += 1
            return out
        if ch == "[":
            self.pos += 1
            out = []
            while self.peek() != "]":
                out.append(self.value())
                if self.peek() == ",":
                    self.pos += 1
                elif self.peek() != "]":
                    self.fail()
            self.pos += 1
            return out
        if ch and ch in "'\"":
            return self.string()
        word = self.word()
        if word in ("true", "false", "null"):
            return {"true": True, "false": False, "null": None}[word]
        try:
            if word.lower().startswith("0x"):
                return int(word, 16)
            return float(word) if re.search(r"[.eE]", word) else int(word)
        except ValueError:
            self.fail()

    def word(self):
        self.skip()
        found = re.compile(r"[\w$.+\-]+").match(self.text, self.pos)
        if not found:
            self.fail()
        self.pos = found.end()
        return found.group()

    def string(self):
        quote = self.text[self.pos]
        found = re.compile(r"%s((?:\\.|[^\\%s])*)%s" % (quote, quote, quote), re.S).match(self.text, self.pos)
        if not found:
            self.fail()
        self.pos = found.end()
        return codecs.decode(re.sub(r"\\\n", "", found.group(1)).encode("latin-1", "backslashreplace"), "unicode_escape")


host = FakeHost().install()
