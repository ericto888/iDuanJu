package app.iduanju.core.tvbox

import app.iduanju.core.hls.HLSAdFilter
import app.iduanju.core.hongguo.HGEpisode
import app.iduanju.core.util.J
import app.iduanju.core.util.ProviderException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
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
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.net.HttpURLConnection
import java.net.Socket
import java.net.URI
import java.net.URL
import java.util.TimeZone
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** What sources, networks and users really do to the engine: half answers, cancellations, hostile addresses, broken numbers. */
class TVBoxRobustnessTest {
    @get:Rule val tmp = TemporaryFolder()
    private val server = MockWebServer()
    private val seen = CopyOnWriteArrayList<RecordedRequest>()
    private val routes = HashMap<String, (RecordedRequest) -> MockResponse>()
    private val engines = ArrayList<TVBoxEngine>()
    private val released = AtomicReference<Set<String>>()
    private lateinit var net: TVBoxNet

    private val jar = object : JarHost {
        override fun spider(http: TVBoxHttp, ref: SpiderRef, site: TVBoxSite): Spider = object : Spider { override fun homeContent(filter: Boolean) = """{"class":[{"type_id":"1","type_name":"类"}]}""" }
        override fun proxy(params: Map<String, String>): ProxyReply? = null
        override fun release(keep: Set<String>, run: Set<String>) { released.set(run) }
        override fun json(http: TVBoxHttp, ref: SpiderRef, key: String, jxs: LinkedHashMap<String, String>, url: String): JSONObject? = null
        override fun mix(http: TVBoxHttp, ref: SpiderRef, key: String, name: String, flag: String, jxs: LinkedHashMap<String, HashMap<String, String>>, url: String): JSONObject? = null
    }
    private val storage = object : ScriptStorage { override fun get(ns: String, k: String): String? = null; override fun set(ns: String, k: String, v: String) {}; override fun delete(ns: String, k: String) {} }

    @Before fun start() {
        server.dispatcher = object : Dispatcher() { override fun dispatch(request: RecordedRequest): MockResponse { seen += request; return routes[request.path!!.substringBefore('?')]?.invoke(request) ?: MockResponse().setResponseCode(404) } }
        server.start()
        net = TVBoxNet(tmp.newFolder("local")) { server.port }
    }

    @After fun stop() { engines.forEach { it.shutdown() }; server.shutdown() }

    private fun engine(cache: File = tmp.newFolder()) = TVBoxEngine(net, TVBoxPlatform(null, null, jar, { r -> SniffResult("https://sniff.example/v.m3u8", mapOf("Referer" to r.url)) }, { null }, storage), TVBoxCache(cache), tmp.newFolder(), tmp.newFolder()).also { engines += it }
    private fun at(path: String) = server.url(path).toString().replace("localhost", "127.0.0.1")
    private fun config(text: String) = (TVBoxConfig.parse(text, "https://h.example/c.json") as ParsedConfig.Config).config
    private fun TVBoxEngine.use(text: String, trusted: Boolean = true, lan: Boolean = false): Map<String, String> {
        val c = config(text)
        setRepos(listOf(RepoRuntime("r", "仓", c, trusted, lan)), "r")
        return c.sites.associate { it.key to TVBoxConfig.siteUid("r", it.key) }
    }
    private fun cms(uid: String, e: TVBoxEngine, url: String) = runBlocking { e.resolve(HGEpisode(1, TVBoxId.episode(uid, "x", 0, 0), media = JSONObject().put("f", "线").put("id", url).toString())) }

    // ------------------------------------------------------------------------------------------------------ cache

    @Test fun bigTextsAreNeverServedFromAnOldMemoryCopy() {
        val dir = tmp.newFolder()
        val big = "a".repeat(1 shl 20)
        TVBoxCache(dir).put("o", "k", big + "1")
        val c = TVBoxCache(dir)
        assertEquals('1', c.get("o", "k")!!.text.last())
        c.put("o", "k", big + "2")
        assertEquals('2', c.get("o", "k")!!.text.last())
        c.put("o", "k", "small"); assertEquals("small", c.get("o", "k")!!.text)
        c.put("o", "k", big + "3"); assertEquals('3', c.get("o", "k")!!.text.last())
    }

