"""Tests of the private helper modules."""

import json
import unittest

import fake_dom
from fake_host import _Adapter, host

import _idj_bridge
import _idj_css
import _idj_http
import _idj_markup
import _idj_text
import _idj_xpath


class BridgeTests(unittest.TestCase):
    def setUp(self):
        host.reset()

    def test_errors(self):
        with self.assertRaises(_idj_bridge.HostError) as caught:
            _idj_bridge.call("no.such.function")
        self.assertEqual(caught.exception.function, "no.such.function")
        self.assertIn("未知的宿主函数", str(caught.exception))
        original, _idj_bridge._native = _idj_bridge._native, None
        try:
            class Broken:
                @staticmethod
                def call(name, args):
                    return "not json"

            _idj_bridge._native = Broken
            with self.assertRaisesRegex(_idj_bridge.HostError, "无效 JSON"):
                _idj_bridge.call("x")
            Broken.call = staticmethod(lambda name, args: "[1]")
            with self.assertRaisesRegex(_idj_bridge.HostError, "无效结果"):
                _idj_bridge.call("x")
        finally:
            _idj_bridge._native = original

    def test_base64(self):
        self.assertEqual(_idj_bridge.b64d(_idj_bridge.b64e(b"\x00\xff")), b"\x00\xff")
        self.assertEqual((_idj_bridge.b64d(None), _idj_bridge.b64d("")), (b"", b""))

    def test_surrogates(self):
        _idj_bridge.call("log", m="x\ud800y 😀")
        self.assertEqual(host.logs, ["x�y 😀"])

    def test_payload_is_json(self):
        _idj_bridge.call("log", m="中\"\\\n")
        self.assertEqual(json.loads(json.dumps(host.calls[-1][1])), {"m": "中\"\\\n"})


