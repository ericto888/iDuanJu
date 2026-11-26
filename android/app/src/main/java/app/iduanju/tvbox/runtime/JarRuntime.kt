package app.iduanju.tvbox.runtime

import android.content.Context
import app.iduanju.core.tvbox.JarHost
import app.iduanju.core.tvbox.NetRequest
import app.iduanju.core.tvbox.ProxyReply
import app.iduanju.core.tvbox.Refresher
import app.iduanju.core.tvbox.SpiderErrors
import app.iduanju.core.tvbox.SpiderRef
import app.iduanju.core.tvbox.TVBoxDecoder
import app.iduanju.core.tvbox.TVBoxHttp
import app.iduanju.core.tvbox.TVBoxSite
import app.iduanju.core.tvbox.TVBoxUrl
import app.iduanju.core.tvbox.text
import app.iduanju.core.util.Bytes
import app.iduanju.core.util.ProviderException
import com.github.catvod.crawler.Spider
import dalvik.system.DexClassLoader
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.lang.reflect.Method
import java.util.concurrent.ConcurrentHashMap

/**
 * Loads CatVod jars (dex) and runs their spiders. One class loader per jar; the app loader is the parent, so `crawler.*`,
 * gson, okhttp and jsoup come from the app, while helper packages a jar ships itself keep priority. Jars are only ever asked
 * for by [app.iduanju.core.tvbox.TVBoxEngine], which checks the config's trust first.
 */
class JarRuntime(private val ctx: Context) : JarHost {
    private val dir = File(ctx.filesDir, "tvbox/jar")
    private val loaded = ConcurrentHashMap<String, Loaded>()
    private val locks = ConcurrentHashMap<String, Any>()
    private val stale = ConcurrentHashMap.newKeySet<String>()

    private class Loaded(val loader: ClassLoader, val file: File, val proxy: Method?)

    /** Helper packages published jars bundle (unshaded builds): their own copy matches the code it was compiled with. */
    private class JarLoader(path: String, opt: String, parent: ClassLoader) : DexClassLoader(path, opt, null, parent) {
        override fun loadClass(name: String, resolve: Boolean): Class<*> {
            if (OWN.any { name.startsWith(it) }) {
                synchronized(this) {
                    findLoadedClass(name)?.let { return it }
                    try { return findClass(name) } catch (_: ClassNotFoundException) {}
                }
            }
            return super.loadClass(name, resolve)
        }

        companion object { private val OWN = listOf("com.github.catvod.net.", "com.github.catvod.utils.", "com.github.catvod.bean.", "com.github.catvod.spider.", "com.github.catvod.parser.") }
    }

    /** A refreshed config re-downloads its jar on next use (unless its md5 still matches). */
    fun invalidate() { stale.addAll(loaded.keys) }

    private fun load(http: TVBoxHttp, ref: SpiderRef): Loaded {
        loaded[ref.id]?.let { if (ref.id !in stale) return it }
        synchronized(locks.getOrPut(ref.id) { Any() }) {
            val old = loaded[ref.id]
            if (old != null && ref.id !in stale) return old
            val file = file(http, ref, forced = ref.id in stale)
            stale.remove(ref.id)
            if (old != null && old.file == file) return old
            val loader = JarLoader(file.path, ctx.codeCacheDir.path, JarRuntime::class.java.classLoader!!)
            Thread.currentThread().contextClassLoader = loader
            try { loader.loadClass("com.github.catvod.spider.Init").getMethod("init", Context::class.java).invoke(null, ctx) } catch (_: ClassNotFoundException) {} catch (_: NoSuchMethodException) {} catch (e: Throwable) { android.util.Log.w(TAG, "jar init failed: ${SpiderErrors.text(e)}", e) }
            val proxy = try { loader.loadClass("com.github.catvod.spider.Proxy").getMethod("proxy", Map::class.java) } catch (_: Throwable) { null }
            return Loaded(loader, file, proxy).also { loaded[ref.id] = it }
        }
    }

    /**
     * Cached by address and content; verified against the config's md5 whenever one is given. A copy is used at once and, when
     * it is old, refreshed behind it for the next start; an explicit refresh ([forced]) waits for the new one.
     */
    private fun file(http: TVBoxHttp, ref: SpiderRef, forced: Boolean): File {
        dir.mkdirs()
        val given = if (MD5.matches(ref.md5)) ref.md5 else ""
        val mine = files(ref)
        val cached = mine.firstOrNull { given.isEmpty() || it.name.endsWith("-$given.jar") }
        if (cached != null && given.isNotEmpty()) return cached
        if (cached != null && !forced && !TVBoxUrl.isLocal(ref.url)) {
            if (System.currentTimeMillis() - cached.lastModified() >= FRESH_MS) Refresher.run("jar|" + ref.id) { try { store(http, ref, "", cached) } catch (_: Exception) { cached.setLastModified(System.currentTimeMillis()) } }
            return cached
        }
        return try { store(http, ref, given, cached) } catch (e: IOException) { cached ?: throw ProviderException.upstream("JAR 下载失败：${SpiderErrors.text(e)}") }
    }

