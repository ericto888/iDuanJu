package app.iduanju.core.tvbox

import app.iduanju.core.util.ProviderException
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

class ParseChainTest {
    private val bodies = HashMap<String, String>()
    private val requests = CopyOnWriteArrayList<NetRequest>()
    private val sniffs = CopyOnWriteArrayList<SniffRequest>()
    private val cancelled = AtomicInteger()
    private var sniff: suspend (SniffRequest) -> SniffResult = { SniffResult("https://sniffed.example/v.m3u8", mapOf("Referer" to it.url)) }
    private val http = TVBoxHttp { r -> requests += r; Thread.sleep(if (r.url.contains("slow")) 300 else 0); NetResponse(200, r.url, emptyMap(), (bodies.entries.firstOrNull { r.url.startsWith(it.key) }?.value ?: throw IOException("offline")).toByteArray()) }

    private fun config(json: String) = (TVBoxConfig.parse("""{"sites":[{"key":"a","type":1,"api":"https://a.example"}],$json}""", "") as ParsedConfig.Config).config
    private fun chain(json: String = "\"flags\":[]", jar: JarParsers? = null, preferred: String = "") = ParseChain(config(json), http, { sniffs += it; sniff(it) }, jar, false, preferred, 2000)
    private fun run(c: ParseChain, r: String, flag: String = "qq", click: String = "") = runBlocking { c.resolve(PlayerResult.parse(r), flag, click) }

    @Test fun directResultsAreNotTouched() {
        val c = chain(""""flags":["qq"],"parses":[{"name":"w","type":0,"url":"https://w.example/?u="}]""")
        assertEquals(listOf("" to "https://v.example/a.m3u8"), run(c, """{"parse":0,"url":"https://v.example/a.m3u8"}""").urls)
        assertEquals(listOf("" to "https://pre.example/?u=abc"), run(c, """{"parse":0,"playUrl":"https://pre.example/?u=","url":"abc"}""").urls)
        assertEquals("https://v.example/b.mp4", run(chain(), """{"parse":1,"url":"https://v.example/b.mp4"}""").urls.single().second)
        assertEquals("http://127.0.0.1:9978/proxy?do=x", run(chain(), """{"url":"http://127.0.0.1:9978/proxy?do=x"}""").urls.single().second)
        assertTrue(sniffs.isEmpty())
        run(chain(), """{"url":"https://page.example/play/1"}"""); assertEquals("https://page.example/play/1", sniffs.single().url) // a missing parse means "needs parsing"
        sniffs.clear(); run(chain(), """{"parse":1,"url":"http://127.0.0.1:9978/proxy?do=page"}"""); assertEquals(1, sniffs.size) // explicit: the proxied page is opened
        assertTrue(assertThrows(ProviderException::class.java) { run(c, """{"parse":0,"url":"magnet:?xt=1"}""") }.message!!.contains("P2P"))
        assertTrue(assertThrows(ProviderException::class.java) { run(c, """{"parse":0,"msg":"需要登录"}""") }.message!!.contains("需要登录"))
    }

    @Test fun playUrlPrefixesPickTheirParse() {
        bodies["https://p.example/?url=abc"] = """{"code":200,"url":"https://v.example/j.m3u8","User-Agent":"P","header":{"Referer":"https://r.example"}}"""
        val c = chain(""""parses":[{"name":"甲","type":1,"url":"https://p2.example/?url=","ext":{"header":{"X":"1"}}}]""")
        val j = run(c, """{"parse":0,"playUrl":"json:https://p.example/?url=","url":"abc"}""")
        assertEquals("https://v.example/j.m3u8", j.urls.single().second); assertEquals(mapOf("Referer" to "https://r.example", "User-Agent" to "P"), j.headers)
        bodies["https://p2.example/?url=abc"] = """{"data":{"url":"https://v.example/k.mp4"}}"""
        assertEquals("https://v.example/k.mp4", run(c, """{"playUrl":"parse:甲","url":"abc"}""").urls.single().second); assertEquals("1", requests.last().headers["X"])
        assertTrue(assertThrows(ProviderException::class.java) { run(c, """{"playUrl":"parse:没有","url":"abc"}""") }.message!!.contains("没有"))
    }

    @Test fun pagesAreSniffedWithRulesClickAndHeaders() {
        val c = chain(""""rules":[{"hosts":["page.example"],"regex":["\\.php\\?v="],"exclude":["ad\\."],"script":["document.x()"]}],"ads":["ad.example"]""")
        run(c, """{"parse":1,"url":"https://page.example/1.html","header":{"User-Agent":"U"},"click":"a()"}""", "", "b()")
        val s = sniffs.single()
        assertEquals("https://page.example/1.html", s.url); assertEquals("U", s.headers["User-Agent"]); assertEquals(listOf("a()", "b()", "document.x()"), s.scripts); assertEquals(listOf("ad.example"), s.ads)
        assertTrue(SniffRules.isVideo("https://cdn.example/x.php?v=1", s.url, s.rules)); assertEquals(false, SniffRules.isVideo("https://ad.example/ad.m3u8", s.url, s.rules)); assertEquals(false, SniffRules.isVideo("https://cdn.example/x.js", s.url, s.rules))
        assertTrue(SniffRules.isAd("x.ad.example", s.ads)); assertEquals(false, SniffRules.isAd("good.example", s.ads))
    }

