"""urllib patch, stub modules, thread keys and the small extra packages."""

import gzip
import json
import os
import subprocess
import sys
import threading
import unittest
import urllib.error
import urllib.request

from fake_host import host

import idj_compat
import idj_urllib

U = "https://site.example"
SITE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class UrllibTests(unittest.TestCase):
    def setUp(self):
        host.reset()
        idj_urllib.install()

    def tearDown(self):
        idj_urllib.uninstall()

    def last(self):
        return host.requests[-1]

    def test_urlopen(self):
        host.on(U + "/a?x=1", "中文", headers={"Content-Type": "text/html; charset=utf-8", "X-Y": ["1", "2"]})
        with urllib.request.urlopen(U + "/a?x=1", timeout=3) as reply:
            self.assertEqual(reply.read().decode(), "中文")
            self.assertEqual((reply.status, reply.getcode(), reply.code, reply.geturl()), (200, 200, 200, U + "/a?x=1"))
            self.assertEqual(reply.headers["Content-Type"], "text/html; charset=utf-8")
            self.assertEqual(reply.info().get_content_charset(), "utf-8")
            self.assertEqual(reply.getheader("x-y"), "1, 2")
        sent = self.last()
        self.assertEqual((sent["timeout"], sent["verify"], sent["redirect"], sent["method"]), (3000, True, False, "GET"))
        self.assertTrue(sent["headers"]["User-Agent"].startswith("Python-urllib/"))

    def test_request_object(self):
        host.on(U + "/p", handler=lambda r: json.dumps([r["method"], r["body"].decode(), r["headers"].get("X-A")]))
        req = urllib.request.Request(U + "/p", data=b"k=v", headers={"User-Agent": "UA", "x-a": "1"})
        self.assertEqual(json.loads(urllib.request.urlopen(req).read()), ["POST", "k=v", "1"])
        self.assertEqual(self.last()["headers"]["User-Agent"], "UA")
        self.assertEqual(self.last()["headers"]["Content-Type"], "application/x-www-form-urlencoded")
        self.assertNotIn("Content-Length", self.last()["headers"])
        self.assertNotIn("Host", self.last()["headers"])
        req = urllib.request.Request(U + "/p", data=b"", method="PUT")
        urllib.request.urlopen(req)
        self.assertEqual(self.last()["method"], "PUT")

    def test_redirects_and_cookies(self):
        import http.cookiejar

        host.on(U + "/1", status=302, headers={"Location": "/2", "Set-Cookie": "a=1; Path=/, b=2; Path=/"})
        host.on(U + "/2", handler=lambda r: r["headers"].get("Cookie", "none"))
        self.assertEqual(urllib.request.urlopen(U + "/1").geturl(), U + "/2")
        jar = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        opener.addheaders = [("User-Agent", "opener")]
        self.assertEqual(sorted(opener.open(U + "/1").read().decode().split("; ")), ["a=1", "b=2"])
        self.assertEqual(self.last()["headers"]["User-Agent"], "opener")

        class Stop(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None

        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.build_opener(Stop).open(U + "/1")
        self.assertEqual((caught.exception.code, caught.exception.headers["Location"]), (302, "/2"))

    def test_errors(self):
        host.on(U + "/404", "missing", status=404)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(U + "/404")
        self.assertEqual((caught.exception.code, caught.exception.reason, caught.exception.read()), (404, "Not Found", b"missing"))
        host.on(U + "/t", error="请求超时")
        with self.assertRaises(urllib.error.URLError) as caught:
            urllib.request.urlopen(U + "/t")
        self.assertIsInstance(caught.exception.reason, TimeoutError)
        with self.assertRaises(urllib.error.URLError):
            urllib.request.urlopen(U + "/unknown")

    def test_contexts(self):
        import ssl

        host.on(U + "/", "ok")
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        urllib.request.urlopen(U + "/", context=context)
        self.assertFalse(self.last()["verify"])
        urllib.request.build_opener(urllib.request.HTTPSHandler(context=context)).open(U + "/")
        self.assertFalse(self.last()["verify"])
        urllib.request.urlopen(U + "/", context=ssl.create_default_context())
        self.assertTrue(self.last()["verify"])
        original = ssl._create_default_https_context
        ssl._create_default_https_context = ssl._create_unverified_context
        try:
            urllib.request.urlopen(U + "/")
            self.assertFalse(self.last()["verify"])
        finally:
            ssl._create_default_https_context = original

    def test_proxy_handlers_are_ignored(self):
        host.on("http://plain.example/", "ok")
        proxy = urllib.request.ProxyHandler({"http": "http://127.0.0.1:1", "https": "http://127.0.0.1:1"})
        opener = urllib.request.build_opener(proxy)
        self.assertEqual(opener.open("http://plain.example/").read(), b"ok")
        urllib.request.install_opener(opener)
        self.assertEqual(urllib.request.urlopen("http://plain.example/").read(), b"ok")

    def test_content_encoding(self):
        host.on(U + "/", b"decoded by the host", headers={"Content-Encoding": "gzip", "Content-Length": "5"})
        reply = urllib.request.urlopen(U + "/")
        self.assertIsNone(reply.headers["Content-Encoding"])
        self.assertEqual(reply.headers["Content-Length"], "19")
        self.assertEqual(reply.read(), b"decoded by the host")
        # A script that asks for gzip decompresses by itself.
        req = urllib.request.Request(U + "/", headers={"Accept-Encoding": "gzip"})
        reply = urllib.request.urlopen(req)
        self.assertEqual(reply.info().get("Content-Encoding"), "gzip")
        self.assertEqual(gzip.decompress(reply.read()), b"decoded by the host")

    def test_urlretrieve_and_fragment(self):
        host.on(U + "/f", b"data")
        path, headers = urllib.request.urlretrieve(U + "/f#x")
        try:
            with open(path, "rb") as fp:
                self.assertEqual(fp.read(), b"data")
        finally:
            urllib.request.urlcleanup()

    def test_install_is_reversible(self):
        idj_urllib.install()
        patched = urllib.request.urlopen
        idj_urllib.uninstall()
        self.assertIsNot(urllib.request.urlopen, patched)
        idj_urllib.uninstall()


class StubTests(unittest.TestCase):
    def test_ssl_stub(self):
        ssl = idj_compat._build_ssl()
        context = ssl.create_default_context(cafile="nowhere")
        self.assertEqual((context.verify_mode, context.check_hostname), (ssl.CERT_REQUIRED, True))
        context.verify_mode = ssl.CERT_NONE
        context.set_ciphers("DEFAULT@SECLEVEL=1")
        context.minimum_version = ssl.TLSVersion.TLSv1
        context.options |= ssl.OP_NO_SSLv3 | 0x4
        self.assertEqual(ssl._create_unverified_context().verify_mode, 0)
        ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).load_verify_locations("x")
        self.assertTrue(issubclass(ssl.SSLError, OSError))
        self.assertTrue(issubclass(ssl.CertificateError, ssl.SSLError))
        with self.assertRaisesRegex(NotImplementedError, "wrap_socket"):
            context.wrap_socket(None)

    def test_socket_stub(self):
        socket = idj_compat._build_socket()
        socket.setdefaulttimeout(7)
        self.assertEqual(socket.getdefaulttimeout(), 7)
        self.assertEqual(socket.inet_ntoa(socket.inet_aton("1.2.3.4")), "1.2.3.4")
        self.assertEqual(socket.inet_ntop(socket.AF_INET6, socket.inet_pton(socket.AF_INET6, "::1")), "::1")
        self.assertIs(socket.timeout, TimeoutError)
        for call in (socket.socket, socket.gethostbyname, socket.create_connection):
            with self.assertRaisesRegex(NotImplementedError, "socket"):
                call("x")

    def run_bare(self, code):
        """Run code in an interpreter whose optional C extensions are missing, like the iOS build."""
        blocked = ("_socket", "_ssl", "_codecs_cn", "_codecs_tw", "_multibytecodec", "_hashlib", "_md5", "_sha1", "_sha2",
                   "pyexpat")
        setup = (
            "import sys; sys.dont_write_bytecode = True\n"
            "for name in %r: sys.modules[name] = None\n"
            "sys.path[:0] = [%r, %r]\n"
            "import logging; logging.disable(logging.CRITICAL)\n"
            "import json, types\n"
            "calls = []\n"
            "def call(name, args):\n"
            "    args = json.loads(args); calls.append((name, args))\n"
            "    if name == 'http':\n"
            "        import base64\n"
            "        return json.dumps({'v': {'code': 200, 'url': args['url'], 'headers': {}, 'body': "
            "base64.b64encode(b'body').decode()}})\n"
            "    if name == 'hash': return json.dumps({'v': 'ab' * 16})\n"
            "    if name == 'gbk' and args['op'] == 'encode': return json.dumps({'v': '1tA='})\n"
            "    if name == 'gbk': return json.dumps({'v': '\\u4e2d'})\n"
            "    return json.dumps({'e': 'unexpected ' + name})\n"
            "host = types.ModuleType('_idj_host'); host.call = call; sys.modules['_idj_host'] = host\n"
            "import idj_compat; idj_compat.install(); idj_compat.install()\n"
        ) % (blocked, SITE, os.path.join(SITE, "tests"))
        done = subprocess.run([sys.executable, "-I", "-c", setup + code], capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout.split()

    def test_install_is_lazy(self):
        code = (
            "import sys; sys.dont_write_bytecode = True; sys.path.insert(0, %r)\n"
            "import idj_compat; idj_compat.install()\n"
            "print([m for m in ('urllib.request', 'http.client', 'ssl', 'socket', 'hashlib', 'email') if m in sys.modules])\n"
            "import urllib.request\n"
            "print(urllib.request.urlopen.__module__, urllib.request.HTTPHandler.http_open.__module__)\n"
            "print(type(urllib.request.__spec__.loader).__name__)\n"
        ) % SITE
        done = subprocess.run([sys.executable, "-I", "-c", code], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.split("\n")[:3], ["[]", "idj_urllib idj_urllib", "SourceFileLoader"])

    def test_bare_interpreter_urllib(self):
        out = self.run_bare(
            "import ssl, socket, urllib.request, http.cookiejar\n"
            "assert ssl.__idj_stub__ and socket.__idj_stub__\n"
            "ctx = ssl._create_unverified_context()\n"
            "print(urllib.request.urlopen('https://s.example/', context=ctx).read().decode())\n"
            "print(calls[-1][1]['verify'])\n"
            "opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))\n"
            "print(opener.open('https://s.example/').read().decode())\n"
            "ssl._create_default_https_context = ssl._create_unverified_context\n"
            "urllib.request.urlopen('https://s.example/'); print(calls[-1][1]['verify'])\n"
        )
        self.assertEqual(out, ["body", "False", "body", "False"])

    def test_bare_interpreter_requests(self):
        out = self.run_bare(
            "import requests, urllib3\n"
            "from urllib3.util.ssl_ import create_urllib3_context\n"
            "create_urllib3_context(ciphers='x')\n"
            "print(requests.get('https://s.example/').text)\n"
            "requests.packages.urllib3.disable_warnings()\n"
            "from lxml import etree\n"
            "import bs4, pyquery\n"
            "print(bs4.BeautifulSoup('<p>x', 'html.parser').p.text)\n"
        )
        self.assertEqual(out, ["body", "x"])

    def test_bare_interpreter_codecs_and_hashes(self):
        out = self.run_bare(
            "print(b'\\xd6\\xd0'.decode('gbk') == '\\u4e2d', '\\u4e2d'.encode('gb2312') == b'\\xd6\\xd0')\n"
            "import codecs, io\n"
            "print(io.TextIOWrapper(io.BytesIO(b'\\xd6\\xd0'), 'gb18030').read() == '\\u4e2d')\n"
            "import hashlib, hmac\n"
            "print(hashlib.md5(b'x').hexdigest() == 'ab' * 16, hashlib.new('MD5', b'x').digest() == b'\\xab' * 16)\n"
            "print(len(hmac.new(b'k', b'm', 'md5').hexdigest()), len(hmac.new(b'k', b'm', hashlib.md5).hexdigest()))\n"
            "from Crypto.Hash import MD5\n"
            "print(MD5.new(b'x').hexdigest() == 'ab' * 16)\n"
        )
        self.assertEqual(out, ["True", "True", "True", "True", "True", "32", "32", "True"])


class ThreadKeyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = threading.Thread.start
        idj_compat._install_threads()
        idj_compat._install_threads()  # idempotent

    @classmethod
    def tearDownClass(cls):
        threading.Thread.start = cls.original
        module = sys.modules.get("concurrent.futures.thread")
        if module is not None and hasattr(module.ThreadPoolExecutor.submit, "__wrapped__"):
            module.ThreadPoolExecutor.submit = module.ThreadPoolExecutor.submit.__wrapped__

    def setUp(self):
        host.set_key("spider-1")

    def tearDown(self):
        host.set_key("")

    def test_thread(self):
        seen = []

        class Worker(threading.Thread):
            def run(self):
                seen.append(host.get_key())

        for thread in (threading.Thread(target=lambda: seen.append(host.get_key())), Worker()):
            thread.start()
            thread.join()
            self.assertNotIn("run", thread.__dict__)
        timer = threading.Timer(0, lambda: seen.append(host.get_key()))
        timer.start()
        timer.join()
        self.assertEqual(seen, ["spider-1"] * 3)

    def test_nested(self):
        seen = []

        def outer():
            inner = threading.Thread(target=lambda: seen.append(host.get_key()))
            inner.start()
            inner.join()

        thread = threading.Thread(target=outer)
        thread.start()
        thread.join()
        self.assertEqual(seen, ["spider-1"])

    def test_executor(self):
        from concurrent.futures import ThreadPoolExecutor

        with ThreadPoolExecutor(2) as pool:
            self.assertEqual(list(pool.map(lambda _: host.get_key(), range(4))), ["spider-1"] * 4)
            # the same pool used on behalf of another spider
            host.set_key("spider-2")
            self.assertEqual(pool.submit(host.get_key).result(), "spider-2")
            host.set_key("spider-1")
            self.assertEqual(pool.submit(lambda a, b=0: (a, b, host.get_key()), 1, b=2).result(), (1, 2, "spider-1"))
            with self.assertRaises(ZeroDivisionError):
                pool.submit(lambda: 1 / 0).result()

    def test_exceptions_still_surface(self):
        caught = []
        old = threading.excepthook
        threading.excepthook = lambda args: caught.append(args.exc_type)
        try:
            thread = threading.Thread(target=lambda: 1 / 0)
            thread.start()
            thread.join()
        finally:
            threading.excepthook = old
        self.assertEqual(caught, [ZeroDivisionError])
        with self.assertRaises(RuntimeError):
            thread.start()


class ExtraTests(unittest.TestCase):
    def setUp(self):
        host.reset()

    def test_json5(self):
        import json5

        self.assertEqual(json5.loads("{a: 'x', /* c */ b: [1, 2,], // d\n c: 0x10}"), {"a": "x", "b": [1, 2], "c": 16})
        self.assertEqual(json5.loads(b'{"a": 1.5}', parse_float=str), {"a": "1.5"})
        with self.assertRaises(ValueError):
            json5.loads("{a:")
        with self.assertRaises(ValueError):
            json5.loads(" ")
        self.assertEqual(json5.loads(json5.dumps({"a": [None, True]})), {"a": [None, True]})

    def test_json_aliases(self):
        import simplejson
        import ujson

        self.assertEqual(simplejson.loads(simplejson.dumps({"a": "中"}, ensure_ascii=False)), {"a": "中"})
        self.assertEqual(ujson.dumps({"a": "/"}, ensure_ascii=False), '{"a":"\\/"}')
        self.assertEqual(ujson.loads('{"a":[1]}'), {"a": [1]})
        with self.assertRaises(simplejson.JSONDecodeError):
            simplejson.loads("x")
        with self.assertRaises(ValueError):
            ujson.loads("x")

    def test_fake_useragent(self):
        from fake_useragent import UserAgent

        ua = UserAgent()
        for text in (ua.random, ua.chrome, ua["firefox"], ua.safari, ua.edge, UserAgent(browsers=["chrome"]).random):
            self.assertTrue(text.startswith("Mozilla/5.0 ("))
        self.assertIn("Firefox", ua.firefox)
        self.assertIn("Mobile", UserAgent(platforms="mobile").random)

    def test_cachetools(self):
        from cachetools import FIFOCache, LRUCache, TTLCache, cached
        from cachetools.func import ttl_cache

        lru = LRUCache(2)
        lru["a"], lru["b"] = 1, 2
        lru["a"]
        lru["c"] = 3
        self.assertEqual((sorted(lru), len(lru), lru.get("b"), lru.currsize), (["a", "c"], 2, None, 2))
        fifo = FIFOCache(2)
        fifo["a"], fifo["b"] = 1, 2
        fifo["a"]
        fifo["c"] = 3
        self.assertEqual(sorted(fifo), ["b", "c"])
        clock = [0]
        ttl = TTLCache(10, 5, timer=lambda: clock[0])
        ttl["a"] = 1
        self.assertIn("a", ttl)
        clock[0] = 6
        self.assertNotIn("a", ttl)
        with self.assertRaises(KeyError):
            ttl["a"]
        self.assertEqual((len(ttl), ttl.get("a", "d"), list(ttl)), (0, "d", []))
        calls = []

        @cached(TTLCache(10, 60))
        def slow(x, y=1):
            calls.append(x)
            return x + y

        self.assertEqual((slow(1), slow(1), slow(1, y=2)), (2, 2, 3))
        self.assertEqual(calls, [1, 1])
        slow.cache_clear()
        slow(1)
        self.assertEqual(len(calls), 3)

        @ttl_cache(maxsize=10, ttl=60)
        def other(x):
            calls.append("o")
            return x

        other(1), other(1)
        self.assertEqual(calls.count("o"), 1)
        with self.assertRaises(ValueError):
            LRUCache(1, getsizeof=len)["k"] = "too long"

    def test_charset_modules(self):
        import certifi
        import chardet
        import charset_normalizer

        data = "中文内容检测，播放列表".encode("gbk")
        self.assertEqual(chardet.detect(data)["encoding"], "GB2312")
        self.assertEqual(data.decode(chardet.detect(data)["encoding"]), "中文内容检测，播放列表")
        self.assertEqual(chardet.detect("中文".encode())["encoding"], "utf-8")
        self.assertEqual(charset_normalizer.detect(data)["encoding"], "gb18030")
        self.assertEqual(str(charset_normalizer.from_bytes(data).best()), "中文内容检测，播放列表")
        detector = chardet.UniversalDetector()
        detector.feed(data)
        self.assertEqual(detector.close()["encoding"], "GB2312")
        self.assertIsInstance(certifi.where(), str)


class IdiomTests(unittest.TestCase):
    """A whole little spider, the way scripts for this app are written."""

    def setUp(self):
        host.reset()

    def test_spider(self):
        import base64
        import re

        import requests
        from Crypto.Cipher import AES
        from Crypto.Util.Padding import pad, unpad
        from lxml import etree
        from pyquery import PyQuery as pq

        key, iv = b"0123456789abcdef", b"fedcba9876543210"
        sealed = base64.b64encode(AES.new(key, AES.MODE_CBC, iv).encrypt(pad(b'{"url":"https://v.example/1.m3u8"}', 16)))
        home = '<html><body><div class="m"><a class="v" href="/v/7.html" title="剧">x</a></div></body></html>'
        play = "<script>var cfg = {\"data\":\"%s\"};</script>" % sealed.decode()
        host.on(U + "/", home.encode("gbk"), headers={"Content-Type": "text/html", "Set-Cookie": "t=1"})
        host.on(U + "/v/7.html", handler=lambda r: play if r["headers"].get("Cookie") == "t=1" else "denied")

        class Spider:
            def __init__(self):
                self.session = requests.Session()
                self.session.headers.update({"User-Agent": "Mozilla/5.0", "Referer": U})

            def fetch(self, url, **kwargs):
                return self.session.get(url, timeout=10, verify=False, **kwargs)

            def home(self):
                rsp = self.fetch(U + "/")
                rsp.encoding = "gbk"
                return [(a.attr("href"), a.attr("title")) for a in pq(rsp.text)(".m .v").items()]

            def player(self, path):
                page = self.fetch(U + path).text
                script = etree.HTML(page).xpath('//script[contains(text(), "cfg")]/text()')[0]
                data = json.loads(re.search(r"cfg = (.*?);", script).group(1))["data"]
                plain = unpad(AES.new(key, AES.MODE_CBC, iv).decrypt(base64.b64decode(data)), AES.block_size)
                return json.loads(plain.decode())["url"]

        spider = Spider()
        self.assertEqual(spider.home(), [("/v/7.html", "剧")])
        self.assertEqual(spider.player("/v/7.html"), "https://v.example/1.m3u8")
        self.assertFalse(host.requests[-1]["verify"])


if __name__ == "__main__":
    unittest.main()