class MarkupTests(unittest.TestCase):
    def events(self, markup, **kwargs):
        return list(_idj_markup.events(markup, **kwargs))

    def test_tags(self):
        self.assertEqual(self.events('<A HREF="x>y" b=\'q\' c=u d/>'), [
            ("s", "a", [("href", "x>y"), ("b", "q"), ("c", "u"), ("d", None)], True)])
        self.assertEqual(self.events("<a href=/x/>y</a >"), [
            ("s", "a", [("href", "/x/")], False), ("t", "y"), ("e", "a")])
        self.assertEqual(self.events("<a\n b = '1'\n>"), [("s", "a", [("b", "1")], False)])
        self.assertEqual(self.events('<a t="&quot;&amp;&#20013;">')[0][2], [("t", '"&中')])

    def test_stray_characters(self):
        self.assertEqual(self.events("a < b & c<"), [("t", "a < b & c<")])
        self.assertEqual(self.events("</>x</ y"), [("t", "x</ y")])
        self.assertEqual(self.events('<p class="a"">t'), [("s", "p", [("class", "a"), ('"', None)], False), ("t", "t")])
        self.assertEqual(self.events("<3 x"), [("t", "<3 x")])
        self.assertEqual(self.events("<a b='>x <i>y</i>"), [
            ("s", "a", [("b", ""), ("'", None)], False), ("t", "x "), ("s", "i", [], False), ("t", "y"), ("e", "i")])
        self.assertEqual(self.events("<a b='>' c"), [("s", "a", [("b", ""), ("'", None)], False), ("t", "' c")])
        self.assertEqual(self.events("x <b"), [("t", "x <b")])

    def test_raw_text(self):
        self.assertEqual(self.events("<script>a</b>&amp;</SCRIPT >x"), [
            ("s", "script", [], False), ("r", "a</b>&amp;"), ("e", "script"), ("t", "x")])
        self.assertEqual(self.events("<title>a<b>&amp;</title>")[1], ("t", "a<b>&"))
        self.assertEqual(self.events("<style>never closed"), [("s", "style", [], False), ("r", "never closed")])

    def test_specials(self):
        self.assertEqual(self.events("<!DOCTYPE html [<!ENTITY a 'b>'>]><!--x--><!-->y<![CDATA[z]]><?php a?><!bogus>"), [
            ("d", "DOCTYPE html [<!ENTITY a 'b>'>]"), ("c", "x"), ("c", ""), ("t", "y"), ("x", "z"), ("p", "php a?"),
            ("c", "bogus")])
        self.assertEqual(self.events("<!--open"), [("c", "open")])

    def test_xml(self):
        self.assertEqual(self.events("<Ab:C xY='1'><script>&lt;</script></Ab:C>", xml=True), [
            ("s", "Ab:C", [("xY", "1")], False), ("s", "script", [], False), ("t", "<"), ("e", "script"), ("e", "Ab:C")])

    def test_no_quadratic_blowup(self):
        import time

        started = time.perf_counter()
        for markup in (
            '<a "' * 20000, "<a b='" * 20000, "<" * 50000, "<a " + "b " * 50000, "<!--" * 20000, "<!x " * 20000,
            "<a b='>' " * 20000, '<a b=">" ' * 20000 + "<p>", "</a " * 20000 + ">", "<a b='" * 20000 + ">", "<?x " * 20000,
        ):
            self.events(markup)
            self.events(markup, xml=True)
        self.assertLess(time.perf_counter() - started, 5)

    def test_to_xml(self):
        self.assertEqual(
            _idj_markup.to_xml('<p a="x&quot;" b>1<br>&nbsp;<i></i><!--c--><script>a<b</script></p>'),
            '<p a="x&quot;" b="">1<br/>\xa0<i/><!--c--><script>a&lt;b</script></p>')
        self.assertEqual(_idj_markup.to_xml("<b><i>x</b>"), "<b><i>x</i></b>")

    def test_visible_text(self):
        text = _idj_markup.visible_text
        self.assertEqual(text("<p> a\n <b>b</b>&nbsp;c </p>"), "a b\xa0c")
        self.assertEqual(text("<ul><li>a</li>\n<li>b</li></ul>"), "a\nb")
        self.assertEqual(text("a<br><br>b"), "a\n\nb")
        self.assertEqual(text("<div><br></div>"), "")
        self.assertEqual(text("<p> a </p>", squash=False), "\n a \n")