    @Test fun flaggedAndJxResultsRaceAllParses() {
        bodies["https://slow.example/"] = """{"url":"https://v.example/slow.m3u8"}"""
        bodies["https://bad.example/"] = """{"code":404,"msg":"解析失败"}"""
        sniff = { try { awaitCancellation() } finally { cancelled.incrementAndGet() } }
        val parses = """"flags":["qq"],"parses":[{"name":"坏","type":1,"url":"https://bad.example/?u="},{"name":"慢","type":1,"url":"https://slow.example/?u="},{"name":"网","type":0,"url":"https://w.example/?u="},{"name":"超级","type":4,"url":""}]"""
        val t = System.currentTimeMillis()
        val r = run(chain(parses), """{"parse":1,"url":"https://v.qq.example/x.html"}""")
        assertEquals("https://v.example/slow.m3u8", r.urls.single().second); assertEquals("慢", r.via); assertTrue(System.currentTimeMillis() - t < 1500); assertEquals(1, cancelled.get())
        // the browser parse wins when it is faster
        sniff = { delay(20); SniffResult("https://v.example/web.mp4", emptyMap()) }
        assertEquals("https://v.example/web.mp4", run(chain(parses), """{"parse":0,"jx":1,"url":"https://v.qq.example/x.html"}""").urls.single().second)
        // not flagged: only the page itself is sniffed
        sniffs.clear(); run(chain(parses), """{"parse":1,"url":"https://v.other.example/x.html"}""", "other"); assertEquals("https://v.other.example/x.html", sniffs.single().url)
    }

    @Test fun parsesMayBeLimitedToFlagsAndAUserChoice() {
        bodies["https://one.example/"] = """{"url":"https://v.example/one.m3u8"}"""; bodies["https://two.example/"] = """{"url":"https://v.example/two.m3u8"}"""
        val parses = """"flags":["qq","iqiyi"],"parses":[{"name":"一","type":1,"url":"https://one.example/?u=","ext":{"flag":["iqiyi"]}},{"name":"二","type":1,"url":"https://two.example/?u=","ext":{"flag":["qq"]}}]"""
        assertEquals("https://v.example/two.m3u8", run(chain(parses), """{"parse":1,"url":"https://x.example/1.html"}""").urls.single().second)
        assertTrue(requests.none { it.url.startsWith("https://one.example") })
        assertEquals("https://v.example/one.m3u8", run(chain(parses, preferred = "一"), """{"parse":1,"url":"https://x.example/1.html"}""").urls.single().second)
        bodies.remove("https://one.example/")
        assertEquals("https://v.example/two.m3u8", run(chain(parses, preferred = "一"), """{"parse":1,"url":"https://x.example/1.html"}""").urls.single().second)
        bodies.clear()
        assertThrows(ProviderException::class.java) { run(chain(parses), """{"parse":1,"url":"https://x.example/1.html"}""") }
    }

    @Test fun jsonResultsThatStillNeedABrowserAreSniffed() {
        bodies["https://p.example/"] = """{"parse":1,"url":"https://player.example/?id=1","header":{"Referer":"https://p.example"}}"""
        val r = run(chain(""""parses":[{"name":"p","type":1,"url":"https://p.example/?u="}]"""), """{"jx":1,"url":"https://v.qq.example/x.html"}""")
        assertEquals("https://sniffed.example/v.m3u8", r.urls.single().second); assertEquals("https://player.example/?id=1", sniffs.single().url); assertEquals("https://p.example", sniffs.single().headers["Referer"])
    }

    @Test fun jarExtensionsReceiveTheOtherParses() {
        val calls = ArrayList<String>()
        val jar = object : JarParsers {
            override suspend fun json(key: String, jxs: LinkedHashMap<String, String>, url: String): JSONObject { calls += "json $key $jxs $url"; return JSONObject().put("url", "https://v.example/x.m3u8") }
            override suspend fun mix(key: String, name: String, flag: String, jxs: LinkedHashMap<String, HashMap<String, String>>, url: String): JSONObject { calls += "mix $key $name $flag ${jxs["一"]!!["type"]} $url"; return JSONObject().put("url", "https://v.example/y.m3u8") }
        }
        val parses = """"parses":[{"name":"一","type":1,"url":"https://one.example/?url=","ext":{"a":1}},{"name":"包","type":2,"url":"Demo"},{"name":"混","type":3,"url":"M"}]"""
        assertEquals("https://v.example/x.m3u8", run(chain(parses, jar, "包"), """{"jx":1,"url":"u"}""").urls.single().second)
        assertEquals("https://v.example/y.m3u8", run(chain(parses, jar, "混"), """{"jx":1,"url":"u"}""").urls.single().second)
        assertTrue(calls[0].startsWith("json Demo {一=https://one.example/?cat_ext=eyJhIjoxfQ==&url=}")); assertEquals("mix M 混 qq 1 u", calls[1])
        assertTrue(assertThrows(ProviderException::class.java) { run(chain(""""parses":[{"name":"包","type":2,"url":"Demo"}]""", null, "包"), """{"jx":1,"url":"https://u.example/1"}""") }.message!!.contains("JAR"))
    }
}
