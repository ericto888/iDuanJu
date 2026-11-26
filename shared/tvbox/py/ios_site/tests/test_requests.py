import copy
import gzip
import io
import json
import pickle
import re
import sys
import time
import unittest

from fake_host import host

import requests

U = "https://site.example"


class Base(unittest.TestCase):
    def setUp(self):
        host.reset()

    def last(self):
        return host.requests[-1]


class RequestTests(Base):
    def test_defaults(self):
        host.on(U + "/", "ok")
        reply = requests.get(U)
        self.assertEqual((reply.text, reply.status_code, reply.ok, bool(reply), reply.reason), ("ok", 200, True, True, "OK"))
        sent = self.last()
        self.assertEqual(sent["method"], "GET")
        self.assertEqual(sent["url"], U + "/")
        self.assertEqual(sent["headers"]["User-Agent"], "python-requests/2.32.3")
        self.assertEqual(sent["headers"]["Accept"], "*/*")
        self.assertEqual((sent["timeout"], sent["verify"], sent["redirect"], sent["body"]), (10000, True, False, None))
        self.assertEqual(host.calls[-1][1]["out"], "b64")
        self.assertEqual(reply.request.headers["Accept-Encoding"], "gzip, deflate")
        self.assertEqual(repr(reply), "<Response [200]>")
        self.assertGreaterEqual(reply.elapsed.total_seconds(), 0)

    def test_params(self):
        host.on(re.compile(""), "ok")
        for params, query in (
            ({"wd": "中文 a", "pg": 1}, "wd=%E4%B8%AD%E6%96%87+a&pg=1"),
            ([("a", "1"), ("a", "2")], "a=1&a=2"),
            ({"a": ["1", "2"], "b": None}, "a=1&a=2"),
            ("x=1&y=2", "x=1&y=2"),
            (b"x=1", "x=1"),
        ):
            requests.get(U + "/s", params=params)
            self.assertEqual(self.last()["url"], U + "/s?" + query)
        reply = requests.get(U + "/s?q=1", params={"b": 2})
        self.assertEqual(reply.url, U + "/s?q=1&b=2")

    def test_url_quoting(self):
        host.on(re.compile(""), "ok")
        for url, want in (
            (U + "/搜索?wd=中 文", U + "/%E6%90%9C%E7%B4%A2?wd=%E4%B8%AD%20%E6%96%87"),
            (U + "/a%2fb%41", U + "/a%2FbA"),
            (U + "/100%", U + "/100%25"),
            (U + "/a/../b/./c", U + "/b/c"),
            (U + "/s?a[]=1&b={x}", U + "/s?a%5B%5D=1&b=%7Bx%7D"),
            ("HTTPS://Site.Example:8443/x#frag", "https://site.example:8443/x"),
            ("  " + U + "/lead", U + "/lead"),
            (U + "/x\n", U + "/x%0A"),
            ("https://[::1]:8080/x", "https://[::1]:8080/x"),
            ("https://中文.example/", "https://xn--fiq228c.example/"),
        ):
            requests.get(url)
            self.assertEqual(self.last()["url"], want)
        self.assertEqual(requests.get(U + "/x#frag").url, U + "/x#frag")

    def test_bad_urls(self):
        exceptions = requests.exceptions
        with self.assertRaisesRegex(exceptions.MissingSchema, "No scheme supplied. Perhaps you meant https://site.example/x"):
            requests.get("site.example/x")
        with self.assertRaises(exceptions.InvalidURL):
            requests.get("http:///x")
        with self.assertRaises(exceptions.InvalidSchema):
            requests.get("ftp://site.example/x")
        self.assertTrue(issubclass(exceptions.MissingSchema, ValueError))

    def test_bodies(self):
        host.on(re.compile(""), "ok")
        form = "application/x-www-form-urlencoded"
        cases = (
            ({"data": {"a": "1", "b": "中"}}, b"a=1&b=%E4%B8%AD", form),
            ({"data": [("a", "1"), ("a", "2")]}, b"a=1&a=2", form),
            ({"data": {"a": ["1", "2"]}}, b"a=1&a=2", form),
            ({"data": "raw=中"}, "raw=中".encode(), None),
            ({"data": b"\x00\xff"}, b"\x00\xff", None),
            ({"json": {"k": "中"}}, b'{"k": "\\u4e2d"}', "application/json"),
            ({"json": []}, b"[]", "application/json"),
            ({"data": io.BytesIO(b"stream")}, b"stream", None),
            ({"data": (chunk for chunk in (b"a", b"b"))}, b"ab", None),
            ({"data": {"a": 1}, "headers": {"Content-Type": "x/y"}}, b"a=1", "x/y"),
        )
        for kwargs, body, kind in cases:
            requests.post(U + "/p", **kwargs)
            self.assertEqual((self.last()["method"], self.last()["body"]), ("POST", body))
            self.assertEqual(self.last()["headers"].get("Content-Type"), kind)
        self.assertNotIn("Content-Length", self.last()["headers"])
        requests.post(U + "/p")
        self.assertIsNone(self.last()["body"])
        for method in ("put", "patch", "delete", "options", "head"):
            getattr(requests, method)(U + "/p")
            self.assertEqual(self.last()["method"], method.upper())
        requests.request("PROPFIND", U + "/p", data={"a": 1})
        self.assertEqual((self.last()["method"], self.last()["body"]), ("PROPFIND", b"a=1"))

    def test_files(self):
        host.on(re.compile(""), "ok")
        requests.post(U, data={"k": "v", "中": "文"}, files={
            "a": ("f.txt", b"one", "text/plain"), "b": b"two", "c": (None, "three"), "d": ("x.bin", io.BytesIO(b"four")),
        })
        kind = self.last()["headers"]["Content-Type"]
        found = re.fullmatch(r"multipart/form-data; boundary=([0-9a-f]{32})", kind)
        self.assertTrue(found)
        self.assertEqual(self.last()["body"].decode(), "".join((
            '--B\r\nContent-Disposition: form-data; name="k"\r\n\r\nv\r\n',
            '--B\r\nContent-Disposition: form-data; name="中"\r\n\r\n文\r\n',
            '--B\r\nContent-Disposition: form-data; name="a"; filename="f.txt"\r\nContent-Type: text/plain\r\n\r\none\r\n',
            '--B\r\nContent-Disposition: form-data; name="b"; filename="b"\r\n\r\ntwo\r\n',
            '--B\r\nContent-Disposition: form-data; name="c"\r\n\r\nthree\r\n',
            '--B\r\nContent-Disposition: form-data; name="d"; filename="x.bin"\r\n\r\nfour\r\n',
            "--B--\r\n",
        )).replace("--B", "--" + found.group(1)))

    def test_headers(self):
        host.on(re.compile(""), "ok")
        requests.get(U, headers={"user-agent": "UA", "X-N": 5, "Accept": None, "Accept-Encoding": "gzip, br"})
        sent = self.last()["headers"]
        self.assertEqual((sent["user-agent"], sent["X-N"]), ("UA", "5"))
        self.assertNotIn("Accept", sent)
        self.assertNotIn("Accept-Encoding", sent)  # left to the host
        self.assertNotIn("User-Agent", sent)
        requests.get(U, headers={"Accept-Encoding": "identity", "Content-Length": "999"})
        self.assertEqual(self.last()["headers"]["Accept-Encoding"], "identity")
        self.assertNotIn("Content-Length", self.last()["headers"])
        with self.assertRaises(requests.exceptions.InvalidHeader):
            requests.get(U, headers={"X": "a\r\nb"})

    def test_timeout_verify_auth(self):
        host.on(re.compile(""), "ok")
        for timeout, want in ((5, 5000), (1.5, 1500), ((3, 20), 20000), ((3, None), 3000), (None, 10000)):
            requests.get(U, timeout=timeout)
            self.assertEqual(self.last()["timeout"], want)
        requests.get(U, verify=False)
        self.assertFalse(self.last()["verify"])
        import certifi

        requests.get(U, verify=certifi.where(), proxies={"http": "http://127.0.0.1:1"}, hooks=None, stream=True)
        self.assertTrue(self.last()["verify"])
        requests.get(U, auth=("user", "pass"))
        self.assertEqual(self.last()["headers"]["Authorization"], "Basic dXNlcjpwYXNz")
        requests.get("https://user:pa%20ss@site.example/")
        self.assertEqual(self.last()["headers"]["Authorization"], "Basic dXNlcjpwYSBzcw==")
        self.assertEqual(self.last()["url"], U + "/")
        from requests.auth import AuthBase, HTTPBasicAuth

        requests.get(U, auth=HTTPBasicAuth("u", "p"))
        self.assertEqual(self.last()["headers"]["Authorization"], "Basic dTpw")

        class Token(AuthBase):
            def __call__(self, r):
                r.headers["X-Token"] = "t"
                return r

        requests.get(U, auth=Token())
        self.assertEqual(self.last()["headers"]["X-Token"], "t")

    def test_errors(self):
        exceptions = requests.exceptions
        for message, kind in (
            ("请求超时", exceptions.ReadTimeout), ("The request timed out.", exceptions.Timeout),
            ("connect timeout", exceptions.ConnectTimeout), ("无法连接到服务器", exceptions.ConnectionError),
            ("SSL certificate problem", exceptions.SSLError),
        ):
            host.on(U + "/e", error=message)
            with self.assertRaises(kind) as caught:
                requests.get(U + "/e")
            self.assertIn(message, str(caught.exception))
            self.assertEqual(caught.exception.request.url, U + "/e")
            self.assertIsInstance(caught.exception, requests.RequestException)
            self.assertIsInstance(caught.exception, IOError)
        self.assertIs(requests.ConnectionError, exceptions.ConnectionError)
        with self.assertRaises(ValueError):
            requests.get(U, timeout=0)

    def test_raise_for_status(self):
        host.on(U + "/404", "gone", status=404)
        host.on(U + "/500", "x", status=500)
        reply = requests.get(U + "/404")
        self.assertFalse(reply)
        with self.assertRaisesRegex(requests.HTTPError, r"404 Client Error: Not Found for url: https://site.example/404") as c:
            reply.raise_for_status()
        self.assertIs(c.exception.response, reply)
        with self.assertRaisesRegex(requests.HTTPError, "500 Server Error"):
            requests.get(U + "/500").raise_for_status()
        self.assertEqual(reply.status_code, requests.codes.not_found)
        self.assertEqual(requests.codes.ok, 200)
        self.assertEqual(requests.codes["teapot"], 418)

    def test_adapter_subclass(self):
        """TLS adapters override init_poolmanager; retrying ones override send."""
        from requests.adapters import HTTPAdapter, Retry
        from requests.packages.urllib3.util.ssl_ import create_urllib3_context

        class Adapter(HTTPAdapter):
            calls = 0

            def init_poolmanager(self, *args, **kwargs):
                kwargs["ssl_context"] = create_urllib3_context(ciphers="DEFAULT@SECLEVEL=1")
                return super().init_poolmanager(*args, **kwargs)

            def send(self, request, **kwargs):
                Adapter.calls += 1
                request.headers["X-Adapter"] = "1"
                return super().send(request, **kwargs)

        host.on(re.compile(""), "ok")
        session = requests.Session()
        session.mount("https://", Adapter(max_retries=Retry(total=3, backoff_factor=1, status_forcelist=[500])))
        session.get(U)
        self.assertEqual((Adapter.calls, self.last()["headers"]["X-Adapter"]), (1, "1"))
        session.get("http://plain.example/")
        self.assertEqual(Adapter.calls, 1)

    def test_hooks(self):
        host.on(re.compile(""), "ok")
        seen = []
        requests.get(U, hooks={"response": lambda r, *a, **k: seen.append(r.url)})
        self.assertEqual(seen, [U + "/"])
        session = requests.Session()
        session.hooks["response"].append(lambda r, **k: seen.append("s"))
        session.get(U)
        self.assertEqual(seen[-1], "s")


