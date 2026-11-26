package app.iduanju

import androidx.test.platform.app.InstrumentationRegistry
import app.iduanju.core.hongguo.HGEpisode
import app.iduanju.core.hongguo.HGStreamKind
import app.iduanju.core.tvbox.JsModules
import app.iduanju.core.tvbox.JsSpider
import app.iduanju.core.tvbox.ScriptCache
import app.iduanju.core.tvbox.ScriptHost
import app.iduanju.core.tvbox.ScriptStorage
import app.iduanju.core.tvbox.TVBoxHttp
import app.iduanju.core.tvbox.TVBoxId
import app.iduanju.core.tvbox.TVBoxSite
import app.iduanju.core.tvbox.Trust
import app.iduanju.core.util.Bytes
import app.iduanju.core.util.ProviderException
import app.iduanju.data.Catalog
import app.iduanju.tvbox.ImportResult
import app.iduanju.tvbox.TVBoxRepo
import app.iduanju.tvbox.runtime.PyRuntime
import app.iduanju.tvbox.runtime.QuickJsTvEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/** The Android-only halves of the TVBox engine on a real device: dex jars, QuickJS, WebView sniffing, Python, the proxy. */
class TVBoxRuntimeTest {
    private val inst = InstrumentationRegistry.getInstrumentation()
    private val store get() = IdjApp.instance.tvbox
    private val imported = ArrayList<String>()

    /** The test APK carries `com.github.catvod.spider.*` fixtures: it is the jar. */
    private val jarBytes by lazy { File(inst.context.packageCodePath).readBytes() }

    private fun <T> main(f: suspend () -> T): T = runBlocking { withContext(Dispatchers.Main) { f() } }

    private fun import(config: String, trust: Boolean = true, name: String = "demo-${System.nanoTime()}.json"): TVBoxRepo {
        val repo = main { (store.importLocal(config.toByteArray(), name) as ImportResult.Imported).repo }
        imported += repo.id
        if (trust) main { store.setTrust(repo.id, Trust.Trusted) }
        return store.repos.first { it.id == repo.id }
    }

    private fun jarConfig(extra: String = "", md5: String = ""): String {
        main { assertTrue(store.importLocal(jarBytes, "demo.jar") is ImportResult.Attachment) }
        return """{"spider":"./demo.jar$md5","sites":[{"key":"csp_demo","name":"演示","type":3,"api":"csp_Demo","ext":"E"}]$extra}"""
    }

    @After fun cleanup() { main { imported.forEach { store.remove(it) } } }

    @Test fun jarSpiderRunsFromAReadOnlyDex() {
        val repo = import(jarConfig(md5 = ";md5;" + Bytes.hex(Bytes.md5(jarBytes))))
        val uid = repo.sites.single().uid
        val home = runBlocking { store.engine.home(uid).toList().last().value }
        assertEquals("演示分类", home.categories.single().name)
        assertEquals("演示影片 Ecsp_demo", home.items[0].title); assertEquals("0cc1", home.items[0].remark); assertTrue(home.items[1].folder); assertEquals("cn", home.filters["1"]!!.single().options[1].second)
        val jars = File(inst.targetContext.filesDir, "tvbox/jar").listFiles()!!.filter { it.name.endsWith(".jar") }
        assertTrue(jars.isNotEmpty()); assertTrue(jars.none { it.canWrite() })
        // ids with slashes, queries and JSON survive the whole way
        val sid = home.items[0].sid
        assertEquals("""id/1?x=%20&y={"a":1}#z""", TVBoxId.parseVod(sid)!!.id)
        val d = Catalog.detail(sid)
        assertEquals(listOf("本地", "嗅探"), d.lines.map { it.name }); assertEquals(2, d.episodes.size)
        val v = Catalog.resolve(d.episodes[1])
        assertTrue(v.url!!, v.url!!.startsWith("http://127.0.0.1:") && v.url!!.endsWith("/proxy?do=video"))
        val c = URL(v.url).openConnection() as HttpURLConnection
        c.setRequestProperty("Range", "bytes=4-7")
        assertEquals(206, c.responseCode); assertEquals("ftyp", c.inputStream.readBytes().toString(Charsets.US_ASCII))
        assertEquals("csp:1", URL("http://127.0.0.1:${store.engine.runningPort}/proxy?do=csp&siteKey=csp_demo&a=1").readText())
        assertEquals("词", runBlocking { store.engine.search(uid, "词") }.items.single().title)
        val error = assertThrows(ProviderException::class.java) { runBlocking { store.engine.action(uid, "x") } }
        assertTrue(error.message!!, error.message!!.contains("缺少类 Nothing"))
        assertFalse(Catalog.isHongguo(sid))
    }

