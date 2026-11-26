package app.iduanju.core.tvbox

import app.iduanju.core.util.Bytes
import app.iduanju.core.util.J
import app.iduanju.core.util.ProviderException
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

/** Background refreshes of downloads that are already in use: one at a time per address. */
object Refresher {
    private val running = ConcurrentHashMap.newKeySet<String>()
    private val pool = ThreadPoolExecutor(2, 2, 20, TimeUnit.SECONDS, LinkedBlockingQueue()) { r -> Thread(r, "tvbox-refresh").apply { isDaemon = true; priority = Thread.MIN_PRIORITY } }
        .apply { allowCoreThreadTimeOut(true) }

    fun run(key: String, block: () -> Unit) {
        if (running.add(key)) pool.execute { try { block() } catch (_: Throwable) { } finally { running.remove(key) } }
    }
}

/** Downloaded scripts on disk: a copy is used at once and refreshed behind it when it is old; a first download is shared by everyone asking for it. */
class ScriptCache(private val dir: File, private val freshMs: Long = 30 * 60_000L) {
    private val locks = ConcurrentHashMap<String, ReentrantLock>()

    fun load(url: String, http: TVBoxHttp, headers: Map<String, String> = emptyMap(), tag: Any? = null): String {
        if (TVBoxUrl.isLocal(url)) return TVBoxDecoder.text(http.execute(NetRequest(url, tag = tag)).body)
        val f = File(dir, Bytes.hex(Bytes.md5(url)))
        cached(f, url, http, headers)?.let { return it }
        val lock = locks.getOrPut(url) { ReentrantLock() }
        lock.lockInterruptibly()
        try { return cached(f, url, http, headers) ?: download(f, url, http, headers, tag) } finally { lock.unlock() }
    }

    private fun cached(f: File, url: String, http: TVBoxHttp, headers: Map<String, String>): String? {
        if (freshMs <= 0 || !f.isFile) return null
        val text = runCatching { f.readText() }.getOrNull() ?: return null
        // a server that is down is asked again only after another period
        if (System.currentTimeMillis() - f.lastModified() >= freshMs) Refresher.run("js|" + f.path) { try { download(f, url, http, headers, null) } catch (_: Exception) { f.setLastModified(System.currentTimeMillis()) } }
        return text
    }

    private fun download(f: File, url: String, http: TVBoxHttp, headers: Map<String, String>, tag: Any?): String {
        val text = http.text(url, headers, 20_000, tag)
        if (text.trimStart().startsWith("<!DOCTYPE", true) || text.trimStart().startsWith("<html", true)) throw IOException("脚本地址返回的是网页：${TVBoxUrl.fileName(url)}")
        dir.mkdirs()
        runCatching {
            val tmp = File(dir, f.name + "." + System.nanoTime() + ".tmp")
            tmp.writeText(text)
            try { Files.move(tmp.toPath(), f.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) } finally { tmp.delete() }
        }
        return text
    }

    fun clear() { dir.listFiles()?.forEach { it.delete() } }
}

/** ES-module loader of HOST_ABI.md: `assets://js/lib/…`, bare library names, http(s), relative to the importing module. */
class JsModules(private val asset: (String) -> String?, private val http: TVBoxHttp, private val cache: ScriptCache, private val entry: String, private val tag: Any) {
    private val libs = HashMap<String, String?>()
    private fun lib(name: String): String? = libs.getOrPut(name) { asset(name) }

    fun normalize(base: String, name: String): String = when {
        name == ENTRY -> name
        name.startsWith(LIB) -> name
        name.startsWith("assets://") -> LIB + name.substringAfterLast('/')
        TVBoxUrl.isHttp(name) || TVBoxUrl.isLocal(name) -> name
        !name.startsWith(".") && !name.startsWith("/") && lib(name) != null -> LIB + name
        base.startsWith(LIB) -> LIB + name.removePrefix("./").removePrefix("/")
        else -> TVBoxUrl.join(if (base.isEmpty() || base == ENTRY) entry else base, name)
    }