class ResponseTests(Base):
    def reply(self, body, kind=None, **headers):
        head = dict(headers)
        if kind:
            head["Content-Type"] = kind
        host.on(U + "/r", body, headers=head)
        return requests.get(U + "/r")

    def test_header_charset(self):
        reply = self.reply("中文".encode("gbk"), "text/html; charset=GBK")
        self.assertEqual((reply.encoding, reply.text), ("GBK", "中文"))
        reply = self.reply("镕朱".encode("gb18030"), "text/html; charset=gb2312")  # outside GB2312 proper
        self.assertEqual(reply.text, "镕朱")
        reply = self.reply("中文".encode(), "text/html; charset=bogus")
        self.assertEqual(reply.text, "中文")

    def test_settable_encoding(self):
        reply = self.reply("中文".encode("gbk"), "text/html; charset=utf-8")
        self.assertIn("�", reply.text)
        reply.encoding = "gbk"
        self.assertEqual(reply.text, "中文")
        reply.encoding = reply.apparent_encoding
        self.assertEqual((reply.encoding, reply.text), ("gb18030", "中文"))
        reply.encoding = None
        self.assertEqual(reply.text, "中文")

    def test_sniffing(self):
        page = '<html><head><meta charset="%s"></head><body>中文标题，欢迎观看</body></html>'
        for codec in ("utf-8", "gbk"):
            reply = self.reply((page % codec).encode(codec), "text/html")
            self.assertEqual(reply.encoding, "ISO-8859-1")
            self.assertIn("中文标题", reply.text)
        reply = self.reply("没有声明的国标页面，视频列表".encode("gbk"), "text/html")
        self.assertEqual(reply.text, "没有声明的国标页面，视频列表")
        reply = self.reply("没有声明".encode(), None)
        self.assertEqual((reply.encoding, reply.text), (None, "没有声明"))
        reply = self.reply("﻿带BOM".encode(), "text/html")
        self.assertEqual(reply.text, "带BOM")

    def test_latin1_repair_idiom(self):
        reply = self.reply("中文".encode(), "text/html")
        self.assertEqual(reply.text.encode("ISO-8859-1").decode("utf-8"), "中文")
        self.assertEqual(reply.text.encode(reply.encoding).decode(reply.apparent_encoding), "中文")
        self.assertEqual(reply.text.encode("utf-8"), "中文".encode())
        self.assertTrue(re.search("中", reply.text))
        for twin in (copy.deepcopy({"t": reply.text})["t"], copy.copy(reply.text), pickle.loads(pickle.dumps(reply.text))):
            self.assertEqual((type(twin), twin), (str, "中文"))
        self.assertEqual(json.dumps(reply.text, ensure_ascii=False), '"中文"')

    def test_json(self):
        reply = self.reply('{"名": [1, 2.5, null]}', "application/json")
        self.assertEqual(reply.json(), {"名": [1, 2.5, None]})
        self.assertEqual(self.reply('{"a": "中"}'.encode("gbk"), "text/plain; charset=gbk").json(), {"a": "中"})
        self.assertEqual(self.reply('﻿{"a": "中"}', "text/html").json(), {"a": "中"})
        self.assertEqual(self.reply('{"a": "中"}'.encode("utf-16"), "application/json").json(), {"a": "中"})
        self.assertEqual(self.reply('{"a": "中"}'.encode("gbk"), "application/json").json(), {"a": "中"})
        with self.assertRaises(requests.exceptions.JSONDecodeError) as caught:
            self.reply("<html>", "text/html").json()
        self.assertIsInstance(caught.exception, json.JSONDecodeError)
        self.assertIsInstance(caught.exception, requests.RequestException)
        self.assertIsInstance(caught.exception, ValueError)

    def test_content_is_exact(self):
        body = bytes(range(256))
        reply = self.reply(body, "application/octet-stream")
        self.assertEqual(reply.content, body)
        self.assertEqual(b"".join(reply.iter_content(100)), body)
        self.assertEqual(len(list(reply.iter_content(chunk_size=1))), 256)
        self.assertEqual(reply.raw.read(10), body[:10])
        self.assertEqual(reply.raw.read(), body[10:])

    def test_gzip_left_by_host(self):
        reply = self.reply(gzip.compress(b"plain"), "text/plain", **{"Content-Encoding": "gzip"})
        self.assertEqual(reply.content, b"plain")
        raw = gzip.compress(b"file")
        self.assertEqual(self.reply(raw, "application/gzip").content, raw)

    def test_iter_lines(self):
        reply = self.reply("a\nb\r\n中\n", "text/plain; charset=utf-8")
        self.assertEqual(list(reply.iter_lines()), [b"a", b"b", "中".encode()])
        self.assertEqual(list(reply.iter_lines(decode_unicode=True)), ["a", "b", "中"])
        self.assertEqual(list(reply.iter_lines(delimiter=b"\n"))[0], b"a")
        self.assertEqual("".join(reply.iter_content(2, decode_unicode=True)), "a\nb\r\n中\n")
        with reply as same:
            self.assertEqual(same.text[0], "a")
        reply.close()
        self.assertEqual(reply.content[:1], b"a")

    def test_headers_are_case_insensitive(self):
        reply = self.reply("x", "text/plain", **{"X-Multi": ["a", "b"], "LOCATION": "/z"})
        self.assertEqual(reply.headers["x-multi"], "a, b")
        self.assertEqual(reply.headers.get("location"), "/z")
        self.assertIn("content-TYPE", reply.headers)
        self.assertIsNone(reply.headers.get("nope"))
        self.assertEqual(dict(reply.headers)["Content-Type"], "text/plain")

    def test_pickle(self):
        reply = pickle.loads(pickle.dumps(self.reply("中", "text/plain; charset=utf-8")))
        self.assertEqual((reply.text, reply.status_code), ("中", 200))

    def test_links(self):
        reply = self.reply("x", None, Link='<https://a.example/2>; rel="next", <https://a.example/9>; rel="last"')
        self.assertEqual(reply.links["next"]["url"], "https://a.example/2")


