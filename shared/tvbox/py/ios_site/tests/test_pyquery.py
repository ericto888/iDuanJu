import unittest

from fake_host import host
from test_lxml import PAGE

from lxml import etree
from pyquery import PyQuery as pq


class Base(unittest.TestCase):
    def setUp(self):
        host.reset()
        self.doc = pq(PAGE)


class ConstructTests(Base):
    def test_sources(self):
        self.assertEqual(self.doc[0].tag, "html")
        self.assertEqual(pq(PAGE.encode())("title").text(), "影视 & 剧集")
        self.assertEqual(pq('<div class="a"><p>x</p></div>').attr("class"), "a")
        element = etree.HTML(PAGE).xpath("//li")[1]
        self.assertEqual(pq(element).find("a").attr("title"), "片二")
        self.assertEqual(len(pq([element, element.getparent()])), 2)
        self.assertEqual(pq(self.doc("li")).length, 3)
        self.assertEqual(pq("li", self.doc).length, 3)
        self.assertEqual(pq("li", PAGE).eq(0).find("a").attr("title"), "片一")
        self.assertEqual(pq("li", element).length, 1)
        self.assertEqual(len(pq("")), 0)
        self.assertEqual(len(pq([])), 0)

    def test_xml(self):
        doc = pq('<?xml version="1.0" encoding="utf-8"?><rss><list><video><name>A</name><link>u</link></video></list></rss>')
        self.assertEqual(doc("video name").text(), "A")
        self.assertEqual(doc("link").text(), "u")
        self.assertEqual(pq("<rss><Item><link>u</link></Item></rss>")("Item > link").text(), "u")

    def test_url(self):
        host.on("https://s.example/p", PAGE, headers={"Content-Type": "text/html; charset=utf-8"})
        doc = pq(url="https://s.example/p", headers={"User-Agent": "UA"})
        self.assertEqual(doc("li").length, 3)
        self.assertEqual(host.requests[-1]["headers"]["User-Agent"], "UA")
        self.assertEqual(doc.make_links_absolute()("li a").attr("href"), "https://s.example/d/1.html")


