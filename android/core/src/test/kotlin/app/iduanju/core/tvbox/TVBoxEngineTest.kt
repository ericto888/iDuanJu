package app.iduanju.core.tvbox

import app.iduanju.core.hongguo.HGEpisode
import app.iduanju.core.hongguo.HGStreamKind
import app.iduanju.core.util.Bytes
import app.iduanju.core.util.ProviderException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.IOException
import java.net.HttpURLConnection
import java.net.Socket
import java.net.URL
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/** The engine over a real HTTP stack (MockWebServer plays every site) with fake jar / sniffer runtimes. */
class TVBoxEngineTest {
    @get:Rule val tmp = TemporaryFolder()
    private val server = MockWebServer()
    private val seen = CopyOnWriteArrayList<RecordedRequest>()
    private val routes = HashMap<String, (RecordedRequest) -> MockResponse>()
    private val sniffed = CopyOnWriteArrayList<SniffRequest>()
    private val closed = AtomicInteger()
    @Volatile private var running: Set<String>? = null
    private lateinit var net: TVBoxNet
    private lateinit var engine: TVBoxEngine

    private val jar = object : JarHost {
        override fun spider(http: TVBoxHttp, ref: SpiderRef, site: TVBoxSite): Spider = if (site.api == "csp_Broken") throw NoSuchMethodError("Lokhttp3/X;.y") else object : Spider {
            override fun homeContent(filter: Boolean): String { if (site.api == "csp_Slow") Thread.sleep(60_000); return """{"class":[{"type_id":"${site.ext}","type_name":"类"}],"list":[{"vod_id":"1","vod_name":"片","vod_pic":"proxy://do=csp&siteKey=${site.key}&u=1"}]}""" }
            override fun playerContent(flag: String, id: String, vipFlags: List<String>) = JSONObject().put("parse", 0).put("url", "http://127.0.0.1:9978/proxy?do=csp&siteKey=${site.key}&u=$id").put("header", JSONObject().put("ua", "J")).toString()
            override fun searchContent(key: String, quick: Boolean, pg: String): String { if (site.api == "csp_Slow") Thread.sleep(400); return """{"list":[{"vod_id":"$key","vod_name":"$key"}]}""" }
            override fun proxyLocal(params: Map<String, String>) = ProxyReply(206, "video/mp2t", (params["u"] + "|" + params["range"]).byteInputStream(), mapOf("Content-Range" to "bytes 0-1/2"))
            override fun liveContent(url: String) = "组,#genre#\n频道,http://l.example/1"
            override fun destroy() { closed.incrementAndGet() }
        }
        override fun proxy(params: Map<String, String>) = if (params["do"] == "static") ProxyReply.text("static") else null
        override fun release(keep: Set<String>, run: Set<String>) { running = run }
        override fun json(http: TVBoxHttp, ref: SpiderRef, key: String, jxs: LinkedHashMap<String, String>, url: String) = JSONObject().put("url", "https://ext.example/$key.m3u8").put("header", JSONObject().put("Referer", jxs.keys.joinToString("+")))
        override fun mix(http: TVBoxHttp, ref: SpiderRef, key: String, name: String, flag: String, jxs: LinkedHashMap<String, HashMap<String, String>>, url: String) = JSONObject().put("url", "https://mix.example/$flag.mp4")
    }