class SessionTests(Base):
    def test_defaults_are_merged(self):
        host.on(re.compile(""), "ok")
        session = requests.session()
        session.headers.update({"User-Agent": "UA", "X-A": "1"})
        session.params = {"k": "v"}
        session.auth = ("u", "p")
        session.verify = False
        session.get(U + "/x", params={"q": "1"}, headers={"X-A": None, "x-b": "2"})
        sent = self.last()
        self.assertEqual(sent["url"], U + "/x?k=v&q=1")
        self.assertEqual((sent["headers"]["User-Agent"], sent["headers"]["x-b"]), ("UA", "2"))
        self.assertNotIn("X-A", sent["headers"])
        self.assertFalse(sent["verify"])
        self.assertTrue(sent["headers"]["Authorization"].startswith("Basic "))
        session.headers = {"User-Agent": "plain dict"}
        session.get(U + "/x", params=[("a", "1"), ("a", "2")])
        self.assertEqual(self.last()["url"], U + "/x?k=v&a=1&a=2")
        self.assertEqual(self.last()["headers"]["User-Agent"], "plain dict")
        with requests.Session() as other:
            self.assertEqual(other.post(U, json={"a": 1}).status_code, 200)

    def test_cookies_persist(self):
        host.on(U + "/login", "in", headers={"Set-Cookie": ["sid=abc; Path=/; HttpOnly", "theme=dark"]})
        host.on(U + "/me", handler=lambda r: r["headers"].get("Cookie", ""))
        session = requests.Session()
        reply = session.post(U + "/login", data={"u": 1})
        self.assertEqual(reply.cookies.get_dict(), {"sid": "abc", "theme": "dark"})
        self.assertEqual(reply.cookies["sid"], "abc")
        self.assertEqual(requests.utils.dict_from_cookiejar(session.cookies), {"sid": "abc", "theme": "dark"})
        self.assertEqual(session.get(U + "/me").text, "sid=abc; theme=dark")
        self.assertEqual(session.get(U + "/me", cookies={"extra": "1"}).text, "sid=abc; theme=dark; extra=1")
        self.assertEqual(session.cookies.get_dict(), {"sid": "abc", "theme": "dark"})
        self.assertEqual(session.get(U + "/me", headers={"Cookie": "own=1"}).text, "own=1")
        self.assertEqual(requests.get(U + "/me").text, "")
        self.assertEqual(requests.get(U + "/me", cookies={"a": "1", "b": "2"}).text, "a=1; b=2")
        self.assertEqual(requests.get(U + "/me", cookies=reply.cookies).text, "sid=abc; theme=dark")

    def test_comma_joined_set_cookie(self):
        host.on(U + "/c", "x", headers={
            "Set-Cookie": "a=1; expires=Wed, 21 Oct 2099 07:28:00 GMT; path=/, b=2; Max-Age=60, c=3,4"})
        self.assertEqual(requests.get(U + "/c").cookies.get_dict(), {"a": "1", "b": "2", "c": "3,4"})

    def test_scope_rules(self):
        host.on(re.compile("/set$"), "x", headers={"Set-Cookie": [
            "wide=1; Domain=example.com; Path=/", "deep=2; Path=/a/b", "sec=3; Secure", "gone=4; Max-Age=0",
            "old=5; Expires=Thu, 01 Jan 1970 00:00:00 GMT", "evil=6; Domain=other.com", "tld=7; Domain=com"]})
        host.on(re.compile("/echo"), handler=lambda r: r["headers"].get("Cookie", ""))
        session = requests.Session()
        session.get("https://www.example.com/set")
        self.assertEqual(sorted(session.cookies.keys()), ["deep", "sec", "wide"])
        self.assertEqual(session.get("https://api.example.com/echo").text, "wide=1")
        self.assertEqual(session.get("http://www.example.com/echo").text, "wide=1")
        self.assertEqual(session.get("https://www.example.com/echo").text, "wide=1; sec=3")
        self.assertEqual(session.get("https://www.example.com/a/b/echo").text, "deep=2; wide=1; sec=3")
        self.assertEqual(session.get("https://elsewhere.org/echo").text, "")
        host.on(re.compile("/drop$"), "x", headers={"Set-Cookie": "wide=; Domain=.example.com; Path=/; Max-Age=0"})
        session.get("https://www.example.com/drop")
        self.assertNotIn("wide", session.cookies)

    def test_odd_cookies(self):
        host.on(U + "/c", "x", headers={"Set-Cookie": ["flag", "=v", "", "a=b=c", "e="]})
        host.on(U + "/e", handler=lambda r: r["headers"].get("Cookie", ""))
        session = requests.Session()
        session.get(U + "/c")
        self.assertEqual(session.get(U + "/e").text, "flag; a=b=c; e=")

    def test_expiry(self):
        host.on(U + "/c", "x", headers={"Set-Cookie": "a=1; Max-Age=1"})
        host.on(U + "/e", handler=lambda r: r["headers"].get("Cookie", "none"))
        session = requests.Session()
        session.get(U + "/c")
        self.assertEqual(session.get(U + "/e").text, "a=1")
        for cookie in session.cookies:
            cookie.expires = int(time.time()) - 5
        self.assertEqual(session.get(U + "/e").text, "none")

    def test_jar_api(self):
        jar = requests.cookies.RequestsCookieJar()
        jar.set("a", "1", domain="x.example", path="/p")
        jar["b"] = "2"
        jar.update({"c": "3"})
        self.assertEqual((jar.get("a"), jar.get("zz", "d"), jar["b"]), ("1", "d", "2"))
        self.assertEqual(jar.items(), [("a", "1"), ("b", "2"), ("c", "3")])
        self.assertEqual(dict(jar), {"a": "1", "b": "2", "c": "3"})
        self.assertEqual([(c.name, c.value) for c in jar][0], ("a", "1"))
        self.assertEqual(jar.get_dict(domain="x.example"), {"a": "1"})
        self.assertEqual("; ".join("%s=%s" % kv for kv in jar.items()), "a=1; b=2; c=3")
        self.assertIn("a", jar)
        jar.set("a", "other", domain="y.example")
        with self.assertRaises(requests.cookies.CookieConflictError):
            jar.get("a")
        self.assertEqual(jar.get("a", domain="y.example"), "other")
        self.assertEqual(len(jar.copy()), 4)
        del jar["a"]
        self.assertEqual(jar.keys(), ["b", "c"])
        jar.clear()
        self.assertFalse(len(jar))
        self.assertEqual(requests.utils.cookiejar_from_dict({"k": "v"}).get_dict(), {"k": "v"})
        session = requests.Session()
        session.cookies.set("k", "v")
        session.cookies = requests.utils.add_dict_to_cookiejar(session.cookies, {"z": "9"})
        host.on(U + "/", handler=lambda r: r["headers"]["Cookie"])
        self.assertEqual(session.get(U).text, "k=v; z=9")
        self.assertIn("RequestsCookieJar", repr(session.cookies))

    def test_redirects(self):
        host.on(U + "/a", status=302, headers={"Location": "/b?x=1", "Set-Cookie": "hop=1; Path=/"})
        host.on(U + "/b?x=1", status=301, headers={"location": "https://other.example/c"})
        host.on("https://other.example/c", handler=lambda r: {"body": r["method"] + "|" + r["headers"].get("Cookie", "")})
        session = requests.Session()
        reply = session.post(U + "/a", data={"k": "v"}, headers={"Authorization": "secret"})
        self.assertEqual(reply.text, "GET|")
        self.assertEqual(reply.url, "https://other.example/c")
        self.assertEqual([r.status_code for r in reply.history], [302, 301])
        self.assertEqual([(r["method"], r["url"]) for r in host.requests], [
            ("POST", U + "/a"), ("GET", U + "/b?x=1"), ("GET", "https://other.example/c")])
        self.assertIsNone(host.requests[1]["body"])
        self.assertNotIn("Content-Type", host.requests[1]["headers"])
        self.assertEqual(host.requests[1]["headers"]["Cookie"], "hop=1")
        self.assertEqual(host.requests[1]["headers"]["Authorization"], "secret")
        self.assertNotIn("Authorization", host.requests[2]["headers"])
        self.assertEqual(session.cookies.get_dict(), {"hop": "1"})
        self.assertEqual(reply.history[0].cookies.get_dict(), {"hop": "1"})

    def test_redirect_variants(self):
        host.on(U + "/307", status=307, headers={"Location": "//site.example/end"})
        host.on(U + "/303", status=303, headers={"Location": "end"})
        host.on(U + "/loop", status=302, headers={"Location": "/loop"})
        host.on(U + "/cn", status=302, headers={"Location": "/搜索".encode().decode("latin-1")})
        host.on(U + "/end", handler=lambda r: "%s %s" % (r["method"], (r["body"] or b"").decode()))
        host.on(U + "/%E6%90%9C%E7%B4%A2", "cn")
        self.assertEqual(requests.post(U + "/307", data="keep").text, "POST keep")
        self.assertEqual(requests.put(U + "/303", data="drop").text, "GET ")
        reply = requests.get(U + "/307", allow_redirects=False)
        self.assertEqual((reply.status_code, reply.headers["location"], reply.is_redirect), (307, "//site.example/end", True))
        self.assertEqual(reply.next.url, U + "/end")
        self.assertEqual(requests.head(U + "/307").status_code, 307)
        self.assertEqual(requests.get(U + "/cn").text, "cn")
        with self.assertRaises(requests.TooManyRedirects):
            requests.get(U + "/loop")
        session = requests.Session()
        session.max_redirects = 2
        with self.assertRaisesRegex(requests.TooManyRedirects, "Exceeded 2 redirects"):
            session.get(U + "/loop")

    def test_prepared(self):
        host.on(re.compile(""), "ok")
        session = requests.Session()
        prepared = session.prepare_request(requests.Request("post", U + "/p", data={"a": 1}, headers={"X": "y"}))
        self.assertEqual((prepared.method, prepared.url, prepared.body, prepared.path_url), ("POST", U + "/p", "a=1", "/p"))
        self.assertEqual(session.send(prepared, timeout=3).status_code, 200)
        self.assertEqual(self.last()["timeout"], 3000)
        self.assertEqual(requests.Request("GET", U, params={"a": "b"}).prepare().url, U + "/?a=b")