    @Test fun anOldLiveListIsRefreshedOnceForAllItsRows() = runBlocking<Unit> {
        val body = (1..30_000).joinToString("\n", "央视,#genre#\n") { "频道$it,http://a.example/$it.m3u8?padding=0123456789" }
        routes["/live.txt"] = { MockResponse().setBody(body) }
        val cache = tmp.newFolder()
        val text = """{"lives":[{"name":"直播","url":"${at("/live.txt")}"}],"sites":[]}"""
        val uid = TVBoxConfig.liveUid("r", at("/live.txt"))
        engine(cache).let { it.use(text); it.liveList(uid) }
        cache.walkTopDown().filter { it.isFile }.forEach { it.setLastModified(System.currentTimeMillis() - 600_000) }
        seen.clear()
        val e = engine(cache).also { it.use(text) }
        repeat(6) { assertEquals(30_000, e.liveList(uid).list.channels.size) }
        delay(800)
        assertEquals(1, seen.size)
    }

    @Test fun anEmptyRefreshKeepsWhatIsShown() = runBlocking<Unit> {
        var blank = false
        routes["/cms"] = { MockResponse().setBody(if (blank) "{}" else """{"class":[{"type_id":"1","type_name":"电影"}],"list":[{"vod_id":"1","vod_name":"片"}]}""") }
        val e = engine()
        val uid = e.use("""{"sites":[{"key":"a","name":"A","type":1,"api":"${at("/cms")}"}]}""")["a"]!!
        // the categories are there before the pictures of the second call are
        val first = e.home(uid).toList()
        assertEquals(listOf(false, true), first.map { it.fresh }); assertEquals(listOf(0, 1), first.map { it.value.items.size }); assertEquals("电影", first[0].value.categories.single().name)
        blank = true
        val again = e.home(uid, force = true).toList()
        assertEquals(listOf(1, 1), again.map { it.value.categories.size }); assertTrue(again.last().fresh); assertNotNull(again.last().error)
    }

    // ------------------------------------------------------------------------------------------------------ sessions

    private fun slowFirst(n: AtomicInteger) = SpiderSession("测", 45_000) {
        if (n.incrementAndGet() == 1) try { Thread.sleep(2000) } catch (e: InterruptedException) { throw ProviderException.upstream("下载失败：" + InterruptedIOException("interrupted").message) }
        object : Spider { override fun homeContent(filter: Boolean) = "ok" }
    }

    @Test fun aCancelledInitialisationIsNotHeldAgainstTheSite() = runBlocking<Unit> {
        val n = AtomicInteger()
        val s = slowFirst(n)
        val a = launch(Dispatchers.Default) { s.call(5000, "搜索") { it.homeContent(true) } }
        delay(150)
        val b = async(Dispatchers.Default) { s.call(5000, "首页") { it.homeContent(true) } }
        delay(100); a.cancelAndJoin()
        assertEquals("ok", b.await()); assertEquals("ok", s.call(5000, "首页") { it.homeContent(true) }); assertEquals(2, n.get())
        s.close()
    }

    @Test fun anInitialisationThatIsNoLongerWantedIsAborted() = runBlocking<Unit> {
        val aborted = CountDownLatch(1)
        val s = SpiderSession("测", 45_000) { onAbort -> onAbort { aborted.countDown() }; Thread.sleep(3000); object : Spider {} }
        val a = launch(Dispatchers.Default) { s.call(5000, "首页") { "x" } }
        delay(150); a.cancelAndJoin()
        assertEquals(0L, aborted.count); s.close()
    }

    @Test fun closingWhileASpiderIsCreatedStillDestroysIt() = runBlocking<Unit> {
        val destroyed = AtomicInteger()
        val s = SpiderSession("测", 45_000) { try { Thread.sleep(400) } catch (_: InterruptedException) { }; object : Spider { override fun destroy() { destroyed.incrementAndGet() } } }
        val j = launch(Dispatchers.Default) { runCatching { s.call(5000, "首页") { "x" } } }
        delay(100); s.close(); j.join()
        withTimeout(3000) { while (destroyed.get() == 0) delay(20) }
        // given up on: released by its own thread once that unwinds
        val stuck = SpiderSession("死", 1000) { object : Spider { override fun homeContent(filter: Boolean): String { val end = System.currentTimeMillis() + 4500; while (System.currentTimeMillis() < end) { try { Thread.sleep(50) } catch (_: InterruptedException) { } }; return "" }; override fun destroy() { destroyed.incrementAndGet() } } }
        assertThrows(SpiderTimeout::class.java) { runBlocking { stuck.call(100, "首页") { it.homeContent(true) } } }
        withTimeout(8000) { while (destroyed.get() < 2) delay(50) }
        assertTrue(stuck.dead)
    }