class CssTests(unittest.TestCase):
    MARKUP = (
        '<div id="r" class="a b"><p class="x">1<i>k</i></p><p lang="zh-CN">2</p><span></span><p data-k="V w">3</p>'
        '<input type="checkbox" checked disabled><h2>t</h2><a href="u">l</a></div><div class="b">z</div>'
    )

    def setUp(self):
        self.doc = fake_dom.parse_html(self.MARKUP)

    def q(self, css, **kwargs):
        found = _idj_css.select(_Adapter(False), [self.doc], css, **kwargs)
        return [n.tag + (":" + n.string() if n.string() else "") for n in found]

    def test_matrix(self):
        for css, want in (
            ("p", ["p:1k", "p:2", "p:3"]), ("P.x", ["p:1k"]), ("#r > p:first-child", ["p:1k"]), ("p:last-of-type", ["p:3"]),
            ("p:nth-child(2)", ["p:2"]), ("p:nth-of-type(odd)", ["p:1k", "p:3"]), ("p:nth-last-of-type(-n+2)", ["p:2", "p:3"]),
            ("p + p", ["p:2"]), ("p ~ p", ["p:2", "p:3"]), ("p ~ span + p", ["p:3"]), ("[lang|=zh]", ["p:2"]),
            ("[data-k~=w]", ["p:3"]), ('[data-k="v W" i]', ["p:3"]), ("[data-k^=V]", ["p:3"]), ("[data-k$=w]", ["p:3"]),
            ("[data-k*='V ']", ["p:3"]), ("p[class!=x]", ["p:2", "p:3"]), ("span:empty", ["span"]),
            ("p:has(> i)", ["p:1k"]), ("p:has(+ span)", ["p:2"]), ("p:not(.x, [lang])", ["p:3"]),
            (":is(h2, a)", ["h2:t", "a:l"]), ("p:contains(2)", ["p:2"]), ("p:contains('k')", ["p:1k"]),
            ("p:-soup-contains-own('k')", []), ("i", ["i:k"]), ("div.a.b i", ["i:k"]), ("div.b", ["div:123tl".replace("123", "1k23"), "div:z"]),
            ("p:eq(1)", ["p:2"]), ("p:eq(-1)", ["p:3"]), ("p:first", ["p:1k"]), ("p:last", ["p:3"]), ("p:gt(0)", ["p:2", "p:3"]),
            ("p:lt(2)", ["p:1k", "p:2"]), ("p:even", ["p:1k", "p:3"]), ("p:odd", ["p:2"]), ("div:eq(0) p:eq(2)", ["p:3"]),
            ("p:gt(0):first", ["p:2"]), ("p:first, h2", ["p:1k", "h2:t"]), (":checked", ["input"]), (":disabled", ["input"]),
            (":header", ["h2:t"]), ("a:link", ["a:l"]), ("div:only-child", []), ("i:only-child", ["i:k"]),
            ("html:root", ["html:1k23tlz"]), ("*|p.x", ["p:1k"]), ("p.x , a", ["p:1k", "a:l"]), ("#r>h2~a", ["a:l"]),
        ):
            self.assertEqual(self.q(css), want, css)

    def test_limit_and_filter(self):
        self.assertEqual(self.q("p", limit=2), ["p:1k", "p:2"])
        adapter = _Adapter(False)
        nodes = _idj_css.select(adapter, [self.doc], "p")
        self.assertEqual(len(_idj_css.filter_nodes(adapter, nodes, ".x, :eq(1)")), 2)
        self.assertEqual(len(_idj_css.filter_nodes(adapter, nodes, "#r > p:gt(0)")), 2)
        self.assertTrue(_idj_css.matches(adapter, nodes[0], "div p.x"))
        self.assertFalse(_idj_css.matches(adapter, nodes[0], "div > div p.x"))

    def test_syntax_errors(self):
        for bad in ("", " ", ">a", "a >", "a[", "a[=x]", ":foo", "a::before", "a,,b", ":eq(x)", "a)", ":not(", "..a", "a#"):
            with self.assertRaises(_idj_css.SelectorSyntaxError, msg=bad):
                _idj_css.parse(bad)
        with self.assertRaisesRegex(NotImplementedError, "位置伪类"):
            self.q("p:not(:eq(1))")


class XPathAnalysisTests(unittest.TestCase):
    def test_types(self):
        for expr, want in (
            ("//a/@href", "nodeset"), ("string(//a)", "string"), ("string(//a)/b", "nodeset"), ("count(//a)", "number"),
            ("count(//a) > 1", "boolean"), ("//a[count(b) > 1]", "nodeset"), ("a | b", "nodeset"), ("(//a)[1]", "nodeset"),
            ("(count(//a))", "number"), ("-1", "number"), ("'x'", "string"), ("3", "number"), ("* * 2", "number"),
            ("div", "nodeset"), ("a-b", "nodeset"), ("a - b", "number"), ("not(a) and b", "boolean"), ("text()", "nodeset"),
            ("self::node()", "nodeset"), ("../@x", "nodeset"), ("re:test(a, 'b')", "boolean"), ("contains(a,'b')", "boolean"),
        ):
            self.assertEqual(_idj_xpath.result_type(_idj_xpath.tokenize(expr)), want, expr)

    def test_rewrite(self):
        self.assertEqual(
            _idj_xpath.rewrite("//n:a[@n:b=$v]/n:*", {"n": "u"}, {"v": "x"}),
            "//*[local-name()='a' and namespace-uri()='u'][@*[local-name()='b' and namespace-uri()='u']='x']/*[namespace-uri()='u']")
        self.assertEqual(_idj_xpath.rewrite("@xml:lang"), "@xml:lang")
        self.assertEqual(_idj_xpath.rewrite("self::n:a", {"n": "u"}), "self::*[local-name()='a' and namespace-uri()='u']")
        self.assertEqual(_idj_xpath.literal("it's"), '"it\'s"')
        self.assertEqual(_idj_xpath.literal("a'\"b"), "concat('a', \"'\", '\"b')")
        self.assertEqual([_idj_xpath.literal(v) for v in (True, 3, 2.5, -1)], ["true()", "3", "2.5", "(-1)"])
        with self.assertRaises(NotImplementedError):
            _idj_xpath.literal([1])