class SurfaceTests(Base):
    def test_module_surface(self):
        self.assertEqual(requests.__version__, "2.32.3")
        requests.packages.urllib3.disable_warnings()
        requests.packages.urllib3.disable_warnings(requests.packages.urllib3.exceptions.InsecureRequestWarning)
        from requests.packages.urllib3.exceptions import InsecureRequestWarning
        import urllib3

        self.assertIs(InsecureRequestWarning, urllib3.exceptions.InsecureRequestWarning)
        from requests.adapters import HTTPAdapter  # noqa: F401
        from requests.compat import quote, urljoin
        from requests.cookies import cookiejar_from_dict  # noqa: F401
        from requests.exceptions import ChunkedEncodingError, RequestException  # noqa: F401
        from requests.models import PreparedRequest, Request, Response  # noqa: F401
        from requests.sessions import Session  # noqa: F401
        from requests.status_codes import codes  # noqa: F401
        from requests.structures import CaseInsensitiveDict
        from requests.utils import unquote, urlparse

        self.assertEqual(quote("中"), "%E4%B8%AD")
        self.assertEqual(unquote("%E4%B8%AD"), "中")
        self.assertEqual(urljoin(U, "/a"), U + "/a")
        self.assertEqual(urlparse(U).netloc, "site.example")
        self.assertEqual(requests.utils.quote("a b"), "a%20b")
        self.assertEqual(requests.utils.requote_uri("http://x/a b"), "http://x/a%20b")
        self.assertEqual(CaseInsensitiveDict({"A": 1}), {"a": 1})
        self.assertEqual(requests.utils.get_encodings_from_content('<meta charset="gbk">'), ["gbk"])
        with self.assertRaises(AttributeError):
            requests.no_such_thing

    def test_import_is_light(self):
        import subprocess

        code = (
            "import sys, time; sys.dont_write_bytecode = True; sys.path.insert(0, %r); import re, json, base64, urllib.parse\n"
            "before = set(sys.modules); started = time.perf_counter(); import requests\n"
            "print(round(time.perf_counter() - started, 3)); print(' '.join(sorted(set(sys.modules) - before)))"
        ) % sys.path[0]
        out = subprocess.run([sys.executable, "-I", "-c", code], capture_output=True, text=True, check=True).stdout
        loaded = out.splitlines()[1].split()
        for heavy in ("ssl", "socket", "http.client", "http.cookiejar", "email", "urllib.request", "urllib3", "logging",
                      "_idj_dom", "lxml", "asyncio", "concurrent"):
            self.assertNotIn(heavy, loaded)


