import copy
import io
import re
import unittest

from fake_host import host
from test_lxml import PAGE

import bs4
from bs4 import BeautifulSoup, Comment, NavigableString, Tag


class Base(unittest.TestCase):
    features = "html.parser"

    def setUp(self):
        host.reset()
        self.soup = BeautifulSoup(PAGE, self.features)


class SearchTests(Base):
    def test_spider_loop(self):
        videos = []
        for li in self.soup.find("ul", class_="list").find_all("li", class_="item"):
            link = li.find("a")
            image = li.find("img")
            videos.append((link["title"], link.get("href"), image["data-src"] if image else "", li.span.get_text() if li.span else ""))
        self.assertEqual(videos, [
            ("片一", "/d/1.html", "//i.example/1.jpg", "更新至10集"), ("片二", "/d/2.html", "//i.example/2.jpg", "完结"),
            ("片三", "/d/3.html", "", "")])

    def test_names(self):
        soup = self.soup
        self.assertEqual(soup.title.string, "影视 & 剧集")
        self.assertEqual(soup.ul.li.a["title"], "片一")
        self.assertIsNone(soup.nope)
        self.assertEqual([t.name for t in soup.find_all(["b", "title"])], ["title", "b"])
        self.assertEqual({t.name for t in soup.find_all(re.compile("^s"))}, {"span", "script"})
        self.assertEqual(len(soup.find_all(True)), len(soup.find_all()))
        self.assertEqual([t.name for t in soup.find_all(lambda t: t.has_attr("data-src"))], ["img", "img"])
        self.assertEqual(len(soup("li")), 3)
        self.assertEqual(len(soup.findAll("li", limit=2)), 2)
        self.assertEqual(soup.find("body").find_all("li", recursive=False), [])
        self.assertEqual(len(soup.ul.find_all("li", recursive=False)), 3)

    def test_attributes(self):
        soup = self.soup
        self.assertEqual(soup.find(id="nav").name, "div")
        self.assertEqual(soup.find("div", {"class": "top"})["id"], "nav")
        self.assertEqual(soup.find("div", "nav")["id"], "nav")
        self.assertEqual(soup.find(class_="nav top")["id"], "nav")
        self.assertIsNone(soup.find(class_="top nav"))
        self.assertEqual(len(soup.find_all(class_=["on", "top"])), 2)
        self.assertEqual(len(soup.find_all(class_=re.compile("^it"))), 3)
        self.assertEqual(len(soup.find_all("li", class_=lambda c: c == "on")), 1)
        self.assertEqual(len(soup.find_all("li", class_=lambda c: c == "item on")), 1)  # also sees the whole value
        self.assertEqual(len(soup.find_all("div", class_=None)), 0)
        self.assertEqual(len(soup.find_all("a", class_=None)), 5)
        self.assertEqual(len(soup.find_all("a", href=True)), 5)
        self.assertEqual(len(soup.find_all("a", href=re.compile(r"^/d/"))), 3)
        self.assertEqual(len(soup.find_all("a", title=None)), 1)
        self.assertEqual(len(soup.find_all(attrs={"data-src": True})), 2)
        self.assertEqual(soup.find("a", {"href": "/d/2.html", "title": "片二"}).parent["class"], ["item", "on"])
        self.assertEqual(soup.find("a", title=lambda t: t and "三" in t)["href"], "/d/3.html")

    def test_strings(self):
        soup = self.soup
        self.assertEqual(soup.find("a", string="电影")["href"], "/vod/1.html")
        self.assertEqual(soup.find("a", text=re.compile("首"))["href"], "/")
        found = soup.find(string=re.compile("完"))
        self.assertIsInstance(found, NavigableString)
        self.assertEqual((found, found.parent.name), ("完结", "span"))
        self.assertEqual(soup.find_all(string=["首页", "电影"]), ["首页", "电影"])
        comment = soup.find(string=lambda s: isinstance(s, Comment))
        self.assertEqual((comment, str(type(comment).__name__)), (" 注释 ", "Comment"))

    def test_result_set_error(self):
        with self.assertRaisesRegex(AttributeError, "treating a list of elements like a single element"):
            self.soup.find_all("a").text

    def test_strainer(self):
        from bs4 import SoupStrainer

        self.assertEqual(len(self.soup.find_all(SoupStrainer("a", href=re.compile("^/d")))), 3)
        only = BeautifulSoup(PAGE, "html.parser", parse_only=SoupStrainer("li"))
        self.assertEqual([c.name for c in only.contents], ["li"] * 3)
        self.assertEqual(len(only.find_all("a")), 3)

    def test_css(self):
        soup = self.soup
        self.assertEqual([a["title"] for a in soup.select("ul.list > li a")], ["片一", "片二", "片三"])
        self.assertEqual(soup.select_one("li:nth-of-type(2) a")["href"], "/d/2.html")
        self.assertIsNone(soup.select_one("li.nope"))
        self.assertEqual(len(soup.select('a[href^="/d/"]')), 3)
        self.assertEqual(len(soup.select("a[href*=d][title]")), 4)
        self.assertEqual(len(soup.select("#nav a, li a")), 5)
        self.assertEqual(soup.select("li.on + li a")[0]["title"], "片三")
        self.assertEqual(len(soup.select("li.item ~ li")), 2)
        self.assertEqual(soup.select('span:-soup-contains("完结")')[0].parent["class"], ["item", "on"])
        self.assertEqual(len(soup.select("li:has(> a > img)")), 2)
        self.assertEqual(len(soup.select("li:not(.on)", limit=1)), 1)
        self.assertEqual(soup.ul.select("li")[2].a["title"], "片三")
        self.assertEqual(len(soup.select("body li")), 3)
        self.assertEqual(soup.ul.css.select_one("li.on").a["title"], "片二")
        self.assertTrue(soup.ul.css.match("body > ul"))
        self.assertEqual(soup.find("b").css.closest("li").a["title"], "片一")
        self.assertEqual(soup.select("html")[0].name, "html")
        self.assertEqual(len(soup.select(":root")), 1)
        self.assertEqual(len(soup.select("* > html")), 0)
        with self.assertRaises(bs4.SelectorSyntaxError):
            soup.select("li[")