    @Test fun wrongMd5AndUntrustedConfigsAreRefused() {
        val bad = import(jarConfig(md5 = ";md5;00000000000000000000000000000000"))
        assertTrue(assertThrows(ProviderException::class.java) { runBlocking { store.engine.home(bad.sites.single().uid).toList() } }.message!!.contains("md5"))
        val untrusted = import(jarConfig(), trust = false)
        assertTrue(assertThrows(ProviderException::class.java) { runBlocking { store.engine.home(untrusted.sites.single().uid).toList() } }.message!!.contains("信任"))
        val missing = import(jarConfig().replace("csp_Demo", "csp_None"))
        assertTrue(assertThrows(ProviderException::class.java) { runBlocking { store.engine.home(missing.sites.single().uid).toList() } }.message!!.contains("没有 csp_None"))
    }

    @Test fun hiddenWebViewSniffsThePlayPage() {
        val repo = import(jarConfig())
        val uid = repo.sites.single().uid
        val v = Catalog.resolve(HGEpisode(1, TVBoxId.episode(uid, "x", 1, 0), media = """{"f":"嗅探","id":"page"}"""))
        assertEquals("https://media.invalid/path/stream.m3u8?sign=1", v.url); assertEquals(HGStreamKind.hls, v.streams.single().kind); assertTrue(v.streams.single().headers.containsKey("User-Agent"))
        val started = System.currentTimeMillis()
        val e = assertThrows(ProviderException::class.java) { Catalog.resolve(HGEpisode(1, TVBoxId.episode(uid, "x", 1, 0), media = """{"f":"嗅探","id":"empty"}""")) }
        assertTrue(e.message!!, e.message!!.contains("没有嗅探到")); assertTrue(System.currentTimeMillis() - started < 30_000)
    }

    /** The whole way through the app: a route with an awkward id, then the shared player on the jar's own proxy. */
    @Test fun episodePlaysInTheSharedPlayer() {
        val repo = import(jarConfig())
        val sid = TVBoxId.vod(repo.sites.single().uid, "id/1?x=%20&y={\"a\":1}#z")
        app.iduanju.ui.UiEvidence.playerPositionMs = 0
        app.iduanju.ui.UiEvidence.playerPlaying = false
        val intent = android.content.Intent(inst.targetContext, MainActivity::class.java).putExtra("route", "player/${android.net.Uri.encode(sid)}/1")
        androidx.test.core.app.ActivityScenario.launch<MainActivity>(intent).use {
            val deadline = System.currentTimeMillis() + 60_000
            while (System.currentTimeMillis() < deadline && app.iduanju.ui.UiEvidence.playerPositionMs <= 800) Thread.sleep(200)
            assertTrue("player position ${app.iduanju.ui.UiEvidence.playerPositionMs} ms", app.iduanju.ui.UiEvidence.playerPositionMs > 800)
        }
    }

    @Test fun jarParseExtensionsAnswer() {
        val repo = import(jarConfig(""","parses":[{"name":"扩展","type":2,"url":"Demo"},{"name":"j","type":1,"url":"https://none.invalid/?u="}]"""))
        main { store.setParse(repo.id, "扩展") }
        val r = store.repos.first { it.id == repo.id }
        assertEquals("扩展", r.record.parse)
        val out = store.engine.call("", "", "", "clan://localhost/demo.jar", "jsonExt", org.json.JSONArray().put("Demo").put(JSONObject().put("a", "b")).put("https://page.invalid/1"))
        assertEquals("https://media.invalid/1.m3u8", JSONObject(out).getString("url"))
    }

    private val memory = object : ScriptStorage {
        private val m = HashMap<String, String>()
        override fun get(ns: String, k: String) = m["$ns|$k"]
        override fun set(ns: String, k: String, v: String) { m["$ns|$k"] = v }
        override fun delete(ns: String, k: String) { m.remove("$ns|$k") }
    }

    private fun js(source: String, ext: String = ""): JsSpider {
        val api = "https://s.invalid/site.js"
        val cache = ScriptCache(File(inst.targetContext.cacheDir, "js-test-${System.nanoTime()}"), 0)
        val http = TVBoxHttp { r -> if (r.url == api) app.iduanju.core.tvbox.NetResponse(200, r.url, emptyMap(), source.toByteArray()) else if (r.url.endsWith("/page")) app.iduanju.core.tvbox.NetResponse(200, r.url, mapOf("Content-Type" to listOf("text/html; charset=utf-8")), "<ul><li><a href='/1'>一 😀</a></li></ul>".toByteArray()) else throw IOException("offline ${r.url}") }
        fun asset(n: String) = runCatching { inst.targetContext.assets.open("tvbox/js/$n").bufferedReader().use { it.readText() } }.getOrNull()
        val host = ScriptHost("js", http, memory, { 9978 })
        return JsSpider(TVBoxSite("js", "JS", 3, api, ext), { QuickJsTvEngine() }, host, JsModules({ asset("lib/$it") }, http, cache, api, host.tag), asset("bootstrap.js")!!).also { it.init(ext) }
    }