class SelectTests(Base):
    def test_spider_loop(self):
        videos = [{
            "vod_id": item("a").attr("href"), "vod_name": item("a").attr("title"),
            "vod_pic": item.find("img").attr("data-src"), "vod_remarks": item("span").text(),
        } for item in self.doc(".list .item").items()]
        self.assertEqual(videos[0], {
            "vod_id": "/d/1.html", "vod_name": "片一", "vod_pic": "//i.example/1.jpg", "vod_remarks": "更新至10集"})
        self.assertEqual(videos[2], {"vod_id": "/d/3.html", "vod_name": "片三", "vod_pic": None, "vod_remarks": ""})

    def test_items(self):
        items = list(self.doc.items("li"))
        self.assertEqual(len(items), 3)
        self.assertIsInstance(items[0], pq)
        self.assertEqual([i.attr("class") for i in self.doc("li").items(".on")], ["item on"])  # falls back to filter()
        self.assertEqual([i.text() for i in self.doc("#nav a").items()], ["首页", "电影"])

    def test_call_includes_self_find_does_not(self):
        for includes in (False, True):  # hosts differ in whether select() returns the context element
            host.select_includes_self = includes
            li = self.doc("li").eq(1)
            self.assertEqual(li("li").length, 1)
            self.assertEqual(li.find("li").length, 0)
            self.assertEqual(li("a").attr("title"), "片二")
            nested = pq("<div class='x'><div class='x'>i</div></div>")
            self.assertEqual(nested(".x").length, 2)
            self.assertEqual(nested.find(".x").length, 1)
            self.assertEqual(nested(".x").find(".x").length, 1)

    def test_positional(self):
        self.assertEqual(self.doc("li:eq(1) a").attr("title"), "片二")
        self.assertEqual(self.doc("li:first a").attr("title"), "片一")
        self.assertEqual(self.doc("li:last a").attr("title"), "片三")
        self.assertEqual(self.doc("li:gt(0)").length, 2)
        self.assertEqual(self.doc("li:lt(2)").length, 2)
        self.assertEqual(self.doc('li:contains("完结") a').attr("title"), "片二")
        self.assertEqual(self.doc("li:has(img)").length, 2)
        self.assertEqual(self.doc("li:not(.on)").length, 2)

    def test_list_behaviour(self):
        items = self.doc("li")
        self.assertEqual((len(items), items.length, items.size()), (3, 3, 3))
        self.assertIsInstance(items[0], etree._Element)
        self.assertEqual(items[0].get("class"), "item")
        self.assertEqual(items[1:].length, 2)
        self.assertEqual(items[-1].find("a").get("title"), "片三")
        self.assertEqual([e.find("a").get("title") for e in items], ["片一", "片二", "片三"])
        self.assertEqual([pq(e).find("a").attr.title for e in items], ["片一", "片二", "片三"])
        self.assertTrue(items)
        self.assertFalse(self.doc("nope"))
        self.assertEqual((self.doc("#nav") + items).length, 4)
        self.assertEqual(items.add(self.doc("#nav")).length, 4)
        self.assertEqual(repr(self.doc("#nav")), "[<div#nav.nav.top>]")

    def test_traversal(self):
        doc = self.doc
        li = doc("li.on")
        self.assertEqual(li.parent().attr("class"), "list")
        self.assertEqual([e.tag for e in li.parents()], ["html", "body", "ul"])
        self.assertEqual(li.parents("body").length, 1)
        self.assertEqual(li.closest("ul").attr("class"), "list")
        self.assertEqual(li.closest("li").attr("class"), "item on")
        self.assertEqual(li.closest("table").length, 0)
        self.assertEqual(li.next().find("a").attr("title"), "片三")
        self.assertEqual(li.prev().find("a").attr("title"), "片一")
        self.assertEqual(li.next(".nope").length, 0)
        self.assertEqual(doc("li").eq(0).nextAll().length, 2)
        self.assertEqual(doc("li").eq(0).next_all(".on").length, 1)
        self.assertEqual(doc("li").eq(2).prev_all().length, 2)
        self.assertEqual(li.siblings().length, 2)
        self.assertEqual(li.siblings("li").eq(1).find("a").attr("title"), "片三")
        self.assertEqual(li.children().length, 2)
        self.assertEqual(li.children("span").text(), "完结")
        self.assertEqual(doc("ul").children("li").children("a").length, 3)
        self.assertEqual(li.eq(5).length, 0)
        self.assertEqual(doc("li").first().find("a").attr("title"), "片一")
        self.assertEqual(doc("li").last().find("a").attr("title"), "片三")
        self.assertIs(li.end(), doc)
        self.assertEqual(doc("li").eq(0).find("span").end().attr("class"), "item")

    def test_filters(self):
        items = self.doc("li")
        self.assertEqual(items.filter(".on").length, 1)
        self.assertEqual(items.filter(":eq(2)").find("a").attr("title"), "片三")
        self.assertEqual(items.filter(lambda i: i > 0).length, 2)
        self.assertEqual(items.filter(lambda i, e: "on" in e.get("class")).length, 1)
        self.assertEqual(items.not_(".on").length, 2)
        self.assertTrue(items.is_(".on"))
        self.assertFalse(items.eq(0).is_(".on"))
        self.assertTrue(items.eq(1).has_class("on") and items.hasClass("on"))
        self.assertFalse(items.eq(0).hasClass("on"))
        self.assertTrue(items.eq(1).is_("ul > li"))

    def test_each_and_map(self):
        seen = []
        self.doc("li").each(lambda i, e: seen.append((i, pq(e)("a").attr("title"))))
        self.assertEqual(seen, [(0, "片一"), (1, "片二"), (2, "片三")])
        seen.clear()
        self.doc("li").each(lambda i: False if seen.append(i) or i == 1 else None)
        self.assertEqual(seen, [0, 1])
        self.assertEqual(list(self.doc("li").map(lambda i, e: pq(e)("a").attr("title"))), ["片一", "片二", "片三"])
        self.assertEqual(list(self.doc("li a").map(lambda i: pq(this).attr.href)), ["/d/1.html", "/d/2.html", "/d/3.html"])  # noqa: F821

    def test_contents(self):
        parts = self.doc("li").eq(0).find("span").contents()
        self.assertEqual([p if isinstance(p, str) else p.tag for p in parts], ["更新至", "b", "集"])