class Urllib3Tests(Base):
    def test_pool_manager(self):
        import urllib3

        host.on(U + "/a?x=1", {"k": "中"}, headers={"X-Y": ["1", "2"]})
        host.on(U + "/post", handler=lambda r: r["body"])
        http = urllib3.PoolManager(timeout=urllib3.Timeout(connect=2, read=7), cert_reqs="CERT_NONE")
        reply = http.request("GET", U + "/a", fields={"x": "1"}, headers={"H": "v"})
        self.assertEqual((reply.status, reply.json(), reply.headers["x-y"]), (200, {"k": "中"}, "1, 2"))
        self.assertEqual(reply.headers.getlist("X-Y"), ["1", "2"])
        self.assertEqual(json.loads(reply.data.decode()), {"k": "中"})
        self.assertEqual(self.last()["headers"]["H"], "v")
        self.assertEqual((self.last()["timeout"], self.last()["verify"]), (7000, False))
        reply = http.request("POST", U + "/post", body=json.dumps({"a": 1}).encode(), timeout=3.0)
        self.assertEqual((reply.read(), self.last()["timeout"]), (b'{"a": 1}', 3000))
        self.assertIn(b'name="f"', http.request("POST", U + "/post", fields={"f": "v"}).data)
        self.assertEqual(http.request_encode_body("POST", U + "/post", {"f": "v"}, encode_multipart=False).data, b"f=v")
        self.assertEqual(urllib3.request("POST", U + "/post", json={"a": "中"}).data, '{"a":"中"}'.encode())

    def test_redirects_and_errors(self):
        import urllib3

        host.on(U + "/r", status=302, headers={"Location": "/end"})
        host.on(U + "/end", "end")
        http = urllib3.PoolManager()
        self.assertEqual(http.request("GET", U + "/r").data, b"end")
        self.assertEqual(http.request("GET", U + "/r", redirect=False).status, 302)
        host.on(U + "/loop", status=302, headers={"Location": "/loop"})
        with self.assertRaises(urllib3.exceptions.MaxRetryError):
            http.request("GET", U + "/loop")
        host.on(U + "/t", error="timed out")
        with self.assertRaises(urllib3.exceptions.MaxRetryError) as caught:
            http.request("GET", U + "/t")
        self.assertIsInstance(caught.exception.reason, urllib3.exceptions.TimeoutError)
        self.assertEqual(urllib3.util.parse_url("https://a.example:8/x?y").port, 8)
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
        from urllib3.util import Retry
        from urllib3.util.retry import Retry as Same

        self.assertIs(Retry, Same)
        self.assertEqual(Retry(total=5, backoff_factor=0.1).new(total=2).total, 2)


if __name__ == "__main__":
    unittest.main()