    fun load(name: String): String {
        if (name.startsWith(LIB)) return lib(name.substring(LIB.length)) ?: throw IOException("内置脚本库里没有 ${name.substring(LIB.length)}")
        val text = try { cache.load(name, http, tag = tag) } catch (e: IOException) {
            // a repository that forgot one of the well-known helper files still works with the bundled one
            lib(TVBoxUrl.decode(TVBoxUrl.fileName(name))) ?: throw IOException("无法下载脚本 ${TVBoxUrl.fileName(name)}：${SpiderErrors.text(e)}")
        }
        if (text.startsWith("//bb")) throw IOException("${TVBoxUrl.fileName(name)} 是 QuickJS 字节码（//bb），本机引擎无法加载")
        return if (name == entry) SPIDER_ID.replace(text, "globalThis.__JS_SPIDER__") else text
    }

    companion object {
        const val LIB = "assets://js/lib/"
        const val ENTRY = "idj-entry.js"
        private val SPIDER_ID = Regex("(?<![\\w.$])(?:globalThis\\.)?__JS_SPIDER__")
    }
}

/** One JavaScript context, confined to the thread that created it. Errors surface as exceptions with the script's message. */
interface JsEngine {
    /** Defines `globalThis.__tv(name, argsJson)`. */
    fun install(call: (String, String) -> String)
    fun modules(normalize: (base: String, name: String) -> String, load: (name: String) -> String)
    /** Evaluates a global script, drains the job queue, returns the completion value (strings only matter). */
    fun script(code: String, name: String): Any?
    fun module(code: String, name: String)
    fun close()
}

/** drpy / CatVod JavaScript spider driven through shared/tvbox/js/bootstrap.js. */
class JsSpider(private val site: TVBoxSite, private val engineFactory: () -> JsEngine, private val host: ScriptHost, private val modules: JsModules, private val bootstrap: String) : Spider {
    private lateinit var engine: JsEngine

    override fun init(ext: String) {
        engine = engineFactory()
        try {
            var failure: String? = null
            engine.install { name, args -> host.call(name, args) }
            engine.modules(modules::normalize) { name -> try { modules.load(name) } catch (e: Exception) { failure = SpiderErrors.text(e); throw e } }
            engine.script(bootstrap, "bootstrap.js")
            val api = JSONObject.quote(site.api)
            try { engine.module("import * as m from $api; __idj.attach(m);", JsModules.ENTRY) } catch (e: Exception) { throw ProviderException.unsupported("脚本加载失败：" + (failure ?: SpiderErrors.text(e))) }
            var status = J.parse(engine.script("__idj.status()", "status.js").toString())
            if (!J.bool(status.opt("ok")) && J.str(status.opt("e")).isEmpty()) {
                runCatching { engine.script("import($api).then(function (m) { __idj.attach(m); }).catch(__idj.fail)", "retry.js") }
                status = J.parse(engine.script("__idj.status()", "status.js").toString())
            }
            if (!J.bool(status.opt("ok"))) throw ProviderException.unsupported("脚本加载失败：" + (failure ?: J.str(status.opt("e")).ifEmpty { "模块执行出错" }))
            run("init", JSONArray().put(ext).put(site.key).put(site.type))
        } catch (e: Throwable) { engine.close(); throw e } finally { host.endCall() }
    }

    private fun run(method: String, args: JSONArray): String {
        try {
            engine.script("__idj.start(" + JSONObject.quote(method) + "," + literal(args.toString()) + ")", "call.js")
            while (true) {
                val s = J.parse(engine.script("__idj.poll()", "poll.js").toString())
                if (J.bool(s.opt("done"))) {
                    val e = J.str(s.opt("e"))
                    if (s.has("e")) throw ProviderException.unsupported(e.ifEmpty { "脚本出错" })
                    return (s.opt("v") as? String).orEmpty()
                }
                val wait = J.int64(s.opt("wait"))
                if (wait > 0) Thread.sleep(minOf(wait, 100)) else if (Thread.interrupted()) throw InterruptedException()
            }
        } finally { host.endCall() }
    }

    /** JSON text is a valid JS string literal once line separators are escaped. */
    private fun literal(s: String) = JSONObject.quote(s).replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")