class TextTests(unittest.TestCase):
    def test_detect(self):
        sample = "这是一个没有声明编码的中文页面，播放列表和剧集信息都在这里。"
        for codec, want in (("utf-8", "utf-8"), ("gbk", "gb18030"), ("ascii", "ascii"), ("utf-8-sig", "utf-8-sig"), ("utf-16", "utf-16")):
            data = ("plain" if codec == "ascii" else sample).encode(codec)
            self.assertEqual(_idj_text.detect(data)[0], want)
        self.assertEqual(_idj_text.detect("這是一個沒有聲明編碼的中文頁面，播放列表和劇集資訊都在這裡。".encode("big5"))[0], "big5")
        self.assertEqual(_idj_text.detect(sample.encode()[:-1])[0], "utf-8")  # cut inside a character
        self.assertEqual(_idj_text.detect(b"\xff" + sample.encode())[0], "utf-8")  # one damaged byte
        self.assertEqual(_idj_text.detect(b""), (None, 0.0))

    def test_sniff(self):
        page = '<meta http-equiv="Content-Type" content="text/html; charset=%s"><p>中文</p>'
        self.assertEqual(_idj_text.sniff((page % "gb2312").encode("gbk")), "gb18030")
        self.assertEqual(_idj_text.sniff((page % "gbk").encode("utf-8")), "utf-8")  # wrong declaration
        self.assertEqual(_idj_text.sniff((page % "utf-8").encode("gbk")), "gb18030")
        self.assertEqual(_idj_text.sniff((page % "iso-8859-1").encode("utf-8")), "utf-8")
        self.assertEqual(_idj_text.sniff('<?xml version="1.0" encoding="big5"?><a>中文</a>'.encode("big5")), "big5")
        self.assertEqual(_idj_text.sniff(b"plain"), "utf-8")

    def test_decode(self):
        self.assertEqual(_idj_text.decode("囧".encode("gbk"), "GB2312"), "囧")
        with self.assertRaises(LookupError):
            _idj_text.decode(b"x", "nope")
        self.assertEqual(_idj_text.decode_markup("中".encode("gbk"), "gbk"), ("中", "gb18030"))
        self.assertEqual(_idj_text._host_gbk("中文".encode("gbk")), "中文")


class HttpTests(unittest.TestCase):
    def test_split_set_cookie(self):
        split = _idj_http.split_set_cookie
        self.assertEqual(split("a=1"), ["a=1"])
        self.assertEqual(split("a=1; Expires=Wed, 21 Oct 2099 07:28:00 GMT, b=2"), [
            "a=1; Expires=Wed, 21 Oct 2099 07:28:00 GMT", "b=2"])
        self.assertEqual(split("a=x,y; path=/, __c-d.e=f"), ["a=x,y; path=/", "__c-d.e=f"])

    def test_errors(self):
        for text in ("请求超时", "timed out", "The request timed out.", "timeout", "Time-out"):
            self.assertTrue(_idj_http.is_timeout(text), text)
        self.assertFalse(_idj_http.is_timeout("无法连接"))
        self.assertTrue(_idj_http.is_tls("证书无效"))


if __name__ == "__main__":
    unittest.main()
