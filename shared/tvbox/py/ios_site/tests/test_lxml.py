import copy
import io
import os
import tempfile
import unittest

from fake_host import host

import requests
from lxml import etree, html
from lxml.cssselect import CSSSelector

PAGE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>影视 &amp; 剧集</title></head>
<body>
<div id="nav" class="nav top"><a href="/">首页</a><a href="/vod/1.html" title="电影">电影</a></div>
<ul class="list">
  <li class="item"><a href="/d/1.html" title="片一"><img data-src="//i.example/1.jpg"></a><span>更新至<b>10</b>集</span> 尾巴</li>
  <li class="item on"><a href="/d/2.html" title="片二"><img data-src="//i.example/2.jpg"></a><span>完结</span></li>
  <li class="item"><a href="/d/3.html" title="片三"></a></li>
</ul>
<!-- 注释 -->
<script>var player={"url":"a<b&c"};</script>
</body></html>"""


class Base(unittest.TestCase):
    def setUp(self):
        host.reset()


class XPathTests(Base):
    def setUp(self):
        super().setUp()
        self.root = etree.HTML(PAGE)

    def test_root(self):
        self.assertEqual(self.root.tag, "html")
        self.assertIsNone(self.root.getparent())
        self.assertIsInstance(self.root, etree._Element)

    def test_attribute_and_text_lists(self):
        self.assertEqual(self.root.xpath("//a/@href"), ["/", "/vod/1.html", "/d/1.html", "/d/2.html", "/d/3.html"])
        self.assertEqual(self.root.xpath('//li[@class="item"]/a/@title'), ["片一", "片三"])
        self.assertEqual(self.root.xpath("//title/text()")[0], "影视 & 剧集")
        self.assertEqual(self.root.xpath('//div[@id="nav"]//text()'), ["首页", "电影"])
        self.assertEqual("".join(self.root.xpath("//li[1]/span//text()")), "更新至10集")
        self.assertEqual(self.root.xpath("//nothing"), [])
        result = self.root.xpath("//a/@href")[0]
        self.assertIsInstance(result, str)
        self.assertIsInstance(result, etree._ElementUnicodeResult)

    def test_scalars(self):
        self.assertEqual(self.root.xpath("count(//li)"), 3.0)
        self.assertIsInstance(self.root.xpath("count(//li)"), float)
        self.assertIs(self.root.xpath("boolean(//li)"), True)
        self.assertIs(self.root.xpath("count(//li) > 5"), False)
        self.assertEqual(self.root.xpath("string(//li[2]/a/@title)"), "片二")
        self.assertEqual(self.root.xpath("string(//nothing)"), "")
        self.assertEqual(self.root.xpath("normalize-space(//li[1])"), "更新至10集 尾巴")
        self.assertEqual(self.root.xpath("1 + 2 * 3"), 7.0)
        self.assertEqual(self.root.xpath('concat("a", "b")'), "ab")
        self.assertTrue(self.root.xpath("number('x')") != self.root.xpath("number('x')"))

    def test_spider_loop(self):
        videos = []
        for li in self.root.xpath('//ul[@class="list"]/li[contains(@class,"item")]'):
            name = li.xpath("./a/@title")[0]
            link = li.xpath(".//a/@href")[0].split("/")[-1]
            pic = li.xpath(".//img/@data-src")
            videos.append((name, link, "https:" + pic[0] if pic else "", li.xpath("string(span)").strip()))
        self.assertEqual(videos, [
            ("片一", "1.html", "https://i.example/1.jpg", "更新至10集"), ("片二", "2.html", "https://i.example/2.jpg", "完结"),
            ("片三", "3.html", "", "")])

    def test_relative_and_absolute(self):
        li = self.root.xpath("//li[2]")[0]
        self.assertEqual(li.xpath("a/@title"), ["片二"])
        self.assertEqual(len(li.xpath("//li")), 3)
        self.assertEqual(li.xpath("../@class"), ["list"])
        self.assertEqual(li.xpath("following-sibling::li[1]/a/@title"), ["片三"])
        self.assertEqual(li.xpath("preceding-sibling::li/a/@title | following-sibling::li/a/@title"), ["片一", "片三"])
        self.assertEqual(self.root.xpath("(//li)[last()]/a/@title"), ["片三"])
        self.assertEqual(self.root.xpath('//a[text()="电影"]/@href'), ["/vod/1.html"])
        self.assertEqual(self.root.xpath("/html/body/ul/li[position()<3]/a/@title"), ["片一", "片二"])
        self.assertEqual(self.root.xpath('//script[contains(text(),"player")]/text()')[0], 'var player={"url":"a<b&c"};')

    def test_smart_strings(self):
        href = self.root.xpath("//a/@href")[2]
        self.assertTrue(href.is_attribute)
        self.assertEqual(href.attrname, "href")
        self.assertEqual(href.getparent().get("title"), "片一")
        text = self.root.xpath("//li[1]/span/b/text()")[0]
        self.assertEqual(text.getparent().tag, "b")
        self.assertTrue(text.is_text)
        self.assertIs(type(copy.deepcopy(text)), str)
        tail = self.root.xpath("//li[1]/span/text()")[1]
        self.assertEqual(tail, "集")
        self.assertEqual(tail.getparent().tag, "span")  # text() parent in the tree

    def test_variables_and_namespaces(self):
        self.assertEqual(self.root.xpath("//a[@title=$t]/@href", t="片二"), ["/d/2.html"])
        self.assertEqual(self.root.xpath("//li[$n]/a/@title", n=3), ["片三"])
        self.assertEqual(self.root.xpath("//a[@title=$t]", t="it's \"x\""), [])
        with self.assertRaisesRegex(etree.XPathEvalError, "Undefined variable"):
            self.root.xpath("//a[@title=$t]")
        with self.assertRaisesRegex(etree.XPathEvalError, "Undefined namespace prefix"):
            self.root.xpath("//x:a")

    def test_errors(self):
        for bad in ("//a[", "", "//a[unknown()]", "///"):
            with self.assertRaises(etree.XPathEvalError):
                self.root.xpath(bad)
        self.assertTrue(issubclass(etree.XPathEvalError, etree.XPathError))
        with self.assertRaises(NotImplementedError):
            self.root.xpath("//a", extensions={("ns", "f"): None})

    def test_compiled(self):
        find = etree.XPath("//li[@class=$c]/a/@title")
        self.assertEqual(find(self.root, c="item on"), ["片二"])
        self.assertEqual(etree.XPath("count(//li)")(self.root), 3.0)
        self.assertEqual(find.path, "//li[@class=$c]/a/@title")
        self.assertEqual(etree.XPathEvaluator(self.root)("//li[1]/a/@title"), ["片一"])

    def test_exslt_regex(self):
        ns = {"re": "http://exslt.org/regular-expressions"}
        self.assertEqual(self.root.xpath(r'//a[re:test(@href, "^/d/\d+\.html$")]/@title', namespaces=ns), ["片一", "片二", "片三"])
        self.assertEqual(len(self.root.xpath('//li[re:test(@class, "ON$", "i")]', namespaces=ns)), 1)
        self.assertEqual(self.root.xpath('//a[re:match(@href, "vod")]/text()', namespaces=ns), ["电影"])
        self.assertEqual(
            self.root.xpath('//li[contains(@class,"item") and not(re:test(@class, "on"))]/a/@title', namespaces=ns), ["片一", "片三"])
        self.assertEqual(self.root.xpath('//li[a[re:test(@title, "二")]]/span/text()', namespaces=ns), ["完结"])
        self.assertEqual(self.root.xpath('//a/@href[re:test(., "/d/")]', namespaces=ns), ["/d/1.html", "/d/2.html", "/d/3.html"])
        self.assertEqual(self.root.xpath('//li[re:test(string(.), "完结")][a]/a/@title', namespaces=ns), ["片二"])
        self.assertIs(self.root.xpath('re:test(string(//title), "影视")', namespaces=ns), True)
        self.assertEqual(self.root.xpath('re:replace(string(//title), "[^影]", "g", "")', namespaces=ns), "影")
        self.assertEqual(
            self.root.xpath('//li[re:test(@class, "item")]//a[re:test(@href, "[13]")]/@title', namespaces=ns), ["片一", "片三"])
        self.assertEqual(len(self.root.xpath('//li[re:test(@class, "on")] | //a[re:test(@href, "vod")]', namespaces=ns)), 2)
        for unsupported in (
            '//li[re:test(@class, "item")][1]', 'count(//li[re:test(@class, "item")])', 're:match(string(//title), "影")',
        ):
            with self.assertRaisesRegex(NotImplementedError, "EXSLT"):
                self.root.xpath(unsupported, namespaces=ns)

    def test_calls_are_direct(self):
        host.calls.clear()
        self.root.xpath("//a/@href")
        self.assertEqual(host.names(), ["html.xpath"])


class ElementTests(Base):
    def setUp(self):
        super().setUp()
        self.root = etree.HTML(PAGE)
        self.ul = self.root.xpath("//ul")[0]

    def test_text_tail_attrib(self):
        li = self.ul[0]
        span = li.find("span")
        self.assertEqual((span.text, span.tail), ("更新至", " 尾巴"))
        self.assertEqual((span.find("b").text, span.find("b").tail), ("10", "集"))
        self.assertIsNone(li.find("a").text)
        link = li.find("a")
        self.assertEqual((link.get("href"), link.get("nope"), link.get("nope", "d")), ("/d/1.html", None, "d"))
        self.assertEqual(dict(link.attrib), {"href": "/d/1.html", "title": "片一"})
        self.assertEqual((link.keys(), link.values()), (["href", "title"], ["/d/1.html", "片一"]))
        self.assertEqual(link.attrib["title"], "片一")
        self.assertIn("href", link.attrib)
        with self.assertRaises(KeyError):
            link.attrib["nope"]
        self.assertEqual(link.attrib.get("nope", 1), 1)
        self.assertEqual(sorted(k for k in link.attrib), ["href", "title"])

    def test_attribute_editing(self):
        link = self.ul[0].find("a")
        link.set("href", "/new")
        link.attrib["data-x"] = "1"
        self.assertEqual(self.ul.xpath("./li[1]/a/@href"), ["/new"])
        self.assertEqual(self.ul[0].find("a").get("data-x"), "1")
        del link.attrib["title"]
        self.assertNotIn("title", link.attrib)
        self.assertEqual(link.attrib.pop("data-x"), "1")
        with self.assertRaises(KeyError):
            del link.attrib["title"]

    def test_children(self):
        self.assertEqual(len(self.ul), 3)
        self.assertTrue(self.ul)
        self.assertFalse(self.ul[2].find("a"))  # childless elements are false in lxml
        self.assertEqual([c.get("class") for c in self.ul], ["item", "item on", "item"])
        self.assertEqual(self.ul[-1].find("a").get("title"), "片三")
        self.assertEqual(len(self.ul[0:2]), 2)
        self.assertEqual(self.ul.index(self.ul[1]), 1)
        self.assertIn(self.ul[0], self.ul)
        self.assertEqual(self.ul.getchildren(), list(self.ul))
        self.assertEqual([e.tag for e in self.ul[0].iterchildren("span")], ["span"])
        self.assertEqual([e.tag for e in self.ul[0].iterchildren(reversed=True)], ["span", "a"])
        with self.assertRaises(ValueError):
            self.ul.index(self.root)

    def test_relatives(self):
        second = self.ul[1]
        self.assertEqual(second.getparent(), self.ul)
        self.assertEqual(second.getprevious(), self.ul[0])
        self.assertEqual(second.getnext(), self.ul[2])
        self.assertIsNone(self.ul[2].getnext())
        self.assertEqual([e.tag for e in second.iterancestors()], ["ul", "body", "html"])
        self.assertEqual([e.tag for e in second.iterancestors("body", "html")], ["body", "html"])
        self.assertEqual(list(second.itersiblings()), [self.ul[2]])
        self.assertEqual(list(self.ul[2].itersiblings(preceding=True)), [self.ul[1], self.ul[0]])
        self.assertEqual(second.getroottree().getroot(), self.root)
        self.assertEqual(len({second, self.ul[1]}), 1)
        self.assertEqual(second.getroottree().getpath(second), "/html/body/ul/li[2]")

    def test_iteration(self):
        self.assertEqual([e.tag for e in self.ul[0].iter()], ["li", "a", "img", "span", "b"])
        self.assertEqual([e.tag for e in self.ul[0].iterdescendants()], ["a", "img", "span", "b"])
        self.assertEqual([e.tag for e in self.ul[0].iter("img", "b")], ["img", "b"])
        self.assertEqual(len(list(self.root.iter("li"))), 3)
        self.assertEqual("".join(self.ul[1].itertext()), "完结")
        self.assertEqual(list(self.ul[0].find("span").itertext()), ["更新至", "10", "集"])
        comments = list(self.root.iter(etree.Comment))
        self.assertEqual((comments[0].text, comments[0].tag), (" 注释 ", etree.Comment))

    def test_find(self):
        self.assertEqual(self.root.find(".//ul/li").get("class"), "item")
        self.assertEqual(len(self.root.findall(".//li")), 3)
        self.assertEqual(self.root.find(".//li[@class='item on']/a").get("title"), "片二")
        self.assertEqual(self.root.findtext(".//title"), "影视 & 剧集")
        self.assertIsNone(self.root.findtext(".//nope"))
        self.assertEqual(self.root.findtext(".//li/a", "d"), "")
        self.assertIsNone(self.root.find("nope"))
        self.assertEqual(self.ul.find("li[2]/span").text, "完结")
        self.assertEqual(self.root.getroottree().find("//li").get("class"), "item")

    def test_cssselect(self):
        self.assertEqual([e.get("title") for e in self.root.cssselect("li.item > a")], ["片一", "片二", "片三"])
        self.assertEqual(self.ul.cssselect("ul"), [self.ul])
        self.assertEqual(CSSSelector("li.on a")(self.root)[0].get("title"), "片二")
        host.select_includes_self = True
        self.assertEqual(self.ul.cssselect("ul"), [self.ul])
        from lxml.cssselect import SelectorSyntaxError

        with self.assertRaises(SelectorSyntaxError):
            self.root.cssselect("li[")

    def test_remove(self):
        span = self.ul[0].find("span")
        self.ul[0].remove(span)
        self.assertEqual("".join(self.ul[0].itertext()), "")  # lxml drops the tail with the element
        self.assertEqual([a.get("tail") for n, a in host.calls if n == "html.remove"], [True])
        with self.assertRaises(ValueError):
            self.ul.remove(self.root)
        for script in self.root.xpath("//script"):
            script.getparent().remove(script)
        self.assertEqual(self.root.xpath("//script"), [])

    def test_text_editing(self):
        bold = self.root.xpath("//b")[0]
        bold.text = "11"
        self.assertEqual(self.ul[0].xpath("string(span)"), "更新至11集")
        with self.assertRaisesRegex(NotImplementedError, "element.text"):
            self.ul.text = "x"
        with self.assertRaisesRegex(NotImplementedError, "append"):
            self.ul.append(bold)
        with self.assertRaisesRegex(NotImplementedError, "tail"):
            bold.tail = "x"
        with self.assertRaises(NotImplementedError):
            bold.tag = "i"

    def test_strip(self):
        etree.strip_tags(self.ul[0].find("span"), "b")
        self.assertEqual(self.ul[0].find("span").text, "更新至10集")
        with self.assertRaisesRegex(NotImplementedError, "strip_tags"):
            etree.strip_tags(self.root, "a")
        etree.strip_tags(self.root, etree.Comment)
        self.assertEqual(list(self.root.iter(etree.Comment)), [])
        etree.strip_elements(self.root, "script", "li")
        self.assertEqual(self.root.xpath("//li | //script"), [])
        etree.strip_attributes(self.root, "class")
        self.assertEqual(self.root.xpath("//@class"), [])

    def test_deepcopy(self):
        twin = copy.deepcopy(self.ul[1])
        twin.set("class", "changed")
        self.assertEqual((twin.tag, twin.find("a").get("title")), ("li", "片二"))
        self.assertEqual(self.ul[1].get("class"), "item on")
        self.assertNotEqual(twin, self.ul[1])

    def test_info_is_cached(self):
        link = self.ul[0].find("a")
        host.calls.clear()
        link.tag, link.get("href"), link.text, link.attrib["title"]
        self.assertEqual(host.names(), ["html.info"])


class SerialiseTests(Base):
    def test_tostring(self):
        root = etree.HTML('<div class="a&amp;b">一<br>&lt;二&gt;<img src="x"><p></p></div>尾')
        div = root.xpath("//div")[0]
        inner = '<div class="a&amp;b">一<br/>&lt;二&gt;<img src="x"/><p/></div>尾'
        self.assertEqual(etree.tostring(div, encoding="unicode"), inner)
        self.assertEqual(etree.tostring(div, encoding=str), inner)
        self.assertEqual(etree.tostring(div, encoding="utf-8"), inner.encode())
        self.assertEqual(etree.tostring(div, encoding="utf-8").decode(), inner)
        self.assertIn(b"&#19968;", etree.tostring(div))
        self.assertTrue(etree.tostring(div, with_tail=False).endswith(b"</div>"))
        self.assertEqual(
            etree.tostring(div, encoding="unicode", method="html", with_tail=False),
            '<div class="a&amp;b">一<br>&lt;二&gt;<img src="x"><p></p></div>')
        self.assertEqual(etree.tostring(div, method="text", encoding="unicode"), "一<二>尾")
        self.assertTrue(etree.tostring(div, encoding="unicode", pretty_print=True, with_tail=False).endswith("</div>\n"))
        self.assertTrue(etree.tostring(root, encoding="gbk").startswith(b"<?xml version='1.0' encoding='gbk'?>"))
        self.assertTrue(etree.tostring(root.getroottree(), encoding="unicode").startswith("<html><body><div"))
        with self.assertRaises(TypeError):
            etree.tostring("text")
        with self.assertRaisesRegex(NotImplementedError, "c14n"):
            etree.tostring(div, method="c14n")

    def test_script_round_trip(self):
        root = etree.HTML("<script>if(a<b && c){}</script>")
        script = root.xpath("//script")[0]
        self.assertEqual(etree.tostring(script, encoding="unicode"), "<script>if(a&lt;b &amp;&amp; c){}</script>")
        self.assertEqual(etree.tostring(script, encoding="unicode", method="html"), "<script>if(a<b && c){}</script>")

    def test_new_trees(self):
        root = etree.Element("i", version="1")
        child = etree.SubElement(root, "d", p="1,2,3")
        child.text = "弹幕<&>"
        etree.SubElement(root, "e")
        self.assertEqual(
            etree.tostring(root, encoding="unicode"), '<i version="1"><d p="1,2,3">弹幕&lt;&amp;&gt;</d><e/></i>')
        self.assertTrue(etree.tostring(root, encoding="utf-8", xml_declaration=True).startswith(b"<?xml"))
        self.assertTrue(etree.iselement(root))
        with self.assertRaises(NotImplementedError):
            etree.SubElement(etree.HTML("<p>x</p>"), "a")


class ParserTests(Base):
    def test_bytes(self):
        page = '<html><head><meta charset="gbk"></head><body><p>中文</p></body></html>'
        self.assertEqual(etree.HTML(page.encode("gbk")).xpath("//p/text()"), ["中文"])
        self.assertEqual(etree.HTML("<p>中文</p>".encode()).xpath("//p/text()"), ["中文"])
        self.assertEqual(etree.HTML("<p>中文</p>".encode("gbk"), etree.HTMLParser(encoding="gbk")).xpath("//p/text()"), ["中文"])
        self.assertEqual(etree.HTML("﻿<p>中</p>").xpath("//p/text()"), ["中"])

    def test_from_response(self):
        host.on("https://s.example/", PAGE, headers={"Content-Type": "text/html; charset=utf-8"})
        reply = requests.get("https://s.example/")
        self.assertEqual(etree.HTML(reply.text).xpath("//li[2]/a/@title"), ["片二"])
        self.assertEqual(etree.HTML(reply.content).xpath("//li[2]/a/@title"), ["片二"])
        self.assertEqual(etree.HTML(reply.content.decode("utf-8")).xpath("//li[2]/a/@title"), ["片二"])

    def test_declaration_and_empty(self):
        self.assertEqual(etree.HTML('<?xml version="1.0" encoding="utf-8"?><html><body><p>x</p></body></html>').xpath("//p/text()"), ["x"])
        for empty in ("", "  "):
            with self.assertRaises(etree.XMLSyntaxError):
                etree.HTML(empty)
            with self.assertRaises(etree.ParserError):
                html.fromstring(empty)
        with self.assertRaises(ValueError):
            etree.HTML(None)

    def test_surrogates_and_nul(self):
        self.assertEqual(etree.HTML("<p>a\ud800b\x00c</p>").xpath("string(//p)"), "a�bc")

    def test_xml(self):
        root = etree.XML('<rss><item><title>A</title><link>http://x</link></item><item><title>B</title></item></rss>')
        self.assertEqual(root.xpath("//item/title/text()"), ["A", "B"])
        self.assertEqual(root.findtext("item/link"), "http://x")
        self.assertEqual(etree.tostring(root.find("item"), encoding="unicode"),
                         "<item><title>A</title><link>http://x</link></item>")
        self.assertEqual(etree.fromstring(b'<?xml version="1.0" encoding="gbk"?><a>\xd6\xd0</a>').text, "中")
        with self.assertRaises(etree.XMLSyntaxError):
            etree.fromstring("<a><b></a>")
        with self.assertRaises(SyntaxError):
            etree.XML("<p>&nbsp;</p>")
        self.assertEqual(etree.fromstring("<a><b>x</b>", etree.XMLParser(recover=True)).find("b").text, "x")
        self.assertEqual(etree.fromstring("<p>x", etree.HTMLParser()).tag, "html")

    def test_namespaces(self):
        root = etree.fromstring('<f xmlns="urn:d" xmlns:m="urn:m"><e><m:c url="u"/></e></f>')
        ns = {"d": "urn:d", "m": "urn:m"}
        self.assertEqual(root.xpath("//m:c/@url", namespaces=ns), ["u"])
        self.assertEqual(root.xpath("/d:f/d:e/m:*", namespaces=ns)[0].get("url"), "u")
        self.assertEqual(root.find("{urn:d}e/{urn:m}c").get("url"), "u")
        self.assertEqual(root.find("d:e", ns).tag, "{urn:d}e")
        self.assertEqual(etree.QName(root).localname, "f")
        self.assertEqual([e.tag for e in root.iter("{urn:m}c")], ["{urn:m}c"])

    def test_parse(self):
        tree = etree.parse(io.StringIO("<a><b>x</b></a>"))
        self.assertEqual(tree.getroot().find("b").text, "x")
        self.assertEqual(tree.xpath("/a/b/text()"), ["x"])
        tree = etree.parse(io.BytesIO(PAGE.encode()), etree.HTMLParser(encoding="utf-8"))
        self.assertEqual(tree.xpath("//li[1]/a/@title"), ["片一"])
        self.assertEqual(len(tree.findall("//li")), 3)
        handle, path = tempfile.mkstemp(suffix=".html")
        os.write(handle, PAGE.encode())
        os.close(handle)
        try:
            self.assertEqual(etree.parse(path, etree.HTMLParser()).xpath("//li[1]/a/@title"), ["片一"])
        finally:
            os.unlink(path)
        with self.assertRaises(OSError):
            etree.parse("no-such-file.xml")


class HtmlModuleTests(Base):
    def test_fromstring(self):
        self.assertEqual(html.fromstring(PAGE).tag, "html")
        self.assertEqual(html.fromstring('<div id="x"><p>a</p></div>').get("id"), "x")
        self.assertEqual(html.fromstring("<p>a</p><p>b</p>").tag, "div")
        self.assertEqual(len(html.fromstring("<p>a</p><p>b</p>")), 2)
        self.assertEqual(html.fromstring("<a>a</a><b>b</b>").tag, "span")
        self.assertEqual(html.document_fromstring("<p>a</p>").tag, "html")
        self.assertIsInstance(html.fromstring("<p>a</p>"), html.HtmlElement)
        self.assertIsInstance(html.fromstring(PAGE).xpath("//li")[0], html.HtmlElement)

    def test_fragments(self):
        self.assertEqual(html.fragment_fromstring("<p>a</p>").text, "a")
        parts = html.fragments_fromstring("lead<p>a</p><p>b</p>")
        self.assertEqual((parts[0], parts[1].text, parts[2].text), ("lead", "a", "b"))
        self.assertEqual(html.fragment_fromstring("a<b>c</b>", create_parent="p").tag, "p")
        with self.assertRaisesRegex(etree.ParserError, "Multiple elements"):
            html.fragment_fromstring("<p>a</p><p>b</p>")

    def test_methods(self):
        root = html.fromstring(PAGE)
        self.assertEqual(root.xpath("//li")[0].text_content().strip(), "更新至10集 尾巴")
        self.assertEqual(root.cssselect("li.on")[0].find_class("on")[0].tag, "li")
        self.assertEqual(root.get_element_by_id("nav").tag, "div")
        with self.assertRaises(KeyError):
            root.get_element_by_id("nope")
        self.assertEqual((root.body.tag, root.head.tag), ("body", "head"))
        nav = root.get_element_by_id("nav")
        self.assertIn("top", nav.classes)
        nav.classes.add("new")
        nav.classes.discard("top")
        self.assertEqual(nav.get("class"), "nav new")
        root.make_links_absolute("https://s.example/dir/")
        self.assertEqual(root.xpath("//li[1]/a/@href"), ["https://s.example/d/1.html"])
        self.assertIn("https://s.example/vod/1.html", [link for _, _, link, _ in root.iterlinks()])
        span = root.xpath("//li[1]/span")[0]
        span.drop_tree()
        self.assertEqual(root.xpath("//li[1]")[0].text_content().strip(), "尾巴")  # tail stays
        bold = html.fromstring("<p>a<b>b</b>c</p>")
        bold.find("b").drop_tag()
        self.assertEqual(html.tostring(bold, encoding="unicode"), "<p>abc</p>")

    def test_tostring(self):
        element = html.fromstring("<p>中<br>x</p>")
        self.assertEqual(html.tostring(element, encoding="unicode"), "<p>中<br>x</p>")
        self.assertEqual(html.tostring(element, encoding="utf-8").decode(), "<p>中<br>x</p>")
        self.assertEqual(html.tostring(element), b"<p>&#20013;<br>x</p>")


if __name__ == "__main__":
    unittest.main()