    @Before fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse { seen += request; return routes[request.path!!.substringBefore('?')]?.invoke(request) ?: MockResponse().setResponseCode(404) }
        }
        server.start()
        net = TVBoxNet(tmp.newFolder("local")) { server.port }
        val store = HashMap<String, String>()
        val storage = object : ScriptStorage { override fun get(ns: String, k: String) = store["$ns|$k"]; override fun set(ns: String, k: String, v: String) { store["$ns|$k"] = v }; override fun delete(ns: String, k: String) { store.remove("$ns|$k") } }
        engine = TVBoxEngine(net, TVBoxPlatform({ GraalJsEngine() }, null, jar, { r -> sniffed += r; SniffResult("https://sniff.example/v.m3u8", mapOf("Referer" to r.url)) }, { javaClass.getResource("/js/$it")?.readText() }, storage), TVBoxCache(tmp.newFolder("cache")), tmp.newFolder("scripts"), tmp.newFolder("epg"))
    }

    @After fun stop() { engine.shutdown(); server.shutdown() }

    private fun at(path: String) = server.url(path).toString().replace("localhost", "127.0.0.1")
    private fun json(body: String) = MockResponse().setHeader("Content-Type", "application/json; charset=utf-8").setBody(body)
    private fun use(config: String, trusted: Boolean = true, id: String = "r", local: Boolean = false): Map<String, String> {
        val c = (TVBoxConfig.parse(config, "https://h.example/c.json") as ParsedConfig.Config).config
        engine.setRepos(listOf(RepoRuntime(id, "仓", c, trusted, false, local = local)), id)
        return c.sites.associate { it.key to TVBoxConfig.siteUid(id, it.key) }
    }

    @Test fun t4SendsTheAgreedParameters() = runBlocking<Unit> {
        routes["/t4"] = { r ->
            val u = r.requestUrl!!
            json(when {
                u.queryParameter("play") != null -> """{"parse":0,"url":["1080P","https://v.example/a.m3u8|Referer=https%3A%2F%2Fr.example%2F","720P","https://v.example/b.mp4"],"header":"{\"User-Agent\":\"T4\"}","danmaku":"https://d.example/1.xml","subs":[{"name":"中","url":"https://s.example/a.srt","format":"application/x-subrip"}]}"""
                u.queryParameter("wd") != null -> """{"list":[{"vod_id":"9","vod_name":"${u.queryParameter("wd")}"}]}"""
                u.queryParameter("ids") != null -> """{"list":[{"vod_id":"9","vod_name":"剧","vod_play_from":"a${'$'}${'$'}${'$'}b","vod_play_url":"1${'$'}x#2${'$'}y${'$'}${'$'}${'$'}01${'$'}z"}]}"""
                u.queryParameter("t") != null -> """{"list":[{"vod_id":"1","vod_name":"页"}],"page":1,"pagecount":3}"""
                else -> """{"class":[{"type_id":"1","type_name":"电影"}],"filters":{"1":[{"key":"k","name":"n","value":[{"n":"a","v":"b"}]}]},"list":[{"vod_id":"1","vod_name":"推荐"}]}"""
            })
        }
        routes["/ext.json"] = { json("EXT-BODY") }
        val uid = use("""{"sites":[{"key":"t","name":"T4","type":4,"api":"${at("/t4")}","ext":"${at("/ext.json")}","header":{"X-Site":"1"}}],"headers":[{"host":"v.example","header":{"X-Rule":"2"}}]}""", local = true)["t"]!!
        val home = engine.home(uid).toList().single()
        assertTrue(home.fresh); assertEquals("电影", home.value.categories.single().name); assertEquals("推荐", home.value.items.single().title); assertEquals("b", home.value.filters["1"]!!.single().options.single().second)
        val page = engine.category(uid, "1", 1, mapOf("k" to "b")).toList().last().value
        assertTrue(page.hasMore)
        assertEquals("关键", engine.search(uid, "关键").items.single().title)
        val d = engine.detail(uid, "9")
        assertEquals(listOf("a", "b"), d.lines.map { it.name })
        val v = engine.resolve(d.lines[0].episodes[1])
        assertEquals(listOf("1080P", "720P"), v.streams.map { it.quality }); assertEquals(HGStreamKind.hls, v.streams[0].kind); assertEquals(HGStreamKind.mp4Clear, v.streams[1].kind)
        assertEquals(mapOf("X-Site" to "1", "User-Agent" to "T4", "Referer" to "https://r.example/", "X-Rule" to "2"), v.streams[0].headers); assertEquals("https://d.example/1.xml", v.danmaku); assertEquals("application/x-subrip", v.streams[0].subtitles.single().format)
        // an episode restored from history has no media: it is looked up again
        assertEquals("https://v.example/a.m3u8", engine.resolve(HGEpisode(1, TVBoxId.episode(uid, "9", 1, 0))).url)
        val q = seen.filter { it.path!!.startsWith("/t4") }.map { it.requestUrl!! }
        assertTrue(q.all { it.queryParameter("extend") == "EXT-BODY" }); assertTrue(seen.filter { it.path!!.startsWith("/t4") }.all { it.getHeader("X-Site") == "1" && it.getHeader("User-Agent") == "okhttp/4.12.0" })
        assertEquals("true", q[0].queryParameter("filter"))
        val cat = q.first { it.queryParameter("t") != null }
        assertEquals("detail", cat.queryParameter("ac")); assertEquals("1", cat.queryParameter("pg")); assertEquals("""{"k":"b"}""", String(Bytes.b64decode(cat.queryParameter("ext")!!)!!))
        assertEquals("y" to "a", q.first { it.queryParameter("play") != null }.let { it.queryParameter("play") to it.queryParameter("flag") })
    }

    @Test fun cmsJsonAndXmlWorkOverHttpAndKeepEveryLine() = runBlocking<Unit> {
        routes["/api.php"] = { r -> if (r.requestUrl!!.queryParameter("ac") == "list") json("""{"code":1,"class":[{"type_id":1,"type_name":"剧集"}],"list":[{"vod_id":1,"vod_name":"无图"}]}""") else json("""{"code":1,"page":"1","pagecount":2,"list":[{"vod_id":7,"vod_name":"片","vod_pic":"http://i.example/1.jpg","vod_play_from":"m3u8${'$'}${'$'}${'$'}qq","vod_play_url":"1${'$'}https://v.example/1.m3u8${'$'}${'$'}${'$'}1${'$'}https://v.qq.example/x.html"}]}""") }
        routes["/xml"] = { MockResponse().setBody("""<rss><list page="1" pagecount="1"><video><id>42</id><name>海岸</name><dl><dd flag="高清"><![CDATA[第一集${'$'}https://m.example/a.m3u8]]></dd></dl></video></list><class><ty id="7">纪录片</ty></class></rss>""") }
        val u = use("""{"sites":[{"key":"j","name":"J","type":1,"api":"${at("/api.php")}"},{"key":"x","name":"X","type":0,"api":"${at("/xml")}"}],"flags":["qq"],"parses":[{"name":"web","type":0,"url":"https://jx.example/?url="}]}""", trusted = false)
        val h = engine.home(u["j"]!!).toList().last().value
        assertEquals("剧集", h.categories.single().name); assertEquals("http://i.example/1.jpg", h.items.single().cover)
        val d = engine.detail(u["j"]!!, "7")
        assertEquals(listOf("m3u8", "qq"), d.lines.map { it.name })
        assertEquals("https://v.example/1.m3u8", engine.resolve(d.lines[0].episodes[0]).url); assertTrue(sniffed.isEmpty())
        val parsed = engine.resolve(d.lines[1].episodes[0])
        assertEquals("https://sniff.example/v.m3u8", parsed.url); assertEquals("https://jx.example/?url=https://v.qq.example/x.html", sniffed.single().url); assertEquals("https://jx.example/?url=https://v.qq.example/x.html", parsed.streams.single().headers["Referer"])
        assertEquals("纪录片", engine.home(u["x"]!!).toList().last().value.categories.single().name)
        assertEquals("videolist", seen.last { it.path!!.startsWith("/xml") }.requestUrl!!.queryParameter("ac"))
    }

    @Test fun cachedHomeAppearsFirstAndSurvivesFailures() = runBlocking<Unit> {
        val n = AtomicInteger()
        routes["/t4"] = { if (n.incrementAndGet() >= 3) MockResponse().setResponseCode(500) else json("""{"class":[{"type_id":"${n.get()}","type_name":"类"}]}""") }
        val uid = use("""{"sites":[{"key":"t","name":"T4","type":4,"api":"${at("/t4")}"}]}""")["t"]!!
        assertEquals("1", engine.home(uid).toList().single().value.categories.single().id)
        val again = engine.home(uid).toList()
        assertEquals(1, again.size); assertEquals(1, n.get()) // still fresh: no request
        val forced = engine.home(uid, force = true).toList()
        assertEquals(listOf("1" to false, "2" to true), forced.map { it.value.categories.single().id to it.fresh })
        val failed = engine.home(uid, force = true).toList()
        assertEquals(listOf("2", "2"), failed.map { it.value.categories.single().id }); assertNotNull(failed.last().error)
    }

    @Test fun codeSitesNeedTrustAndFailuresAreReadable() = runBlocking<Unit> {
        val config = """{"spider":"https://j.example/a.jar","sites":[{"key":"a","name":"甲","type":3,"api":"csp_A","ext":"E"},{"key":"b","name":"乙","type":3,"api":"csp_Broken"},{"key":"p","name":"蟒","type":3,"api":"https://p.example/a.py"},{"key":"z","name":"怪","type":9,"api":"?"}]}"""
        val u = use(config, trusted = false)
        fun fails(key: String) = assertThrows(ProviderException::class.java) { runBlocking { engine.home(u[key]!!).toList() } }.message!!
        assertTrue(fails("a").contains("尚未信任"))
        use(config, trusted = true)
        assertEquals("E", engine.home(u["a"]!!).toList().last().value.categories.single().id)
        assertTrue(fails("b").contains("不兼容")); assertTrue(fails("p").contains("未包含 Python")); assertTrue(fails("z").contains("不支持的站点类型"))
        assertTrue(assertThrows(ProviderException::class.java) { runBlocking { engine.detail("gone", "1") } }.message!!.contains("已删除"))
    }

    @Test fun localProxyStreamsSpiderRepliesAndGuardsItself() = runBlocking<Unit> {
        val u = use("""{"spider":"https://j.example/a.jar","sites":[{"key":"a-1","name":"甲","type":3,"api":"csp_A"}]}""")["a-1"]!!
        val item = engine.home(u).toList().last().value.items.single()
        val port = engine.runningPort
        assertTrue(port in 9978..9998); assertTrue(item.cover.startsWith("http://127.0.0.1:$port/proxy?do=csp"))
        fun get(path: String, range: String? = null) = (URL("http://127.0.0.1:$port$path").openConnection() as HttpURLConnection).apply { range?.let { setRequestProperty("Range", it) } }
        assertEquals("ok", get("/proxy?do=ck").inputStream.bufferedReader().readText())
        val v = engine.resolve(HGEpisode(1, TVBoxId.episode(u, "x", 0, 0), media = """{"f":"f","id":"77"}"""))
        assertEquals("J", v.streams.single().headers["User-Agent"])
        val c = URL(v.url!!).openConnection() as HttpURLConnection
        c.setRequestProperty("Range", "bytes=0-1")
        assertEquals(206, c.responseCode); assertEquals("bytes 0-1/2", c.getHeaderField("Content-Range")); assertEquals("77|bytes=0-1", c.inputStream.bufferedReader().readText())
        assertEquals("static", get("/proxy?do=static").inputStream.bufferedReader().readText())
        assertEquals(404, get("/proxy?do=js&siteKey=none").responseCode); assertEquals(404, get("/other").responseCode)
        // DNS rebinding: a page that resolves its own host to 127.0.0.1 gets nothing
        Socket("127.0.0.1", port).use { s -> s.getOutputStream().write("GET /proxy?do=ck HTTP/1.1\r\nHost: evil.example:$port\r\n\r\n".toByteArray()); assertTrue(s.getInputStream().bufferedReader().readLine().contains("403")) }
    }

    @Test fun jsSpiderAndItsProxyThroughTheEngine() = runBlocking<Unit> {
        routes["/a.js"] = { MockResponse().setBody("export default { home: () => ({ class: [{ type_id: 'x', type_name: '类' }] }), play: (f, id) => ({ parse: 0, url: 'proxy://do=js&p=' + id }), proxy: p => [200, 'text/plain', 'JS' + p.p] }") }
        val u = use("""{"sites":[{"key":"js 站","name":"JS","type":3,"api":"${at("/a.js")}"}]}""")["js 站"]!!
        assertEquals("x", engine.home(u).toList().last().value.categories.single().id)
        val v = engine.resolve(HGEpisode(1, TVBoxId.episode(u, "x", 0, 0), media = """{"f":"f","id":"5"}"""))
        assertEquals("JS5", URL(v.url!!).readText())
    }

    @Test fun importedFilesReachScriptsThroughTheLoopbackServer() = runBlocking<Unit> {
        java.io.File(tmp.root, "local/规则 1.json").writeText("""{"v":"本地"}""")
        java.io.File(tmp.root, "local/a.js").writeText("let v; export default { init: ext => { v = JSON.parse(req(ext).content).v }, home: () => ({ class: [{ type_id: v, type_name: v }] }) }")
        val c = (TVBoxConfig.parse("""{"sites":[{"key":"l","name":"L","type":3,"api":"./a.js","ext":"./规则 1.json"}]}""", "clan://localhost/cfg.json") as ParsedConfig.Config).config
        assertEquals("clan://localhost/规则 1.json", c.sites.single().ext)
        engine.setRepos(listOf(RepoRuntime("r", "仓", c, true, false)), "r")
        // the engine's own port is the only loopback target scripts may reach
        net = TVBoxNet(java.io.File(tmp.root, "local")) { engine.runningPort }
        val e = TVBoxEngine(net, TVBoxPlatform({ GraalJsEngine() }, null, null, { throw IOException() }, { javaClass.getResource("/js/$it")?.readText() }, object : ScriptStorage { override fun get(ns: String, k: String): String? = null; override fun set(ns: String, k: String, v: String) {}; override fun delete(ns: String, k: String) {} }), TVBoxCache(tmp.newFolder("cache2")), tmp.newFolder("scripts2"), tmp.newFolder("epg2"))
        engine.shutdown(); engine = e
        e.setRepos(listOf(RepoRuntime("r", "仓", c, true, false)), "r")
        assertEquals("本地", e.home(TVBoxConfig.siteUid("r", "l")).toList().last().value.categories.single().name)
        assertEquals(404, (URL("http://127.0.0.1:${e.runningPort}/file/..%2F..%2Fpasswd").openConnection() as HttpURLConnection).responseCode)
    }

    @Test fun aggregatedSearchStreamsWithoutABarrier() = runBlocking<Unit> {
        val u = use("""{"spider":"https://j.example/a.jar","sites":[{"key":"s","name":"慢","type":3,"api":"csp_Slow"},{"key":"a","name":"快","type":3,"api":"csp_A"},{"key":"b","name":"坏","type":3,"api":"csp_Broken"}]}""")
        val order = engine.searchAll(listOf(u["s"]!!, u["a"]!!, u["b"]!!, "unknown"), "词").toList()
        assertEquals(3, order.size); assertEquals("慢", order.last().ref.site.name); assertEquals("词", order.first { it.ref.site.name == "快" }.items.single().title); assertNotNull(order.first { it.ref.site.name == "坏" }.error)
    }

    @Test fun removingAConfigDestroysItsSpiders() = runBlocking<Unit> {
        val u = use("""{"spider":"https://j.example/a.jar","sites":[{"key":"a","name":"甲","type":3,"api":"csp_A"}]}""")["a"]!!
        engine.home(u).toList()
        assertEquals(TVBoxEngine.SpiderStatus.Ready, engine.status(u))
        engine.restart("r")
        withTimeout(3000) { while (closed.get() == 0) delay(20) }
        assertEquals(TVBoxEngine.SpiderStatus.Idle, engine.status(u))
        engine.home(u, force = true).toList()
        assertEquals(TVBoxEngine.SpiderStatus.Ready, engine.status(u))
        engine.setRepos(emptyList(), "")
        withTimeout(3000) { while (closed.get() == 1) delay(20) }
        assertNull(engine.site(u))
    }

    @Test fun timeoutsAndCancellationReleaseTheSpider() = runBlocking<Unit> {
        val s = SpiderSession("测", 1000) { object : Spider { override fun homeContent(filter: Boolean): String { Thread.sleep(if (filter) 10_000 else 0); return "ok" } } }
        val t = System.currentTimeMillis()
        assertTrue(assertThrows(SpiderTimeout::class.java) { runBlocking { s.call(200, "首页") { it.homeContent(true) } } }.message!!.contains("超时"))
        assertTrue(System.currentTimeMillis() - t < 2000)
        assertEquals("ok", s.call(1000, "首页") { it.homeContent(false) }) // the interrupted thread is usable again
        val job = async { s.call(5000, "首页") { it.homeContent(true) } }
        delay(100); job.cancelAndJoin(); assertTrue(job.isCancelled)
        assertEquals("ok", s.call(1000, "首页") { it.homeContent(false) }); assertFalse(s.dead)
        // a spider that ignores interrupts poisons its session, queued calls fail instead of hanging
        val stuck = SpiderSession("死", 1000) { object : Spider { override fun homeContent(filter: Boolean): String { val end = System.currentTimeMillis() + 6000; while (System.currentTimeMillis() < end) { try { Thread.sleep(100) } catch (_: InterruptedException) {} }; return "" } } }
        assertThrows(SpiderTimeout::class.java) { runBlocking { stuck.call(100, "首页") { it.homeContent(true) } } }
        withTimeout(5000) { while (!stuck.dead) delay(50) }
        assertThrows(SpiderStopped::class.java) { runBlocking { stuck.call(100, "首页") { "x" } } }
        s.close(); stuck.close()
    }

    @Test fun networkPolicyBlocksPrivateAndForeignLoopbackTargets() {
        val open = net.Scope(NetRules()); val lan = net.Scope(NetRules(allowPrivate = true))
        for (bad in listOf("http://10.0.0.1/x", "http://192.168.1.2:8080/", "http://[fe80::1]/", "http://127.0.0.1:1/", "http://localhost:1/", "http://169.254.1.1/")) assertThrows(bad, IOException::class.java) { open.check(bad.toHttpUrl()) }
        lan.check("http://192.168.1.2:8080/".toHttpUrl())
        assertThrows(IOException::class.java) { lan.check("http://127.0.0.1:1/".toHttpUrl()) }
        open.check("http://8.8.8.8/".toHttpUrl()); open.check("http://127.0.0.1:${server.port}/".toHttpUrl())
        routes["/hop"] = { MockResponse().setResponseCode(302).setHeader("Location", "http://10.1.2.3/secret") }
        assertTrue(assertThrows(IOException::class.java) { open.execute(NetRequest(at("/hop"))) }.message!!.contains("拦截"))
        routes["/post"] = { MockResponse().setResponseCode(303).setHeader("Location", "/done") }
        routes["/done"] = { MockResponse().setBody(it.method!!) }
        assertEquals("GET", open.execute(NetRequest(at("/post"), "POST", body = "x".toByteArray())).text())
        assertEquals(302, open.execute(NetRequest(at("/hop"), redirect = false)).code)
        assertThrows(IOException::class.java) { open.execute(NetRequest(at("/done"), maxBytes = 1)) }
        assertTrue(TVBoxNet.isPrivateAddress("http://192.168.1.5:9978/c.json")); assertFalse(TVBoxNet.isPrivateAddress("http://www.饭太硬.com/tv"))
    }

    @Test fun hostsHeadersAndLocalFiles() {
        routes["/h"] = { MockResponse().setBody(it.getHeader("Host") + "|" + it.getHeader("Referer") + "|" + it.getHeader("X")) }
        // a hosts entry may not be used to reach this device
        val s = net.Scope(NetRules(hosts = mapOf("mapped.example" to "127.0.0.1"), headers = listOf(TVBoxHeaderRule("127.0.0.1", mapOf("Referer" to "https://r.example")))))
        assertThrows(IOException::class.java) { s.execute(NetRequest("http://mapped.example:${server.port}/h")) }
        assertEquals("127.0.0.1:${server.port}|https://r.example|中".replace("中", "%E4%B8%AD"), s.execute(NetRequest(at("/h"), headers = mapOf("X" to "中"))).text())
        java.io.File(tmp.root, "local/cfg.json").writeText("{}")
        assertEquals("{}", s.execute(NetRequest("clan://localhost/cfg.json")).text()); assertEquals("{}", s.execute(NetRequest("file:///sdcard/x/cfg.json")).text())
        assertThrows(IOException::class.java) { s.execute(NetRequest("file:///../cache/../../etc/passwd")) }
    }

    @Test fun configLoaderReadsConfigsDepotsAndLists() = runBlocking<Unit> {
        val loader = ConfigLoader(net)
        routes["/c.json"] = { json("GIF89aAbCd1234**" + Bytes.b64("""{"sites":[{"key":"a","type":3,"api":"csp_A"}],"spider":"./a.jar"}""".toByteArray())) }
        routes["/d.json"] = { json("""{"urls":[{"name":"一","url":"./c.json"}]}""") }
        routes["/l.txt"] = { MockResponse().setBody("组,#genre#\nA,http://a.example/1") }
        routes["/web"] = { MockResponse().setBody("<html>") }
        val c = loader.load(at("/c.json"), false)
        assertEquals(at("/a.jar"), (c.parsed as ParsedConfig.Config).config.spider); assertEquals("okhttp/4.12.0", seen.last().getHeader("User-Agent"))
        assertEquals(at("/c.json"), (loader.load(at("/d.json"), false).parsed as ParsedConfig.Depot).entries.single().url)
        assertTrue(loader.load(at("/l.txt"), false).parsed is ParsedConfig.Live)
        assertThrows(LenientJson.Malformed::class.java) { runBlocking { loader.load(at("/web"), false) } }
        assertTrue(assertThrows(ProviderException::class.java) { runBlocking { loader.load(at("/none"), false) } }.message!!.contains("404"))
        assertEquals("http://a.example/x", ConfigLoader.normalize(" a.example/x ")); assertThrows(ProviderException::class.java) { ConfigLoader.normalize("ftp://x/y") }; assertThrows(ProviderException::class.java) { ConfigLoader.normalize("hello") }
    }

    @Test fun liveChannelsGroupsGuideCatchupAndSpiderLists() = runBlocking<Unit> {
        routes["/live.txt"] = { MockResponse().setBody("央视,#genre#\nCCTV1,http://a.example/1.m3u8\$主#http://b.example/PLTV/2|User-Agent=X\n密_pw,#genre#\n锁,http://c.example/3\n") }
        routes["/epg"] = { r -> json("""{"epg_data":[{"title":"全天","start":"00:00","end":"23:59"}],"q":"${r.requestUrl!!.queryParameter("ch")}"}""") }
        routes["/v"] = { MockResponse().setBody("x") }
        val c = (TVBoxConfig.parse("""{"spider":"https://j.example/a.jar","sites":[{"key":"a","type":1,"api":"https://a.example"}],"lives":[{"name":"直播","url":"${at("/live.txt")}","ua":"LIVE","epg":"${at("/epg")}?ch={name}&date={date}"},{"name":"包","type":3,"api":"csp_Live"}]}""", "") as ParsedConfig.Config).config
        engine.setRepos(listOf(RepoRuntime("r", "仓", c, true, false)), "r")
        val uid = TVBoxConfig.liveUid("r", at("/live.txt"))
        val d = engine.liveDetail(uid, emptySet())
        assertTrue(d.isLive); assertEquals(listOf("CCTV1"), d.episodes.map { it.title }); assertEquals("央视", d.episodes.single().page); assertEquals("tvl:$uid#0", d.episodes.single().vid); assertEquals("LIVE", seen.last { it.path == "/live.txt" }.getHeader("User-Agent"))
        assertEquals(listOf("CCTV1", "锁"), engine.liveDetail(uid, setOf("密")).episodes.map { it.title })
        val v = engine.resolveLive(d.episodes.single(), emptySet())
        assertEquals(listOf("主", "线路 2"), v.streams.map { it.quality }); assertEquals("LIVE", v.streams[0].headers["User-Agent"]); assertEquals("X", v.streams[1].headers["User-Agent"]); assertEquals("http://b.example/PLTV/2", v.streams[1].url)
        assertEquals(v.url, engine.resolveLive(HGEpisode(1, "tvl:$uid#0"), emptySet()).url)
        assertEquals("全天", engine.guide(uid, "CCTV1").single().title); assertEquals("CCTV1", seen.last { it.path!!.startsWith("/epg") }.requestUrl!!.queryParameter("ch"))
        val replay = engine.catchup(d.episodes.single(), Programme(1_767_225_600_000, 1_767_229_200_000, "p"))!!
        assertTrue(replay.streams.single().url.startsWith("http://b.example/TVOD/2?playseek="))
        assertEquals("频道", engine.liveDetail(TVBoxConfig.liveUid("r", "csp_Live "), emptySet()).episodes.single().title)
        assertEquals("http://127.0.0.1:${engine.proxyPort}/proxy?do=live&type=txt&ext=" + Bytes.b64(at("/live.txt").toByteArray()), VodMapper.localProxy("proxy://do=live&type=txt&ext=" + Bytes.b64(at("/live.txt").toByteArray()), engine.proxyPort, ""))
        assertTrue(URL("http://127.0.0.1:${engine.proxyPort}/proxy?do=live&type=txt&ext=" + java.net.URLEncoder.encode(Bytes.b64(at("/live.txt").toByteArray()), "UTF-8")).readText().contains("CCTV1"))
    }

    @Test fun jarParseExtensionsRunThroughTheChain() = runBlocking<Unit> {
        routes["/t4"] = { r -> json("""{"parse":1,"jx":1,"url":"https://v.qq.example/x.html"}""") }
        val u = use("""{"spider":"https://j.example/a.jar","sites":[{"key":"t","name":"T","type":4,"api":"${at("/t4")}"}],"parses":[{"name":"包","type":2,"url":"Demo"},{"name":"j1","type":1,"url":"https://none.invalid/?url="}]}""")["t"]!!
        val v = engine.resolve(HGEpisode(1, TVBoxId.episode(u, "x", 0, 0), media = """{"f":"qq","id":"5"}"""))
        assertEquals("https://ext.example/Demo.m3u8", v.url); assertEquals("j1", v.streams.single().headers["Referer"])
    }

    @Test fun bridgeRunsOnlyImportedAndTrustedJars() = runBlocking<Unit> {
        val config = """{"spider":"https://j.example/a.jar;md5;0cc175b9c0f1b6a831c399e269772661","sites":[{"key":"a","name":"甲","type":3,"api":"csp_A","ext":"E"}]}"""
        fun denied(api: String, jar: String, method: String = "homeContent") = assertThrows(BridgeTarget.Denied::class.java) { engine.call("a", api, "E", jar, method, JSONArray()) }.message!!
        use(config, trusted = false)
        assertTrue(denied("csp_A", "https://j.example/a.jar").contains("信任"))
        use(config)
        assertTrue(denied("csp_A", "https://evil.example/a.jar").contains("没有导入")); assertTrue(denied("csp_Other", "https://j.example/a.jar").contains("没有导入")); assertTrue(denied("csp_A", "https://j.example/a.jar", "destroy").contains("不支持"))
        assertEquals("E", JSONObject(engine.call("a", "csp_A", "E", "https://j.example/a.jar;md5;x", "homeContent", JSONArray().put(true))).getJSONArray("class").getJSONObject(0).getString("type_id"))
        assertEquals("other", JSONObject(engine.call("a", "csp_A", "other", "https://j.example/a.jar", "homeContent", JSONArray().put(true))).getJSONArray("class").getJSONObject(0).getString("type_id"))
        assertEquals("https://ext.example/K.m3u8", JSONObject(engine.call("", "", "", "https://j.example/a.jar", "jsonExt", JSONArray().put("K").put(JSONObject()).put("u"))).getString("url"))
    }

    @Test fun failuresReadAsOneChineseLine() {
        assertEquals("无法解析域名 cms.invalid", SpiderErrors.text(java.net.UnknownHostException("Unable to resolve host \"cms.invalid\": No address associated with hostname")))
        assertEquals("与当前版本不兼容：缺少类 Nothing", SpiderErrors.text(java.lang.reflect.InvocationTargetException(NoClassDefFoundError("com/github/catvod/bean/Nothing"))))
        assertTrue(SpiderErrors.text(NoSuchMethodError("No virtual method foo()V in class Lokhttp3/X;")).startsWith("与当前版本不兼容"))
        assertEquals("站点：x", SpiderErrors.text(RuntimeException(ProviderException("站点：x")))); assertEquals("网络超时", SpiderErrors.text(java.net.SocketTimeoutException("timeout")))
    }

    @Test fun latencyMeasurementsStream() = runBlocking<Unit> {
        routes["/t4"] = { json("""{"class":[{"type_id":"1","type_name":"类"}]}""") }
        val u = use("""{"sites":[{"key":"t","name":"T","type":4,"api":"${at("/t4")}"},{"key":"n","name":"N","type":4,"api":"${at("/none")}"}]}""")
        val m = engine.latencies(u.values.toList()).toList().toMap()
        assertTrue(m[u["t"]]!! > 0); assertEquals(-1L, m[u["n"]])
        val job = launch { engine.latencies(u.values.toList()).collect { throw CancellationException() } }
        job.join()
    }
}