    @Test fun slowCmsCallsDoNotQueueBehindEachOther() = runBlocking<Unit> {
        routes["/cms"] = { Thread.sleep(700); MockResponse().setBody("""{"list":[{"vod_id":"1","vod_name":"片"}]}""") }
        val e = engine()
        val uid = e.use("""{"sites":[{"key":"a","name":"A","type":1,"api":"${at("/cms")}"}]}""")["a"]!!
        val t = System.currentTimeMillis()
        (1..3).map { async { e.search(uid, "词$it") } }.awaitAll()
        assertTrue((System.currentTimeMillis() - t).toString(), System.currentTimeMillis() - t < 1600)
    }

    @Test fun aPythonSpiderClosedLateDoesNotTakeItsSuccessorWithIt() {
        val loaded = LinkedHashSet<String>()
        val py = object : PyEngine {
            override fun load(key: String, source: String, ext: String, siteKey: String, url: String, host: ScriptHost) { loaded += key }
            override fun call(key: String, method: String, argsJson: String) = if (key in loaded) "ok" else throw ProviderException.unsupported("脚本还没有加载")
            override fun unload(key: String) { loaded -= key }
        }
        val site = TVBoxSite("p", "蟒", 3, "https://p.example/a.py")
        fun spider() = PySpider("uid", site, py, ScriptHost("p", { throw IOException() }, storage, { 0 }), { "" }, site.api).also { it.init("") }
        val old = spider(); val fresh = spider()
        old.destroy()
        assertEquals("ok", fresh.homeContent(true))
    }

    @Test fun revokedTrustForgetsTheLoadedJar() = runBlocking<Unit> {
        val e = engine()
        val text = """{"spider":"https://j.example/a.jar","sites":[{"key":"a","name":"甲","type":3,"api":"csp_A"}]}"""
        val uid = e.use(text)["a"]!!
        e.home(uid).toList()
        e.use(text, trusted = false)
        withTimeout(3000) { while (released.get() == null) delay(20) }
        assertTrue(released.get().isEmpty())
        e.use(text)
        withTimeout(3000) { while (released.get().isEmpty()) delay(20) }
        assertEquals(setOf(SpiderRef.parse("https://j.example/a.jar").id), released.get())
    }

    // ------------------------------------------------------------------------------------------------------ addresses

    @Test fun onlyNetworkAddressesMakeAConfigPrivate() {
        assertFalse(TVBoxNet.isPrivateAddress("clan://localhost/paste-abc.json")); assertFalse(TVBoxNet.isPrivateAddress("file:///sdcard/a.json")); assertFalse(TVBoxNet.isPrivateAddress(""))
        assertTrue(TVBoxNet.isPrivateAddress("http://nas.local/c.json")); assertTrue(TVBoxNet.isPrivateAddress("http://10.0.0.2/c.json"))
    }

    @Test fun t4ParametersAreNeverReadFromThisDevice() {
        File(tmp.root, "local/tv.json").writeText("SECRET")
        val sent = ArrayList<String>()
        val scope = net.Scope(NetRules())
        val http = object : TVBoxHttp { override fun execute(r: NetRequest): NetResponse { sent += r.url; return if (r.url.startsWith("http://127")) scope.execute(r) else NetResponse(200, r.url, emptyMap(), "{}".toByteArray()) } }
        routes["/file/tv.json"] = { MockResponse().setBody("SECRET") }
        fun home(ext: String) { sent.clear(); RemoteSpider(TVBoxSite("k", "n", 4, "https://remote.example/t4"), http).also { it.init(ext) }.homeContent(true) }
        home(at("/file/tv.json"))
        assertTrue(sent.last(), sent.last().startsWith("https://remote.example/t4") && !sent.last().contains("SECRET")); assertTrue(seen.isEmpty())
        // … nor through a redirect
        routes["/hop"] = { MockResponse().setResponseCode(302).setHeader("Location", at("/file/tv.json")) }
        assertThrows(IOException::class.java) { scope.execute(NetRequest(at("/hop"), loopback = false)) }
        assertTrue(scope.execute(NetRequest(at("/hop"))).text() == "SECRET")
        // an imported config keeps the address of its file, not the content, when the server is elsewhere
        home("clan://localhost/tv.json")
        assertTrue(sent.single().contains("clan") && !sent.single().contains("SECRET"))
    }