    override fun homeContent(filter: Boolean) = run("homeContent", JSONArray().put(filter))
    override fun homeVideoContent() = run("homeVideoContent", JSONArray())
    override fun categoryContent(tid: String, pg: String, filter: Boolean, extend: Map<String, String>) = run("categoryContent", JSONArray().put(tid).put(pg).put(filter).put(JSONObject(extend as Map<*, *>)))
    override fun detailContent(ids: List<String>) = run("detailContent", JSONArray().put(JSONArray(ids)))
    override fun searchContent(key: String, quick: Boolean, pg: String) = run("searchContent", JSONArray().put(key).put(quick).put(pg))
    override fun playerContent(flag: String, id: String, vipFlags: List<String>) = run("playerContent", JSONArray().put(flag).put(id).put(JSONArray(vipFlags)))
    override fun liveContent(url: String) = run("liveContent", JSONArray().put(url))
    override fun proxyLocal(params: Map<String, String>) = ProxyReply.fromRunner(run("proxyLocal", JSONArray().put(JSONObject(params as Map<*, *>))))
    override fun action(action: String) = run("action", JSONArray().put(action))
    override fun isVideoFormat(url: String) = run("isVideoFormat", JSONArray().put(url)) == "true"
    override fun manualVideoCheck() = run("manualVideoCheck", JSONArray()) == "true"
    override fun interrupt() = onInterrupt()
    var onInterrupt: () -> Unit = {}

    override fun destroy() {
        if (!::engine.isInitialized) return
        runCatching { run("destroy", JSONArray()) }
        engine.close()
    }
}

/** Embedded Python behind shared/tvbox/py/idj_runner.py. */
interface PyEngine {
    fun load(key: String, source: String, ext: String, siteKey: String, url: String, host: ScriptHost)
    fun call(key: String, method: String, argsJson: String): String
    fun unload(key: String)
}

class PySpider(uid: String, private val site: TVBoxSite, private val engine: PyEngine, private val host: ScriptHost, private val source: () -> String, private val url: String) : Spider {
    /** Its own name in the interpreter: a predecessor of the same site that is closed late must not take this one with it. */
    private val key = uid + "#" + seq.incrementAndGet()

    override fun init(ext: String) = engine.load(key, source(), ext, site.key, url, host)

    private fun run(method: String, vararg args: Any): String = try { engine.call(key, method, JSONArray().apply { args.forEach { put(it) } }.toString()) } finally { host.endCall() }

    override fun homeContent(filter: Boolean) = run("homeContent", filter)
    override fun homeVideoContent() = run("homeVideoContent")
    override fun categoryContent(tid: String, pg: String, filter: Boolean, extend: Map<String, String>) = run("categoryContent", tid, pg, filter, JSONObject(extend as Map<*, *>))
    override fun detailContent(ids: List<String>) = run("detailContent", JSONArray(ids))
    override fun searchContent(key: String, quick: Boolean, pg: String) = run("searchContent", key, quick, pg)
    override fun playerContent(flag: String, id: String, vipFlags: List<String>) = run("playerContent", flag, id, JSONArray(vipFlags))
    override fun liveContent(url: String) = run("liveContent", url)
    override fun proxyLocal(params: Map<String, String>) = ProxyReply.fromRunner(run("proxyLocal", JSONObject(params as Map<*, *>)))
    override fun action(action: String) = run("action", action)
    override fun isVideoFormat(url: String) = run("isVideoFormat", url) == "true"
    override fun manualVideoCheck() = run("manualVideoCheck") == "true"
    override fun destroy() = engine.unload(key)
    override fun interrupt() = onInterrupt()
    var onInterrupt: () -> Unit = {}

    companion object {
        private val seq = java.util.concurrent.atomic.AtomicLong()

        /** `py_xxx` sites carry the script address in `ext`; otherwise `api` is the script and `ext` its parameter. */
        fun script(api: String, ext: String): Pair<String, String> =
            if (api.startsWith("py_") && !api.contains("/")) { if (ext.contains(".py")) ext to "" else throw ProviderException.invalid("$api 没有给出脚本地址（ext）") } else api to ext
    }
}