    @Test fun quickJsRunsModulesPromisesTimersAndUnicode() {
        val s = js("""
            import { load, _, Crypto, dayjs } from 'assets://js/lib/cat.js';
            import cheerio from 'cheerio.min.js';
            import 模板 from './模板.js';
            let cfg;
            async function init(c) { cfg = c; }
            async function home() {
              const r = await req('https://s.invalid/page');
              const ${'$'} = load(r.content);
              await new Promise(resolve => setTimeout(resolve, 30));
              return JSON.stringify({ ext: cfg.ext.a, key: cfg.skey, t: ${'$'}('li a').text(), h: ${'$'}('a').attr('href'), md5: Crypto.MD5('a').toString(), emoji: '😀中', jp: cheerio.jp('${'$'}.a[0].b', { a: [{ b: 7 }] }), j: cheerio.jinja2('{{x}}-{{y or 1}}', { x: 'é' }), m: !!模板.muban, e: _.first([3]), y: dayjs('2026-01-02').format('YYYY'), aes: aesX('AES/CBC/PKCS7', false, aesX('AES/CBC/PKCS7', true, '明文', false, '1234567812345678', '1234567812345678', true), true, '1234567812345678', '1234567812345678', false) });
            }
            async function category() { await new Promise(() => {}); }
            function detail() { throw new Error('出错😀'); }
            function proxy() { return [200, 'text/plain', '内容😀']; }
            export function __jsEvalReturn() { return { init, home, category, detail, proxy }; }
        """, """{"a":"值😀"}""")
        try {
            val h = JSONObject(s.homeContent(true))
            assertEquals("值😀", h.getString("ext")); assertEquals("一 😀", h.getString("t")); assertEquals("/1", h.getString("h")); assertEquals("0cc175b9c0f1b6a831c399e269772661", h.getString("md5")); assertEquals("😀中", h.getString("emoji"))
            assertEquals(7, h.getJSONArray("jp").getInt(0)); assertEquals("é-1", h.getString("j")); assertTrue(h.getBoolean("m")); assertEquals(3, h.getInt("e")); assertEquals("2026", h.getString("y")); assertEquals("明文", h.getString("aes"))
            assertTrue(assertThrows(ProviderException::class.java) { s.categoryContent("1", "1", true, emptyMap()) }.message!!.contains("没有返回结果"))
            assertTrue(assertThrows(ProviderException::class.java) { s.detailContent(listOf("1")) }.message!!.contains("出错"))
            assertEquals("内容😀", s.proxyLocal(emptyMap())!!.body.readBytes().toString(Charsets.UTF_8))
        } finally { s.destroy() }
    }

    @Test fun quickJsModuleFailuresAreReadable() {
        fun fails(src: String) = assertThrows(ProviderException::class.java) { js(src) }.message!!
        assertTrue(fails("import x from './missing.js'; export default {};"), fails("import x from './missing.js'; export default {};").contains("missing.js"))
        assertTrue(fails("throw new Error('炸了')"), fails("throw new Error('炸了')").contains("炸了"))
        assertTrue(fails("//bb00").contains("字节码"))
        assertTrue(fails("export default { home( }").contains("脚本加载失败"))
        assertTrue(fails("export const a = 1").contains("没有导出"))
        // drpy engines load their rule text with a direct eval that assigns a module variable
        val s = js("let rule = {}; function init(ext) { eval('(function(){' + ext.replace('var rule', 'rule') + '})()'); } export default { init, home: () => ({ list: [], t: rule.title }) }", "var rule = { title: '规则' }")
        assertEquals("规则", JSONObject(s.homeContent(true)).getString("t")); s.destroy()
    }

    @Test fun jsSiteThroughTheEngineWithEvalAndProxy() {
        main { store.importLocal("export default { home: () => ({ class: [{ type_id: 'x', type_name: '脚本类' }] }), play: (f, id) => ({ parse: 0, url: 'proxy://do=js&p=' + id }), proxy: p => [200, 'text/plain', 'JS' + p.p] }".toByteArray(), "demo.js") }
        val repo = import("""{"sites":[{"key":"js 站","name":"脚本","type":3,"api":"./demo.js"}]}""")
        val uid = repo.sites.single().uid
        assertEquals("脚本类", runBlocking { store.engine.home(uid).toList().last().value.categories.single().name })
        val v = Catalog.resolve(HGEpisode(1, TVBoxId.episode(uid, "x", 0, 0), media = """{"f":"f","id":"5"}"""))
        assertEquals("JS5", URL(v.url).readText())
    }