    @Test fun onlyAnImportedConfigWithAServerOnThisDeviceReadsItsOwnFiles() = runBlocking<Unit> {
        File(tmp.root, "local/p.json").writeText("PARAMS")
        val extend = AtomicReference<String?>()
        routes["/t4"] = { r -> extend.set(r.requestUrl!!.queryParameter("extend")); MockResponse().setBody("""{"class":[{"type_id":"1","type_name":"类"}]}""") }
        routes["/ext"] = { MockResponse().setBody("PARAMS") }
        fun home(ext: String, local: Boolean) = runBlocking {
            val c = config("""{"sites":[{"key":"t","name":"T","type":4,"api":"${at("/t4")}","ext":"$ext"}]}""")
            engine().run { setRepos(listOf(RepoRuntime("r", "仓", c, true, false, local = local)), "r"); home(TVBoxConfig.siteUid("r", "t")).toList() }
            extend.get()
        }
        assertEquals(at("/ext"), home(at("/ext"), false)); assertEquals("PARAMS", home(at("/ext"), true))
        assertEquals("clan://localhost/p.json", home("clan://localhost/p.json", false))
    }

    @Test fun abortedT4ParametersAreAskedForAgain() {
        val n = AtomicInteger()
        lateinit var spider: RemoteSpider
        val http = TVBoxHttp { r -> if (r.url.endsWith("/ext") && n.incrementAndGet() == 1) { spider.interrupt(); throw IOException("Canceled") } else NetResponse(200, r.url, emptyMap(), (if (r.url.endsWith("/ext")) "PARAMS" else r.url).toByteArray()) }
        spider = RemoteSpider(TVBoxSite("k", "n", 4, "https://remote.example/t4"), http)
        assertThrows(IOException::class.java) { spider.init("https://remote.example/ext") }
        spider.init("https://remote.example/ext")
        assertTrue(spider.homeContent(true).contains("extend=PARAMS"))
        // a server that simply fails: the address itself is the parameter, as before
        val down = RemoteSpider(TVBoxSite("k", "n", 4, "https://remote.example/t4"), { r -> if (r.url.endsWith("/ext")) throw IOException("HTTP 500") else NetResponse(200, r.url, emptyMap(), r.url.toByteArray()) })
        down.init("https://remote.example/ext")
        assertTrue(down.homeContent(true).contains("extend=https"))
    }

    @Test fun playersNeverReachTheLocalNetworkUnasked() = runBlocking<Unit> {
        val list = AtomicReference("[]")
        routes["/t4"] = { MockResponse().setBody("""{"parse":0,"url":${list.get()},"danmaku":"http://192.168.1.9/d.xml","subs":[{"name":"a","url":"http://10.0.0.3/a.srt"},{"name":"b","url":"https://s.example/b.srt"}]}""") }
        val text = """{"sites":[{"key":"t","name":"T","type":4,"api":"${at("/t4")}"}]}"""
        val e = engine()
        val uid = e.use(text)["t"]!!
        for (bad in listOf("http://192.168.1.1/reboot.m3u8", "http://[fe80::1]/x.mp4", "rtsp://10.0.0.8/live", "udp://@239.0.0.1:1234", "http://nas.local/a.mp4")) {
            list.set("""["$bad"]""")
            assertEquals(bad, TVBoxEngine.LAN_REFUSED, assertThrows(bad, ProviderException::class.java) { cms(uid, e, "1") }.message)
        }
        for (bad in listOf("http://127.0.0.1:1/x.m3u8", "http://localhost:8080/x.mp4", "file:///data/data/app/x.mp4", "content://x/y", "/data/x.mp4")) { list.set("""["$bad"]"""); assertThrows(bad, ProviderException::class.java) { cms(uid, e, "1") } }
        list.set("""["内网","http://192.168.1.1/a.mp4","公网","https://v.example/a.mp4"]""")
        val v = cms(uid, e, "1")
        assertEquals(listOf("公网"), v.streams.map { it.quality }); assertFalse(v.streams.single().lan); assertNull(v.danmaku); assertEquals(listOf("https://s.example/b.srt"), v.streams.single().subtitles.map { it.url })
        val own = "http://127.0.0.1:${e.proxyPort}/proxy?do=t4&x=1"
        list.set("""["$own"]""")
        assertEquals(own, cms(uid, e, "1").url)
        e.use(text, lan = true)
        list.set("""["http://192.168.1.1/a.mp4"]""")
        cms(uid, e, "1").let { assertTrue(it.streams.single().lan); assertNotNull(it.danmaku); assertEquals(2, it.streams.single().subtitles.size) }
        assertThrows(ProviderException::class.java) { list.set("""["http://127.0.0.1:1/x.mp4"]"""); cms(uid, e, "1") }
    }