class ValueTests(Base):
    def test_attr(self):
        link = self.doc("li a")
        self.assertEqual((link.attr("href"), link.attr["href"], link.attr.href), ("/d/1.html",) * 3)
        self.assertIsNone(link.attr("nope"))
        self.assertIsNone(self.doc("nope").attr("x"))
        self.assertEqual(self.doc("img").attr("data-src"), "//i.example/1.jpg")
        self.assertEqual(self.doc("img").attr.data_src, "//i.example/1.jpg")
        self.assertEqual(self.doc("li").attr.class_, "item")
        link.attr("rel", "x").attr(target="_blank", class_="c")
        link.attr["title"] = "新"
        link.attr.lang = "zh"
        first = self.doc("li a").eq(0)
        self.assertEqual([first.attr(k) for k in ("rel", "target", "class", "title", "lang")], ["x", "_blank", "c", "新", "zh"])
        link.remove_attr("rel")
        link.removeAttr("target")
        self.assertIsNone(first.attr("rel"))
        link.addClass("k").removeClass("c").toggleClass("t")
        self.assertEqual(first.attr("class"), "k t")

    def test_text(self):
        self.assertEqual(self.doc("title").text(), "影视 & 剧集")
        self.assertEqual(self.doc("#nav a").text(), "首页 电影")
        self.assertEqual(self.doc("nope").text(), "")
        self.assertEqual(self.doc("li").eq(0).text(), "更新至10集 尾巴")
        block = pq("<div>  简介：\n  <b>a</b>  b<br>c<p>d</p><p>e</p>f </div>")
        self.assertEqual(block.text(), "简介： a b\nc\nd\ne\nf")
        self.assertEqual(block.text(block_symbol="|", sep_symbol="/"), "简介： a b/c|d|e|f")
        self.doc("b").text("11")
        self.assertEqual(self.doc("li span").eq(0).text(), "更新至11集")
        self.assertEqual(self.doc("script").text(), 'var player={"url":"a<b&c"};')

    def test_html(self):
        doc = pq('<div><p class="x">一<br>二&amp;</p><script>a<b&&c</script></div>')
        self.assertEqual(doc("p").html(), "一<br/>二&amp;")
        self.assertEqual(doc("p").html(method="html"), "一<br>二&amp;")
        self.assertEqual(doc("script").html(), "a<b&&c")
        self.assertEqual(doc("p").outer_html(), '<p class="x">一<br>二&amp;</p>')
        self.assertEqual(doc("p").outerHtml(), doc("p").outer_html())
        self.assertEqual(str(doc("p")), '<p class="x">一<br/>二&amp;</p>')
        self.assertIsNone(doc("nope").html())
        self.assertIsNone(doc("nope").outer_html())
        self.assertEqual(doc("br").html(), "")
        with self.assertRaisesRegex(NotImplementedError, "html"):
            doc("p").html("<b>x</b>")
        self.assertEqual(doc("p").html("plain").text(), "plain")

    def test_val(self):
        doc = pq('<form><input name="a" value="1"><textarea name="t">x</textarea><select name="s"><option value="p">P'
                 '</option><option selected>Q</option></select><input type="checkbox" name="c" checked></form>')
        self.assertEqual(doc('input[name="a"]').val(), "1")
        self.assertEqual(doc("textarea").val(), "x")
        self.assertEqual(doc("select").val(), "Q")
        self.assertEqual(doc("input:last").val(), "on")
        self.assertEqual(doc("form").serialize_dict(), {"a": "1", "t": "x", "s": "Q", "c": "on"})
        self.assertEqual(doc("form").serialize(), "a=1&t=x&s=Q&c=on")
        doc('input[name="a"]').val("2")
        self.assertEqual(doc('input[name="a"]').val(), "2")

    def test_remove(self):
        self.doc("script").remove()
        self.assertEqual(self.doc("script").length, 0)
        span = self.doc("li").eq(0)
        span.find("span").remove()
        self.assertEqual(span.text(), "尾巴")  # the text after a removed element stays
        self.doc.remove("li.on")
        self.assertEqual(self.doc("li").length, 2)
        self.assertEqual(self.doc("li").empty().text(), " ")

    def test_clone(self):
        import copy

        self.assertEqual(copy.copy(self.doc("li")).length, 3)
        self.assertEqual(copy.deepcopy(self.doc("li").eq(0))("a").attr("title"), "片一")
        twin = self.doc("li").eq(1).clone()
        twin.attr("class", "z")
        self.assertEqual(self.doc("li").eq(1).attr("class"), "item on")
        self.assertEqual(twin.find("a").attr("title"), "片二")

    def test_unsupported(self):
        for name in ("append", "prepend", "before", "after", "wrap", "replace_with", "appendTo"):
            with self.assertRaisesRegex(NotImplementedError, "pyquery"):
                getattr(self.doc("li"), name)("<b>x</b>")


if __name__ == "__main__":
    unittest.main()
