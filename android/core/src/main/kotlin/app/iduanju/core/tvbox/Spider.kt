package app.iduanju.core.tvbox

import app.iduanju.core.cms.MacCMSXml
import app.iduanju.core.util.Bytes
import app.iduanju.core.util.J
import app.iduanju.core.util.ProviderException
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream

/** Reply of `proxyLocal`; [body] is streamed and closed by the local server. */
class ProxyReply(val code: Int, val type: String, val body: InputStream, val headers: Map<String, String> = emptyMap(), val length: Long = -1) {
    companion object {
        fun text(s: String, code: Int = 200, type: String = "text/plain; charset=utf-8"): ProxyReply = s.toByteArray().let { ProxyReply(code, type, ByteArrayInputStream(it), length = it.size.toLong()) }

        /** `{"code","type","b64","headers"}` as produced by the JS / Python runners. */
        fun fromRunner(json: String): ProxyReply? {
            if (json.isBlank()) return null
            val o = J.parse(json)
            val b = Bytes.b64decode(J.str(o.opt("b64"))) ?: ByteArray(0)
            val h = J.dict(o.opt("headers"))
            return ProxyReply(J.int(o.opt("code")).takeIf { it > 0 } ?: 200, J.str(o.opt("type")).ifEmpty { "application/octet-stream" }, ByteArrayInputStream(b), h.keys().asSequence().associateWith { J.str(h.opt(it)) }, b.size.toLong())
        }
    }
}

/**
 * One TVBox site behind the common contract. Every content method returns the TVBox JSON text ("" = nothing). Calls are
 * blocking and confined to the owning [SpiderSession]'s thread.
 */
interface Spider {
    fun init(ext: String) {}
    fun homeContent(filter: Boolean): String = ""
    fun homeVideoContent(): String = ""
    fun categoryContent(tid: String, pg: String, filter: Boolean, extend: Map<String, String>): String = ""
    fun detailContent(ids: List<String>): String = ""
    fun searchContent(key: String, quick: Boolean, pg: String): String = ""
    fun playerContent(flag: String, id: String, vipFlags: List<String>): String = ""
    fun liveContent(url: String): String = ""
    fun proxyLocal(params: Map<String, String>): ProxyReply? = null
    fun action(action: String): String = ""
    fun isVideoFormat(url: String): Boolean = false
    fun manualVideoCheck(): Boolean = false
    fun destroy() {}
    /** Wakes the spider thread out of a network call (timeout / cancellation). */
    fun interrupt() {}
}

/** 苹果 CMS collect interface, JSON (`type` 1) or XML (`type` 0). */
class CmsSpider(private val site: TVBoxSite, private val http: TVBoxHttp) : Spider {
    private val xml = site.kind == SiteKind.CmsXml
    private val detailAc = if (xml) "videolist" else "detail"
    private val tag = Any()

    private fun get(q: Map<String, String>): JSONObject {
        val u = site.api.toHttpUrlOrNull() ?: throw ProviderException.invalid("采集接口地址无效")
        val b = u.newBuilder().fragment(null)
        q.forEach { (k, v) -> b.setQueryParameter(k, v) }
        val body = http.text(b.build().toString(), site.headers, site.timeoutMs, tag)
        return decode(body)
    }

    override fun homeContent(filter: Boolean): String = get(mapOf("ac" to "list")).toString()
    override fun homeVideoContent(): String = get(mapOf("ac" to detailAc, "pg" to "1")).toString()
    override fun categoryContent(tid: String, pg: String, filter: Boolean, extend: Map<String, String>): String =
        get(buildMap { put("ac", detailAc); put("t", tid); put("pg", pg); if (extend.isNotEmpty()) put("f", JSONObject(extend as Map<*, *>).toString()) }).toString()
    override fun detailContent(ids: List<String>): String = get(mapOf("ac" to detailAc, "ids" to ids.joinToString(","))).toString()
    override fun searchContent(key: String, quick: Boolean, pg: String): String = get(buildMap { put("ac", detailAc); put("wd", key); if (pg != "1" && pg.isNotEmpty()) put("pg", pg) }).toString()