    @Test fun playAddressesKeepTheirCharacters() {
        assertEquals(TVBoxUrl.Stream("https://h.example/a.m3u8?sig=a\$b|c", emptyMap(), ""), TVBoxUrl.vod("https://h.example/a.m3u8?sig=a\$b|c"))
        assertEquals(TVBoxUrl.Stream("https://h.example/a|b.mp4", mapOf("User-Agent" to "X|Y", "Referer" to "https://r.example/"), ""), TVBoxUrl.vod("https://h.example/a|b.mp4|User-Agent=X|Y&Referer=https%3A%2F%2Fr.example%2F"))
        assertEquals("线", TVBoxUrl.stream("http://h.example/1|ua=U\$线").label)
    }

    @Test fun channelsAreFoundByNameBeforeNumber() {
        fun ep(n: Int, group: String, name: String, url: String) = HGEpisode(n, "tvl:x#${n - 1}", title = name, page = group, media = """{"urls":["$url"]}""")
        val list = listOf(ep(1, "新", "临时", "u0"), ep(2, "央视", "CCTV1", "u1"), ep(3, "卫视", "CCTV1", "u2"), ep(4, "卫视", "湖南", "u3"))
        assertEquals(1, LiveKey(1, "央视", "CCTV1", "u1").find(list)) // a channel was inserted in front
        assertEquals(2, LiveKey(1, "卫视", "CCTV1").find(list)); assertEquals(3, LiveKey(1, "改名的组", "湖南").find(list)); assertEquals(2, LiveKey(9, "", "CCTV1", "u2").find(list))
        assertEquals(2, LiveKey(3, "", "CCTV1").find(list)); assertEquals(0, LiveKey(1, "央视", "没有了").find(list)); assertEquals(3, LiveKey(4, "", "").find(list)); assertEquals(-1, LiveKey(9, "", "").find(list))
    }

    // ------------------------------------------------------------------------------------------------------ server

    @Test fun aBrokenReplyOrBodyOnlyEndsItsConnection() {
        val uncaught = AtomicReference<Throwable>()
        val old = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { _, e -> uncaught.set(e) }
        val local = LocalServer("t", true, 19_900..19_930) { r -> if (r.path == "/bad") ProxyReply(200, "video/mp2t", object : InputStream() { override fun read(): Int = throw NullPointerException("Inflater has been closed") }) else ProxyReply.text("ok" + r.body.size) }
        val open = LocalServer("b", false, 19_931..19_960) { ProxyReply.text("ok" + it.body.size) }
        try {
            val p = local.start()
            runCatching { URL("http://127.0.0.1:$p/bad").readText() }
            assertEquals("ok0", URL("http://127.0.0.1:$p/").readText()); assertNull(uncaught.get())
            fun post(port: Int, size: Int) = (URL("http://127.0.0.1:$port/").openConnection() as HttpURLConnection).run { doOutput = true; outputStream.use { it.write(ByteArray(size)) }; inputStream.bufferedReader().readText() }
            assertEquals("ok100000", post(p, 100_000)); assertThrows(IOException::class.java) { post(p, 300_000) }
            val q = open.start()
            assertEquals("ok3000000", post(q, 3_000_000))
            // announced, never sent: a handful may wait, the rest is turned away
            val waiting = (1..4).map { Socket("127.0.0.1", q).apply { getOutputStream().run { write("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 4000000\r\n\r\n".toByteArray()); flush() } } }
            Thread.sleep(300)
            Socket("127.0.0.1", q).use { s -> s.soTimeout = 3000; s.getOutputStream().run { write("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 4000000\r\n\r\n".toByteArray()); flush() }; assertEquals(-1, s.getInputStream().read()) }
            waiting.forEach { it.close() }
        } finally { Thread.setDefaultUncaughtExceptionHandler(old); local.stop(); open.stop() }
    }

