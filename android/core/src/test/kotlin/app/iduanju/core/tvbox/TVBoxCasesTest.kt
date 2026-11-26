package app.iduanju.core.tvbox

import app.iduanju.core.util.J
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** shared/tvbox/cases.json: the behaviour both platforms agree on. Every section of the file must be covered here. */
class TVBoxCasesTest {
    private val cases = JSONObject(javaClass.getResource("/cases.json")!!.readText())
    private val covered = HashSet<String>()

    private fun each(section: String, run: (JSONObject) -> Unit) {
        covered += section
        val list = cases.getJSONArray(section)
        assertTrue("$section is empty", list.length() > 0)
        for (i in 0 until list.length()) {
            val c = list.getJSONObject(i)
            try { run(c) } catch (e: Throwable) { throw AssertionError("$section[$i] ${c.optString("name")}: ${e.message}", e) }
        }
    }

    private fun same(expect: Any?, actual: Any?) {
        when (expect) {
            is JSONObject -> { actual as JSONObject; assertEquals(expect.keySet(), actual.keySet()); expect.keySet().forEach { same(expect.get(it), actual.get(it)) } }
            is JSONArray -> { actual as JSONArray; assertEquals(expect.length(), actual.length()); for (i in 0 until expect.length()) same(expect.get(i), actual.get(i)) }
            is Number -> assertEquals(expect.toDouble(), (actual as Number).toDouble(), 0.0)
            else -> assertEquals(expect, actual)
        }
    }

    private fun map(o: JSONObject) = o.keySet().associateWith { o.getString(it) }

    @Test fun everySectionBehavesAsAgreed() {
        each("lenientJson") { same(it.get("expect"), LenientJson.parse(it.getString("input"))) }
        each("resolve") { assertEquals(it.getString("expect"), TVBoxUrl.resolve(it.getString("base"), it.getString("ref"))) }
        each("decode") {
            assertEquals(it.getString("expect"), TVBoxDecoder.decode(it.getString("input"), it.getString("key")))
            assertEquals(it.getString("expect"), TVBoxDecoder.decode(it.getString("input").toByteArray(), it.getString("key")))
        }
        each("spiderRef") {
            val e = it.getJSONObject("expect")
            assertEquals(SpiderRef(e.getString("url"), e.getString("md5"), e.getBoolean("image")), SpiderRef.parse(it.getString("input")))
        }
        each("siteKind") { assertEquals(it.getString("expect"), SiteKind.of(it.getInt("type"), it.getString("api")).wire) }
        each("picture") {
            val p = TVBoxUrl.picture(it.getString("input")); val e = it.getJSONObject("expect")
            assertEquals(e.getString("url"), p.url); assertEquals(map(e.getJSONObject("headers")), p.headers)
        }
        each("playLines") {
            val lines = VodMapper.lines(it.getString("from"), it.getString("url")); val e = it.getJSONArray("expect")
            assertEquals(e.length(), lines.size)
            lines.forEachIndexed { i, l ->
                assertEquals(e.getJSONObject(i).getString("name"), l.flag)
                assertEquals(e.getJSONObject(i).getJSONArray("eps").map { p -> (p as JSONArray).let { a -> a.getString(0) to a.getString(1) } }, l.eps)
            }
        }
        each("streamUrl") {
            val s = TVBoxUrl.stream(it.getString("input")); val e = it.getJSONObject("expect")
            assertEquals(e.getString("url"), s.url); assertEquals(map(e.getJSONObject("headers")), s.headers); assertEquals(e.getString("label"), s.label)
        }
        each("playerResult") {
            val r = PlayerResult.fromJSON(it.getJSONObject("input")); val e = it.getJSONObject("expect")
            assertEquals(e.getInt("parse"), r.parse); assertEquals(e.getInt("jx"), r.jx); assertEquals(e.getString("playUrl"), r.playUrl); assertEquals(e.getString("danmaku"), r.danmaku)
            assertEquals(map(e.getJSONObject("headers")), r.headers)
            assertEquals(e.getJSONArray("urls").map { p -> (p as JSONArray).let { a -> a.getString(0) to a.getString(1) } }, r.urls)
            assertEquals(e.getJSONArray("subs").map { s -> (s as JSONArray).toList() }, r.subs.map { s -> listOf(s.name, s.url, s.language, s.format) })
        }
        each("isVideoUrl") { assertEquals(it.getString("url"), it.getBoolean("expect"), SniffRules.isVideo(it.getString("url"), "", emptyList())) }
        each("liveText") { c ->
            val groups = LiveParser.parse(c.getString("input")).groups; val e = c.getJSONArray("expect")
            assertTrue(LiveParser.looksLikeList(c.getString("input")) || c.getString("input").startsWith("["))
            assertEquals(e.length(), groups.size)
            groups.forEachIndexed { i, g ->
                val x = e.getJSONObject(i)
                assertEquals(x.getString("name"), g.name); assertEquals(x.getString("pass"), g.pass)
                val channels = x.getJSONArray("channels")
                assertEquals(channels.length(), g.channels.size)
                g.channels.forEachIndexed { j, ch ->
                    val y = channels.getJSONObject(j)
                    assertEquals(y.getString("name"), ch.name); assertEquals(y.getJSONArray("urls").toList(), ch.urls)
                    if (y.has("logo")) assertEquals(y.getString("logo"), ch.logo)
                    if (y.has("tvgId")) assertEquals(y.getString("tvgId"), ch.tvgId)
                    if (y.has("tvgName")) assertEquals(y.getString("tvgName"), ch.tvgName)
                    if (y.has("headers")) assertEquals(map(y.getJSONObject("headers")), ch.headers)
                }
            }
        }
        each("epgUrl") { assertEquals(it.getString("expect"), EpgParser.url(it.getString("template"), it.getString("name"), it.getString("date"))) }
        each("siteUid") { assertEquals(it.getString("expect"), TVBoxConfig.siteUid(it.getString("repo"), it.getString("key"))) }
        val missing = cases.keySet() - covered
        if (missing.isNotEmpty()) fail("cases.json sections without a test: $missing")
    }

    @Test fun looseNumbersAndStringsAreRead() {
        val o = LenientJson.parse("{type: '3', n: 1.5, big: 12345678901, hex: 0x1F, plus: +2, bare: csp_Demo, re: \"a\\.b\\d\", u: \"\\u4e2d\", empty:, t: true}") as JSONObject
        assertEquals(3, J.int(o.opt("type"))); assertEquals(1.5, o.getDouble("n"), 0.0); assertEquals(12345678901L, o.getLong("big")); assertEquals(31, o.getInt("hex")); assertEquals(2, o.getInt("plus"))
        assertEquals("csp_Demo", o.getString("bare")); assertEquals("a\\.b\\d", o.getString("re")); assertEquals("中", o.getString("u")); assertTrue(o.isNull("empty")); assertTrue(o.getBoolean("t"))
    }
}