    private fun files(ref: SpiderRef): List<File> = dir.listFiles { f -> f.name.startsWith(ref.id + "-") && f.name.endsWith(".jar") }?.sortedByDescending { it.lastModified() }.orEmpty()

    /** [using]: the copy that may be being loaded right now. */
    private fun store(http: TVBoxHttp, ref: SpiderRef, given: String, using: File?): File {
        val md5 = if (ref.md5.startsWith("http")) http.text(ref.md5).trim().lowercase().take(32).takeIf { MD5.matches(it) } ?: throw IOException("校验值无法识别") else given
        if (md5.isNotEmpty()) files(ref).firstOrNull { it.name.endsWith("-$md5.jar") }?.let { it.setLastModified(System.currentTimeMillis()); return it }
        val bytes = download(http, ref)
        val sum = Bytes.hex(Bytes.md5(bytes))
        if (md5.isNotEmpty() && md5 != sum) throw ProviderException.upstream("JAR 校验失败：md5 与配置不一致，已拒绝加载")
        val target = File(dir, "${ref.id}-$sum.jar")
        if (!target.isFile) {
            val tmp = File(dir, "${ref.id}.${System.nanoTime()}.tmp")
            tmp.writeBytes(bytes)
            // Android 14+: dynamically loaded code must be read-only before the class loader sees it
            if (!tmp.setReadOnly()) throw IOException("无法保存 JAR")
            if (!tmp.renameTo(target)) { tmp.delete(); if (!target.isFile) throw IOException("无法保存 JAR") }
        }
        target.setLastModified(System.currentTimeMillis())
        files(ref).filter { it != target && it != using && it != loaded[ref.id]?.file }.forEach { it.delete() }
        return target
    }

    private fun download(http: TVBoxHttp, ref: SpiderRef): ByteArray {
        if (!TVBoxUrl.isHttp(ref.url) && !TVBoxUrl.isLocal(ref.url)) throw IOException("不支持的地址 ${ref.url.take(60)}")
        val r = http.execute(NetRequest(ref.url, timeoutMs = 40_000, maxBytes = 48 shl 20))
        if (!r.ok) throw IOException("HTTP ${r.code}")
        val body = if (ref.image || !isCode(r.body)) TVBoxDecoder.carried(r.body) ?: r.body else r.body
        if (!isCode(body)) throw IOException("返回的不是 JAR 文件")
        return body
    }

    private fun isCode(b: ByteArray) = b.size > 100 && ((b[0] == 'P'.code.toByte() && b[1] == 'K'.code.toByte()) || (b[0] == 'd'.code.toByte() && b[1] == 'e'.code.toByte() && b[2] == 'x'.code.toByte()))

    override fun spider(http: TVBoxHttp, ref: SpiderRef, site: TVBoxSite): app.iduanju.core.tvbox.Spider {
        val jar = load(http, ref)
        val name = "com.github.catvod.spider." + site.api.substringAfter("csp_")
        val type = try { jar.loader.loadClass(name) } catch (_: ClassNotFoundException) { throw ProviderException.unsupported("JAR 里没有 ${site.api}") }
        Thread.currentThread().contextClassLoader = jar.loader
        val spider = type.getDeclaredConstructor().apply { isAccessible = true }.newInstance() as? Spider ?: throw ProviderException.unsupported("${site.api} 不是 TVBox spider")
        spider.siteKey = site.key
        spider.init(ctx, site.ext)
        return JarSpider(spider)
    }

    override fun proxy(params: Map<String, String>): ProxyReply? {
        for (jar in loaded.values) {
            val m = jar.proxy ?: continue
            val r = try { m.invoke(null, HashMap(params)) } catch (e: java.lang.reflect.InvocationTargetException) { android.util.Log.w(TAG, "jar proxy: ${SpiderErrors.text(e)}"); null }
            reply(r)?.let { return it }
        }
        return null
    }

    override fun json(http: TVBoxHttp, ref: SpiderRef, key: String, jxs: LinkedHashMap<String, String>, url: String): JSONObject? =
        parser(http, ref, "Json$key").getMethod("parse", LinkedHashMap::class.java, String::class.java).invoke(null, jxs, url) as? JSONObject