    @Test fun pythonSiteUsesTheRealPackages() {
        assumeTrue("build without -Pidj.python=true", PyRuntime.INCLUDED)
        main {
            store.importLocal("""
# -*- coding: utf-8 -*-
import sys
sys.path.append('..')
from base.spider import Spider
import requests, json
from lxml import etree
from bs4 import BeautifulSoup
from pyquery import PyQuery as pq
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad, unpad

class Spider(Spider):
    def init(self, extend=''):
        self.ext = extend
        self.setCache('k', {'n': 1})
    def homeContent(self, filter):
        key = b'1234567812345678'
        enc = AES.new(key, AES.MODE_CBC, key).encrypt(pad('明文'.encode(), 16))
        dec = unpad(AES.new(key, AES.MODE_CBC, key).decrypt(enc), 16).decode()
        root = self.html('<ul><li><a href="/1">一</a></li></ul>')
        return {'class': [{'type_id': '1', 'type_name': root.xpath('//a/text()')[0]}], 'list': [{'vod_id': root.xpath('//a/@href')[0], 'vod_name': dec + BeautifulSoup('<b>x</b>', 'html.parser').b.text + pq('<p>y</p>').text() + self.ext + str(self.getCache('k')['n'])}], 'v': requests.__version__}
    def playerContent(self, flag, id, vipFlags):
        return {'parse': 0, 'url': self.getProxyUrl() + '&p=' + id}
    def localProxy(self, param):
        return [200, 'text/plain', 'PY' + param['p'], {}]
    def searchContent(self, key, quick):
        return {'list': [{'vod_id': key, 'vod_name': key}]}
    def detailContent(self, ids):
        raise ValueError('坏了')
""".trim().toByteArray(), "demo.py")
        }
        val repo = import("""{"sites":[{"key":"py 站","name":"蟒","type":3,"api":"./demo.py","ext":"E"}]}""")
        val uid = repo.sites.single().uid
        val home = runBlocking { store.engine.home(uid).toList().last().value }
        assertEquals("一", home.categories.single().name); assertEquals("明文xyE1", home.items.single().title); assertEquals("/1", home.items.single().id)
        val v = Catalog.resolve(HGEpisode(1, TVBoxId.episode(uid, "x", 0, 0), media = """{"f":"f","id":"5"}"""))
        assertEquals("PY5", URL(v.url).readText())
        assertEquals("q", runBlocking { store.engine.search(uid, "q") }.items.single().title)
        val e = assertThrows(ProviderException::class.java) { runBlocking { store.engine.detail(uid, "1") } }
        assertTrue(e.message!!, e.message!!.contains("坏了") && e.message!!.contains("demo.py"))
    }

    @Test fun bridgeAnswersSignedCallsOnTheLan() {
        val repo = import(jarConfig())
        main { store.setBridge(true) }
        try {
            val deadline = System.currentTimeMillis() + 10_000
            while (System.currentTimeMillis() < deadline && store.bridgeAddress == null && store.bridgeError == null) Thread.sleep(50)
            val code = store.state.bridgeCode
            assertEquals(12, code.length)
            val body = JSONObject().put("siteKey", "csp_demo").put("api", "csp_Demo").put("ext", "E").put("jar", repo.config.spider).put("method", "playerContent").put("args", org.json.JSONArray().put("本地").put("video").put(org.json.JSONArray())).toString().toByteArray()
            fun call(sign: String, time: String, nonce: String): Pair<Int, JSONObject> {
                val c = URL("http://127.0.0.1:9979/bridge/call").openConnection() as HttpURLConnection
                c.doOutput = true
                c.setRequestProperty("X-Idj-Time", time); c.setRequestProperty("X-Idj-Nonce", nonce); c.setRequestProperty("X-Idj-Sign", sign)
                c.outputStream.use { it.write(body) }
                val status = c.responseCode
                return status to JSONObject((if (status < 400) c.inputStream else c.errorStream).bufferedReader().readText())
            }
            val t = (System.currentTimeMillis() / 1000).toString()
            val (ok, reply) = call(app.iduanju.core.tvbox.BridgeAuth.sign(code, t, "nonce-abc-1", body), t, "nonce-abc-1")
            assertEquals(200, ok)
            val url = JSONObject(reply.getString("v")).getString("url")
            assertTrue(url, url.startsWith("http://127.0.0.1:9979/bridge/proxy?do=video&idj_exp="))
            val v = URL(url).openConnection() as HttpURLConnection
            v.setRequestProperty("Range", "bytes=4-7")
            assertEquals("ftyp", v.inputStream.readBytes().toString(Charsets.US_ASCII))
            assertEquals(401, call("00".repeat(32), t, "nonce-abc-2").first)
        } finally { main { store.setBridge(false) } }
    }
}