    // ------------------------------------------------------------------------------------------------------ scripts

    @Test fun scriptsAreDownloadedOnceAndRefreshedBehindTheirUse() {
        val dir = tmp.newFolder()
        val n = AtomicInteger()
        val down = java.util.concurrent.atomic.AtomicBoolean()
        val http = TVBoxHttp { r -> Thread.sleep(50); if (down.get()) throw IOException("down"); NetResponse(200, r.url, emptyMap(), ("v" + n.incrementAndGet()).toByteArray()) }
        val cache = ScriptCache(dir)
        val pool = Executors.newFixedThreadPool(12)
        val all = (1..12).map { pool.submit<String> { cache.load("https://h.example/drpy2.min.js", http) } }.map { it.get() }
        assertEquals(setOf("v1"), all.toSet()); assertEquals(1, n.get())
        fun age() = dir.listFiles()!!.single().setLastModified(System.currentTimeMillis() - 3_600_000)
        age()
        assertEquals("v1", cache.load("https://h.example/drpy2.min.js", http))
        val end = System.currentTimeMillis() + 3000
        while (n.get() < 2 && System.currentTimeMillis() < end) Thread.sleep(20)
        Thread.sleep(100)
        assertEquals("v2", cache.load("https://h.example/drpy2.min.js", http)); assertEquals(2, n.get())
        down.set(true); age()
        assertEquals("v2", cache.load("https://h.example/drpy2.min.js", http))
        Thread.sleep(300)
        // not asked again for a while
        assertTrue(System.currentTimeMillis() - dir.listFiles()!!.single().lastModified() < 60_000)
        pool.shutdown()
        assertThrows(IOException::class.java) { cache.load("https://h.example/other.js", http) }
    }

    // ------------------------------------------------------------------------------------------------------ guides

    private val zone = TimeZone.getTimeZone("Asia/Shanghai")
    private fun guide(now: Long): String {
        val f = java.text.SimpleDateFormat("yyyyMMddHHmmss Z", java.util.Locale.US).apply { timeZone = zone }
        return """<?xml version="1.0"?><tv><channel id="1"><display-name>CCTV1</display-name></channel><programme start="${f.format(java.util.Date(now - 600_000))}" stop="${f.format(java.util.Date(now + 600_000))}" channel="1"><title>朝闻</title><desc>${"长".repeat(500)}</desc></programme></tv>"""
    }

    @Test fun aFailedGuideDownloadNeitherHidesNorReplacesTheGuide() = runBlocking<Unit> {
        val dir = tmp.newFolder()
        val now = System.currentTimeMillis()
        val answers = AtomicReference("<!DOCTYPE html><html><body>登录</body></html>")
        val n = AtomicInteger()
        val http = TVBoxHttp { r -> n.incrementAndGet(); if (answers.get() == "down") throw IOException("down"); NetResponse(if (answers.get() == "404") 404 else 200, r.url, emptyMap(), answers.get().toByteArray()) }
        val ch = LiveChannel("CCTV1", emptyList())
        suspend fun ask(s: EpgService) = s.programmes(http, "https://e.example/e.xml", ch, setOf("cctv1"), now, zone).map { it.title }
        for (bad in listOf("<!DOCTYPE html><html><body>登录</body></html>", "404", "down", "{\"code\":1}")) {
            answers.set(bad); n.set(0)
            val s = EpgService(dir)
            assertEquals(emptyList<String>(), ask(s)); assertEquals(emptyList<String>(), ask(s))
            assertEquals(bad, 1, n.get()) // once, not per channel
            assertTrue(bad, dir.listFiles().orEmpty().isEmpty())
        }
        answers.set(guide(now))
        assertEquals(listOf("朝闻"), ask(EpgService(dir)))
        val f = dir.listFiles()!!.single()
        f.setLastModified(now - 24 * 3_600_000)
        answers.set("<html>维护中</html>")
        assertEquals(listOf("朝闻"), ask(EpgService(dir))); assertTrue(f.readText().contains("<tv>"))
    }