    override fun playerContent(flag: String, id: String, vipFlags: List<String>): String {
        val direct = TVBoxUrl.isVideo(TVBoxUrl.stream(id).url) && site.playUrl.isEmpty()
        return JSONObject().put("parse", if (direct) 0 else 1).put("url", id).put("flag", flag).put("playUrl", site.playUrl).put("header", JSONObject(site.headers as Map<*, *>)).toString()
    }

    override fun interrupt() = http.cancel(tag)

    companion object {
        fun decode(body: String): JSONObject {
            val t = body.trimStart('﻿', ' ', '\r', '\n', '\t')
            val o = try { if (t.startsWith("<")) MacCMSXml.parse(t) else LenientJson.objectOrNull(t) } catch (_: Exception) { null }
                ?: throw ProviderException.upstream("站点没有返回有效的 CMS JSON / XML")
            if (o.has("code") && !o.has("list") && !o.has("class") && J.str(o.opt("code")) !in setOf("1", "200")) throw ProviderException.upstream("站点：" + J.str(o.opt("msg")).ifEmpty { "请求失败" })
            return o
        }
    }
}

/** T4 / hipy remote interface (`type` 4): the same content calls as query parameters. */
class RemoteSpider(private val site: TVBoxSite, private val http: TVBoxHttp, /** Parameters may come from this device. */ private val inside: Boolean = false) : Spider {
    private var extend = ""
    private val tag = Any()
    @Volatile private var stopped = false

    /**
     * Parameters go to the site's server with every call: unless [inside], what they are read from may not be this device,
     * whatever address or redirect leads there.
     */
    override fun init(ext: String) {
        stopped = false
        extend = if (!TVBoxUrl.isHttp(ext)) ext else try { fetch(ext) } catch (e: Exception) {
            // an aborted download says nothing about the parameters: the next call starts over
            if (stopped || Thread.currentThread().isInterrupted || e is InterruptedException) throw e else ext
        }
    }

    private fun fetch(ext: String): String {
        val r = http.execute(NetRequest(ext, headers = site.headers, timeoutMs = site.timeoutMs, tag = tag, loopback = inside))
        if (!r.ok) throw IOException("HTTP ${r.code}")
        return r.text().trim()
    }

    private fun call(params: Map<String, String>): String {
        val u = site.api.toHttpUrlOrNull() ?: throw ProviderException.invalid("站点接口地址无效")
        val q = if (extend.isEmpty()) params else params + ("extend" to extend)
        val r = if (extend.length <= 1000) {
            val b = u.newBuilder()
            q.forEach { (k, v) -> b.setQueryParameter(k, v) }
            NetRequest(b.build().toString(), headers = site.headers, timeoutMs = site.timeoutMs, tag = tag)
        } else {
            val form = q.entries.joinToString("&") { (k, v) -> enc(k) + "=" + enc(v) }
            NetRequest(u.toString(), "POST", site.headers + ("Content-Type" to "application/x-www-form-urlencoded"), form.toByteArray(), site.timeoutMs, tag = tag)
        }
        val resp = http.execute(r)
        if (!resp.ok) throw ProviderException.upstream("站点 HTTP ${resp.code} · ${TVBoxUrl.host(site.api)}")
        return resp.text()
    }

    private fun enc(s: String) = java.net.URLEncoder.encode(s, "UTF-8")

    override fun homeContent(filter: Boolean): String = call(mapOf("filter" to filter.toString()))
    override fun categoryContent(tid: String, pg: String, filter: Boolean, extend: Map<String, String>): String =
        call(mapOf("ac" to "detail", "t" to tid, "pg" to pg, "ext" to Bytes.b64(JSONObject(extend as Map<*, *>).toString().toByteArray())))
    override fun detailContent(ids: List<String>): String = call(mapOf("ac" to "detail", "ids" to ids.joinToString(",")))
    override fun searchContent(key: String, quick: Boolean, pg: String): String = call(buildMap { put("wd", key); put("quick", quick.toString()); if (pg != "1" && pg.isNotEmpty()) put("pg", pg) })
    override fun playerContent(flag: String, id: String, vipFlags: List<String>): String = call(mapOf("play" to id, "flag" to flag))
    override fun action(action: String): String = call(mapOf("ac" to "action", "action" to action))
    override fun interrupt() { stopped = true; http.cancel(tag) }
}