class TreeTests(Base):
    def test_attribute_access(self):
        li = self.soup.find_all("li")[1]
        self.assertEqual((li["class"], li.get("class"), li.attrs), (["item", "on"], ["item", "on"], {"class": ["item", "on"]}))
        self.assertEqual(li.get("id", "d"), "d")
        self.assertTrue(li.has_attr("class"))
        with self.assertRaises(KeyError):
            li["id"]
        self.assertEqual(li.get_attribute_list("class"), ["item", "on"])
        li["id"] = "x"
        li["class"].append("z")
        del li["nope"]
        self.assertEqual(self.soup.select_one("#x.z"), li)

    def test_text(self):
        li = self.soup.li
        self.assertEqual(li.get_text(strip=True), "更新至10集尾巴")
        self.assertEqual(li.get_text("|", strip=True), "更新至|10|集|尾巴")
        self.assertEqual(li.span.text, "更新至10集")
        self.assertIsNone(li.span.string)
        self.assertEqual(li.b.string, "10")
        self.assertEqual(list(li.stripped_strings), ["更新至", "10", "集", "尾巴"])
        self.assertEqual("".join(li.span.strings), "更新至10集")
        self.assertNotIn("player", self.soup.get_text())
        self.assertNotIn("注释", self.soup.get_text())
        self.assertIn("player", self.soup.script.string)
        self.assertEqual(self.soup.script.get_text(), 'var player={"url":"a<b&c"};')
        self.assertEqual([c.text for c in self.soup.body.contents if isinstance(c, Comment)], [""])

    def test_navigation(self):
        first, second, third = self.soup.find_all("li")
        self.assertEqual(second.parent.name, "ul")
        self.assertEqual([p.name for p in second.parents], ["ul", "body", "html", "[document]"])
        self.assertIs(second.find_next_sibling("li"), third)
        self.assertIs(second.find_previous_sibling("li"), first)
        self.assertEqual(len(first.find_next_siblings("li")), 2)
        self.assertEqual(third.find_previous_siblings("li"), [second, first])
        self.assertEqual(second.next_sibling.strip(), "")
        self.assertIs(second.next_sibling.next_sibling, third)
        self.assertEqual(len([s for s in first.next_siblings if isinstance(s, Tag)]), 2)
        self.assertEqual(second.find_parent("body").name, "body")
        self.assertEqual([p.name for p in second.find_parents(["ul", "html"])], ["ul", "html"])
        self.assertEqual(second.find_next("a")["title"], "片二")
        self.assertEqual(second.span.find_next("a")["title"], "片三")
        self.assertEqual(second.a.find_previous("a")["title"], "片一")
        self.assertEqual(len(first.find_all_next("a")), 3)
        self.assertEqual([c.name for c in second.children if c.name], ["a", "span"])
        self.assertEqual(second.a.next_element.name, "img")
        self.assertEqual(second.span.previous_element.name, "img")
        self.assertEqual([d.name for d in second.descendants if d.name], ["a", "img", "span"])
        self.assertEqual(second.index(second.span), second.contents.index(second.span))

    def test_editing(self):
        soup = BeautifulSoup("<div><p>a</p><b>b</b>tail<i>c</i></div>", "html.parser")
        soup.b.decompose()
        self.assertEqual(str(soup), "<div><p>a</p>tail<i>c</i></div>")
        gone = soup.i.extract()
        self.assertEqual((str(gone), gone.parent, str(soup)), ("<i>c</i>", None, "<div><p>a</p>tail</div>"))
        soup.p.string = "<new>"
        soup.div.append(soup.new_tag("a", href="/x", attrs={"class": "k"}, string="t"))
        soup.p.insert_before("first")
        soup.p.insert_after(gone)
        self.assertEqual(str(soup), '<div>first<p>&lt;new&gt;</p><i>c</i>tail<a class="k" href="/x">t</a></div>')
        soup.i.replace_with("R")
        soup.p.unwrap()
        soup.a.wrap(soup.new_tag("u"))
        self.assertEqual(str(soup), '<div>first&lt;new&gt;Rtail<u><a class="k" href="/x">t</a></u></div>')
        soup.smooth()
        self.assertEqual(soup.div.contents[0], "first<new>Rtail")
        soup.div.clear()
        self.assertEqual(str(soup), "<div></div>")
        [s.extract() for s in self.soup(["script", "style"])]
        self.assertIsNone(self.soup.script)
        for br in BeautifulSoup("a<br>b", "html.parser").find_all("br"):
            br.replace_with("\n")

    def test_equality_and_copy(self):
        one, two = BeautifulSoup("<p class='x'>a</p><p class='x'>a</p>", "html.parser").find_all("p")
        self.assertEqual(one, two)
        self.assertIsNot(one, two)
        self.assertEqual(len({one, two}), 1)
        twin = copy.copy(one)
        twin["class"] = "y"
        self.assertEqual(one["class"], ["x"])
        self.assertIsNone(twin.parent)
        self.assertEqual(str(copy.copy(self.soup)), str(self.soup))
        self.assertTrue(BeautifulSoup("<p></p>", "html.parser").p)
        self.assertEqual(len(one), 1)

    def test_output(self):
        soup = BeautifulSoup('<p title=\'say "hi"\' hidden>a &amp; b &lt; c<br>d<img src="x?a=1&amp;b=2"></p><script>a<b</script>', "html.parser")
        self.assertEqual(
            str(soup),
            "<p title='say \"hi\"' hidden=\"\">a &amp; b &lt; c<br/>d<img src=\"x?a=1&amp;b=2\"/></p><script>a<b</script>")
        self.assertEqual(soup.p.decode_contents(), 'a &amp; b &lt; c<br/>d<img src="x?a=1&amp;b=2"/>')
        self.assertEqual(soup.encode("gbk")[:2], b"<p")
        self.assertEqual(BeautifulSoup("<div><p>a<b>c</b></p></div>", "html.parser").prettify(),
                         "<div>\n <p>\n  a\n  <b>\n   c\n  </b>\n </p>\n</div>\n")
        self.assertTrue(soup.p.decode(formatter=None).startswith("<p title='say \"hi\"' hidden=\"\">a & b < c"))
        self.assertEqual(BeautifulSoup("<p>©</p>", "html.parser").decode(formatter="html"), "<p>&copy;</p>")