    @Test fun brokenGuidesCountAsFarAsTheyGo() {
        val now = System.currentTimeMillis()
        val cut = guide(now).substringBefore("</tv>") + "<programme start=\"x\" stop=\"99999999999999 +9999\" channel=\"1\"><title>a</title></programme><programme><title>b<c></title>"
        assertEquals(listOf("朝闻"), EpgParser.xmltv(cut.byteInputStream(), null, now - 86_400_000, now + 86_400_000, zone)["cctv1"]!!.map { it.title })
        assertTrue(EpgParser.xmltv("<html><br></html>".byteInputStream(), null, 0, Long.MAX_VALUE, zone).isEmpty()); assertTrue(EpgParser.xmltv(ByteArray(0).inputStream(), null, 0, Long.MAX_VALUE, zone).isEmpty())
        val json = """{"epg_data":[{"title":"坏","start":9223372036854775807,"end":9223372036854775807},{"title":"坏","start":"NaN","end":"1e300"},{"title":"坏","start":"99:99","end":null},{"title":"好","start":"08:00","end":"09:00"},{"title":"坏","start":-1,"end":Infinity}]}"""
        assertEquals(listOf("好"), EpgParser.json(json, "2026-11-25", zone).map { it.title }.filter { it == "好" }); assertTrue(EpgParser.json(json, "2026-11-25", zone).all { it.start > 0 && it.end > it.start })
    }

    // ------------------------------------------------------------------------------------------------------ numbers and patterns

    @Test fun absurdNumbersNeverThrow() {
        val o = LenientJson.parse("""{"a":Infinity,"b":-Infinity,"c":NaN,"d":1e300,"e":1e999,"f":-1e999,"g":99999999999999999999999,"h":0x7fffffffffffffffff,"i":.,"j":"NaN","k":"1e300","timeout":1e300,"pagecount":1e300,"page":NaN}""") as JSONObject
        for (k in o.keys()) { val v = o.opt(k); J.str(v); J.int(v); J.int64(v); J.double(v); J.bool(v) }
        assertNotNull(o.toString())
        val site = config("""{"sites":[{"key":"a","name":"A","type":1,"api":"https://a.example","timeout":1e300},{"key":"b","name":"B","type":1,"api":"https://b.example","timeout":-Infinity}]}""").sites
        assertEquals(listOf(60_000L, TVBoxSite.DEFAULT_TIMEOUT_MS), site.map { it.timeoutMs })
        val page = VodMapper.page(VodMapper.root("""{"pagecount":1e300,"style":{"ratio":Infinity},"list":[{"vod_id":1e300,"vod_name":"片","style":{"ratio":NaN}},{"vod_id":Infinity,"vod_name":"片"}]}""", "分类"), "u", 1) { it }
        assertEquals(2, page.items.size); assertTrue(page.hasMore)
        assertEquals(7, LiveParser.parse("#EXTM3U\n#EXTINF:-1 catchup=\"append\" catchup-source=\"?x\" catchup-days=\"7\",A\nhttp://a.example/1").channels.single().second.catchup!!.days)
        for (d in listOf("Infinity", "NaN", "1e300", "x")) LiveParser.parse("#EXTM3U\n#EXTINF:-1 catchup=\"append\" catchup-source=\"?x\" catchup-days=\"$d\",A\nhttp://a.example/1").channels.single()
        val hls = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:Infinity,\n#EXT-X-BYTERANGE:99999999999999999999@-1\na.ts\n#EXTINF:NaN,\n#EXT-X-BYTERANGE:x@y\nb.ts\n#EXTINF:1e300,\nc.ts\n#EXTINF:-5,\nd.ts\n#EXT-X-ENDLIST"
        assertTrue(HLSAdFilter.filter(hls, URI("https://h.example/v/i.m3u8")).text.contains("a.ts"))
    }

    @Test fun rulePatternsAreCompiledOnceAndBadOnesIgnored() {
        val ads = (1..500).map { "ad$it\\.example" } + "["
        assertTrue(SniffRules.isAd("ad7.example", ads)); assertFalse(SniffRules.isAd("media.example", ads))
        val rules = listOf(TVBoxRule("r", listOf("page.example"), listOf("[", "/play/\\d+"), listOf("(", "ad\\d"), emptyList()))
        assertTrue(SniffRules.isVideo("https://cdn.example/play/12", "https://page.example/1", rules)); assertFalse(SniffRules.isVideo("https://cdn.example/play/12?ad1", "https://page.example/1", rules))
        // a page asks for hundreds of things
        val t = System.nanoTime()
        repeat(2_000) { SniffRules.isAd("media.example", ads) }
        assertTrue(((System.nanoTime() - t) / 1_000_000).toString(), System.nanoTime() - t < 4_000_000_000)
    }
}