    override fun mix(http: TVBoxHttp, ref: SpiderRef, key: String, name: String, flag: String, jxs: LinkedHashMap<String, HashMap<String, String>>, url: String): JSONObject? =
        parser(http, ref, "Mix$key").getMethod("parse", LinkedHashMap::class.java, String::class.java, String::class.java, String::class.java).invoke(null, jxs, name, flag, url) as? JSONObject

    private fun parser(http: TVBoxHttp, ref: SpiderRef, name: String): Class<*> =
        try { load(http, ref).loader.loadClass("com.github.catvod.parser.$name") } catch (_: ClassNotFoundException) { throw ProviderException.unsupported("JAR 里没有解析 $name") }

    override fun release(keep: Set<String>, run: Set<String>) {
        (loaded.keys - run).forEach { loaded.remove(it); stale.remove(it) }
        dir.listFiles()?.filter { f -> (f.name.endsWith(".tmp") && System.currentTimeMillis() - f.lastModified() > 600_000) || (f.name.endsWith(".jar") && f.name.length > 32 && f.name.substring(0, 32) !in keep) }?.forEach { it.delete() }
    }

    private class JarSpider(private val s: Spider) : app.iduanju.core.tvbox.Spider {
        override fun homeContent(filter: Boolean): String = s.homeContent(filter).orEmpty()
        override fun homeVideoContent(): String = s.homeVideoContent().orEmpty()
        override fun categoryContent(tid: String, pg: String, filter: Boolean, extend: Map<String, String>): String = s.categoryContent(tid, pg, filter, HashMap(extend)).orEmpty()
        override fun detailContent(ids: List<String>): String = s.detailContent(ArrayList(ids)).orEmpty()
        override fun searchContent(key: String, quick: Boolean, pg: String): String {
            if (pg != "1" && pg.isNotEmpty()) return s.searchContent(key, quick, pg).orEmpty()
            return s.searchContent(key, quick).orEmpty().ifEmpty { s.searchContent(key, quick, "1").orEmpty() }
        }
        override fun playerContent(flag: String, id: String, vipFlags: List<String>): String = s.playerContent(flag, id, ArrayList(vipFlags)).orEmpty()
        override fun liveContent(url: String): String = s.liveContent(url).orEmpty()
        override fun proxyLocal(params: Map<String, String>): ProxyReply? = reply(s.proxyLocal(HashMap(params)))
        override fun action(action: String): String = s.action(action).orEmpty()
        override fun isVideoFormat(url: String): Boolean = s.isVideoFormat(url)
        override fun manualVideoCheck(): Boolean = s.manualVideoCheck()
        override fun interrupt() = s.cancelByTag()
        override fun destroy() = s.destroy()
    }

    companion object {
        private const val TAG = "TVBoxJar"
        private const val FRESH_MS = 12 * 3600_000L
        private val MD5 = Regex("[0-9a-f]{32}")

        /** `[code, mime, stream | bytes | text, headers?]` */
        fun reply(raw: Any?): ProxyReply? {
            val r = raw as? Array<*> ?: return null
            if (r.size < 3) return null
            val code = (r[0] as? Number)?.toInt() ?: r[0]?.toString()?.toIntOrNull() ?: return null
            val headers = (r.getOrNull(3) as? Map<*, *>)?.entries?.filter { it.key != null && it.value != null }?.associate { it.key.toString() to it.value.toString() }.orEmpty()
            val type = r[1]?.toString() ?: "application/octet-stream"
            return when (val b = r[2]) {
                is InputStream -> ProxyReply(code, type, b, headers)
                is ByteArray -> ProxyReply(code, type, b.inputStream(), headers, b.size.toLong())
                null -> ProxyReply(code, type, ByteArray(0).inputStream(), headers, 0)
                else -> b.toString().toByteArray().let { ProxyReply(code, type, it.inputStream(), headers, it.size.toLong()) }
            }
        }

        /**
         * Threads a jar starts on its own are outside every call guard: an exception there must not take the app down. Only
         * background threads whose stack belongs to a spider are forgiven.
         */
        fun guardBackgroundThreads() {
            val next = Thread.getDefaultUncaughtExceptionHandler()
            val main = android.os.Looper.getMainLooper().thread
            Thread.setDefaultUncaughtExceptionHandler { t, e ->
                if (t !== main && generateSequence(e as Throwable?) { it.cause.takeIf { c -> c !== it } }.take(8).any { x -> x.stackTrace.any { it.className.startsWith("com.github.catvod.spider.") || it.className.startsWith("com.github.catvod.parser.") } }) android.util.Log.w(TAG, "spider thread ${t.name} died", e)
                else next?.uncaughtException(t, e)
            }
        }
    }
}