class ParserTests(Base):
    def test_html_parser_rules(self):
        """Same loose nesting as upstream's html.parser builder."""
        self.assertEqual(str(BeautifulSoup("<p>a<p>b", "html.parser")), "<p>a<p>b</p></p>")
        self.assertEqual(str(BeautifulSoup("a</b>c<br/></br>", "html.parser")), "ac<br/>")
        self.assertEqual(str(BeautifulSoup("<b><i>x</b>y</i>", "html.parser")), "<b><i>x</i></b>y")
        self.assertEqual(str(BeautifulSoup("<div/>x", "html.parser")), "<div></div>x")
        self.assertEqual(BeautifulSoup("<p>  \n  </p>", "html.parser").p.string, "\n")
        self.assertEqual(BeautifulSoup("<pre>  \n  </pre>", "html.parser").pre.string, "  \n  ")
        self.assertEqual(BeautifulSoup("&lt;&nbsp;&#20013;&copy", "html.parser").string, "<\xa0中©")
        self.assertEqual(BeautifulSoup("<!DOCTYPE html><p>x", "html.parser").contents[0], "html")
        self.assertEqual(str(BeautifulSoup("<!DOCTYPE html><p>x</p>", "html.parser")), "<!DOCTYPE html>\n<p>x</p>")
        self.assertEqual(BeautifulSoup("<a b='1' b='2'>", "html.parser").a["b"], "2")
        self.assertFalse(host.calls)  # html.parser never needs the host

    def test_lxml_builder(self):
        soup = BeautifulSoup("<p>a<p>b", "lxml")
        self.assertEqual(str(soup), "<html><body><p>a</p><p>b</p></body></html>")
        host.calls.clear()
        soup = BeautifulSoup(PAGE, "lxml")
        self.assertEqual(soup.contents[0], "html")
        self.assertEqual([a["title"] for a in soup.select("li a")], ["片一", "片二", "片三"])
        self.assertEqual(soup.script.string, 'var player={"url":"a<b&c"};')
        self.assertEqual(host.names(), ["html.load", "html.rel", "html.outer"])
        self.assertEqual(str(BeautifulSoup("<i>x", "html5lib").body), "<body><i>x</i></body>")
        self.assertEqual(BeautifulSoup("<i>x").i.string, "x")
        self.assertEqual(str(BeautifulSoup("", "lxml")), "")

    def test_soup_outlives_the_host_document(self):
        soup = BeautifulSoup(PAGE, "lxml")
        host.reset()
        self.assertEqual(soup.select_one("li.on a")["title"], "片二")

    def test_xml(self):
        soup = BeautifulSoup('<?xml version="1.0"?><Rss xmlns:m="urn:m"><Item id="1"><link>u</link><m:c/></Item></Rss>', "xml")
        self.assertEqual(soup.find("Item")["id"], "1")
        self.assertEqual(soup.Item.link.string, "u")
        self.assertIsNone(soup.find("item"))
        self.assertTrue(str(soup).startswith('<?xml version="1.0" encoding="utf-8"?>\n<Rss'))
        self.assertEqual(len(soup.select("Item > link")), 1)

    def test_inputs(self):
        self.assertEqual(BeautifulSoup("<p>中</p>".encode("gbk"), "html.parser", from_encoding="gbk").p.text, "中")
        page = '<meta charset="gbk"><p>中文内容</p>'.encode("gbk")
        soup = BeautifulSoup(page, "html.parser")
        self.assertEqual((soup.p.text, soup.original_encoding), ("中文内容", "gb18030"))
        self.assertEqual(BeautifulSoup(io.StringIO("<p>x</p>"), "html.parser").p.text, "x")
        with self.assertRaises(bs4.FeatureNotFound):
            BeautifulSoup("<p>", "nope")
        with self.assertRaises(TypeError):
            BeautifulSoup(None, "html.parser")

    def test_deep_nesting(self):
        soup = BeautifulSoup("<div>" * 5000 + "x", "html.parser")
        self.assertEqual(soup.get_text(), "x")
        self.assertTrue(str(soup).endswith("</div>"))
        self.assertEqual(len(soup.find_all("div")), 5000)
        self.assertTrue(soup.prettify())


if __name__ == "__main__":
    unittest.main()
