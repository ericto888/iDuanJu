package app.iduanju.core.tvbox

import app.iduanju.core.hongguo.HGSubtitle
import app.iduanju.core.util.Bytes
import app.iduanju.core.util.J
import app.iduanju.core.util.ProviderException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject

/** Normalised `playerContent` result. */
data class PlayerResult(
    val parse: Int, val jx: Int, val urls: List<Pair<String, String>>, val headers: Map<String, String>, val playUrl: String,
    val subs: List<HGSubtitle>, val danmaku: String, val format: String = "", val click: String = "", val flag: String = "", val message: String = "",
    /** The result said `parse` itself (both TVBox lineages treat a missing one as "needs parsing"). */
    val parseGiven: Boolean = true,
) {
    companion object {
        fun parse(text: String): PlayerResult = fromJSON(LenientJson.objectOrNull(text) ?: throw ProviderException.upstream("站点没有返回播放信息"))

        fun fromJSON(o: JSONObject): PlayerResult = PlayerResult(
            if (o.has("parse") && !o.isNull("parse")) J.int(o.opt("parse")) else 1, J.int(o.opt("jx")), urls(o.opt("url")).ifEmpty { urls(o.opt("urls")) },
            TVBoxConfig.headerMap(o.opt("header")).ifEmpty { TVBoxConfig.headerMap(o.opt("headers")) }, J.str(o.opt("playUrl")).trim(),
            J.arr(o.opt("subs")).mapNotNull { s -> (s as? JSONObject)?.let { HGSubtitle(J.str(it.opt("name")).ifEmpty { "字幕" }, J.str(it.opt("url")), J.str(it.opt("lang")).ifEmpty { null }, J.str(it.opt("format")).ifEmpty { null }) } }
                .filter { it.url.isNotEmpty() }.ifEmpty { J.str(o.opt("subt")).takeIf { it.contains("://") }?.let { listOf(HGSubtitle("字幕", it)) } ?: emptyList() },
            danmaku(o.opt("danmaku")), J.str(o.opt("format")).let { if (it.isEmpty()) "" else LiveParser.mime(it) }, J.str(o.opt("click")), J.str(o.opt("flag")),
            J.firstNonEmpty(J.str(o.opt("msg")), J.str(o.opt("error"))), o.has("parse") && !o.isNull("parse"),
        )

        /** `"url"`, `["name", "url", …]`, the same as JSON text, or `{"values":[{"n","v"}]}`. */
        private fun urls(v: Any?): List<Pair<String, String>> = when (v) {
            is JSONArray -> {
                val a = J.arr(v)
                when {
                    a.all { it is JSONObject } -> a.mapNotNull { e -> (e as? JSONObject)?.let { J.firstNonEmpty(J.str(it.opt("n")), J.str(it.opt("name"))) to J.firstNonEmpty(J.str(it.opt("v")), J.str(it.opt("url"))) } }
                    a.size == 1 -> listOf("" to J.str(a[0]))
                    else -> a.map { J.str(it) }.chunked(2).filter { it.size == 2 }.map { it[0] to it[1] }
                }.filter { it.second.isNotBlank() }
            }
            is JSONObject -> urls(v.optJSONArray("values")).ifEmpty { urls(J.str(v.opt("url"))) }
            is String -> { val t = v.trim(); if (t.startsWith("[")) LenientJson.arrayOrNull(t)?.let { urls(it) }?.ifEmpty { null } ?: listOf("" to t) else if (t.isEmpty()) emptyList() else listOf("" to t) }
            else -> emptyList()
        }

        private fun danmaku(v: Any?): String = when (v) {
            is String -> v.trim()
            is JSONArray -> J.arr(v).firstNotNullOfOrNull { e -> (if (e is JSONObject) J.str(e.opt("url")) else J.str(e)).ifEmpty { null } }.orEmpty()
            is JSONObject -> J.str(v.opt("url"))
            else -> ""
        }
    }
}

data class SniffRequest(
    val url: String, val headers: Map<String, String>, val scripts: List<String>, val rules: List<TVBoxRule>, val ads: List<String>,
    val allowPrivate: Boolean, val timeoutMs: Long = 15_000,
    /** Spider-side check (`manualVideoCheck` sites); null = the built-in rule. */
    val isVideo: (suspend (String) -> Boolean)? = null,
)

data class SniffResult(val url: String, val headers: Map<String, String>)

/** Hidden browser that watches a page's requests for a media address. */
fun interface Sniffer { suspend fun sniff(r: SniffRequest): SniffResult }

object SniffRules {
    /** Looked at for every request of a page: a pattern is compiled once (null = not a regular expression). */
    private val compiled = object : LinkedHashMap<String, Regex?>(64, 0.75f, true) { override fun removeEldestEntry(e: MutableMap.MutableEntry<String, Regex?>) = size > 2000 }
    private fun regex(p: String): Regex? = synchronized(compiled) { if (p in compiled) compiled[p] else runCatching { Regex(p) }.getOrNull().also { compiled[p] = it } }

    fun rulesFor(host: String, rules: List<TVBoxRule>): List<TVBoxRule> = rules.filter { it.matches(host.lowercase()) }

    /** [page] decides which rules apply, [u] is the request being looked at. */
    fun isVideo(u: String, page: String, rules: List<TVBoxRule>): Boolean {
        if (!TVBoxUrl.isHttp(u) && !TVBoxUrl.isVideo(u)) return false
        val mine = (rulesFor(TVBoxUrl.host(u), rules) + rulesFor(TVBoxUrl.host(page), rules)).distinct()
        if (mine.any { r -> r.exclude.any { hit(u, it) } }) return false
        // several regexes of one old-style rule must all match; new-style rules list alternatives
        if (mine.any { r -> r.regex.any { hit(u, it) } }) return true
        return TVBoxUrl.isVideo(u)
    }

    private fun hit(u: String, pattern: String) = u.contains(pattern) || runCatching { regex(pattern)?.containsMatchIn(u) }.getOrNull() == true

    fun isAd(host: String, ads: List<String>): Boolean = ads.any { a -> a.isNotEmpty() && (host == a || host.endsWith(".$a") || (a.length > 4 && host.contains(a)) || runCatching { regex(a)?.matches(host) }.getOrNull() == true) }
}

/** `com.github.catvod.parser.Json* / Mix*` of the config's jar. */
interface JarParsers {
    suspend fun json(key: String, jxs: LinkedHashMap<String, String>, url: String): JSONObject?
    suspend fun mix(key: String, name: String, flag: String, jxs: LinkedHashMap<String, HashMap<String, String>>, url: String): JSONObject?
}

data class ParsedVideo(val urls: List<Pair<String, String>>, val headers: Map<String, String>, val via: String = "")

/** Contract §3 "播放解析": what still has to happen between `playerContent` and a playable address. */
class ParseChain(
    private val config: TVBoxConfig, private val http: TVBoxHttp, private val sniffer: Sniffer, private val jar: JarParsers?,
    private val allowPrivate: Boolean, private val preferred: String = "", private val timeoutMs: Long = 15_000,
) {
    /** [manual] = the spider asked to judge sniffed requests itself. */
    suspend fun resolve(r: PlayerResult, flag: String, click: String = "", manual: (suspend (String) -> Boolean)? = null): ParsedVideo {
        val first = r.urls.firstOrNull()?.second ?: throw ProviderException.upstream(r.message.ifEmpty { "站点没有返回播放地址" })
        TVBoxUrl.p2p(first)?.let { throw ProviderException.unsupported("$it 链接需要 P2P 内核，暂不支持") }
        val scripts = listOf(r.click, click).filter { it.isNotBlank() }
        val ctx = Ctx(r.headers, flag.ifEmpty { r.flag }, scripts, manual)
        val named = r.playUrl.startsWith("json:") || r.playUrl.startsWith("parse:")
        val flagged = r.playUrl.isEmpty() && flag.isNotEmpty() && config.flags.any { it.equals(flag, true) }
        return when {
            named && r.playUrl.startsWith("json:") -> json(TVBoxParse("json", 1, r.playUrl.substring(5)), first, ctx)
            named -> {
                val name = r.playUrl.substring(6)
                run(config.parses.firstOrNull { it.name == name } ?: throw ProviderException.unsupported("配置里没有名为「$name」的解析"), first, ctx)
            }
            r.jx == 1 -> parses(first, ctx)
            r.parse == 0 -> ParsedVideo(r.urls.map { (n, u) -> n to r.playUrl + u }, r.headers)
            flagged -> parses(first, ctx)
            r.playUrl.isEmpty() && (TVBoxUrl.isVideo(TVBoxUrl.vod(first).url) || (!r.parseGiven && ownProxy(first))) -> ParsedVideo(r.urls, r.headers)
            else -> sniff(r.playUrl + first, r.headers, ctx)
        }
    }

    /** A stream of the app's own proxy: only an explicit `parse=1` sends it through the browser. */
    private fun ownProxy(u: String) = u.startsWith("proxy://") || u.startsWith("http://127.0.0.1:") && u.contains("/proxy?")

    private class Ctx(val headers: Map<String, String>, val flag: String, val scripts: List<String>, val manual: (suspend (String) -> Boolean)?)

    /** Parse entries for a flag: the ones that name it, else the ones that name none, else all. */
    private fun candidates(type: Int, flag: String): List<TVBoxParse> {
        val all = config.parses.filter { it.type == type }
        return all.filter { p -> p.flags.any { it.equals(flag, true) } }.ifEmpty { all.filter { it.flags.isEmpty() } }.ifEmpty { all }
    }

    private suspend fun parses(url: String, ctx: Ctx): ParsedVideo {
        if (config.parses.isEmpty()) return sniff(url, ctx.headers, ctx)
        config.parses.firstOrNull { preferred.isNotEmpty() && it.name == preferred }?.let { p ->
            try { return run(p, url, ctx) } catch (e: CancellationException) { throw e } catch (e: Exception) { if (config.parses.size == 1) throw e }
        }
        return superParse(url, ctx)
    }

    private suspend fun run(p: TVBoxParse, url: String, ctx: Ctx): ParsedVideo = when (p.type) {
        0 -> sniff(p.url + url, p.headers.ifEmpty { ctx.headers }, ctx, p.name)
        1 -> json(p, url, ctx)
        2 -> ext(p.name, ctx) { needJar().json(p.url, LinkedHashMap<String, String>().apply { config.parses.filter { it.type == 1 }.forEach { put(it.name, extUrl(it)) } }, url) }
        3 -> ext(p.name, ctx) {
            needJar().mix(p.url, p.name, ctx.flag, LinkedHashMap<String, HashMap<String, String>>().apply {
                config.parses.forEach { put(it.name, hashMapOf("type" to it.type.toString(), "ext" to it.ext, "url" to it.url)) }
            }, url)
        }
        4 -> superParse(url, ctx)
        else -> throw ProviderException.unsupported("不支持的解析类型 ${p.type}")
    }

    private fun needJar() = jar ?: throw ProviderException.unsupported("这个解析依赖 JAR，当前配置未信任或没有 JAR")

    /** JSON parses receive their own options as `cat_ext` (CatVod convention). */
    private fun extUrl(p: TVBoxParse): String {
        val i = p.url.indexOf('?')
        return if (p.ext.isEmpty() || i < 0) p.url else p.url.substring(0, i + 1) + "cat_ext=" + Bytes.b64(p.ext.toByteArray()).replace('+', '-').replace('/', '_') + "&" + p.url.substring(i + 1)
    }

    private suspend fun json(p: TVBoxParse, url: String, ctx: Ctx): ParsedVideo {
        val r = http.fetch(NetRequest(p.url + url, headers = p.headers, timeoutMs = timeoutMs))
        if (!r.ok) throw ProviderException.upstream("解析「${p.name}」HTTP ${r.code}")
        val o = LenientJson.objectOrNull(r.text()) ?: throw ProviderException.upstream("解析「${p.name}」没有返回 JSON")
        return result(o, p.name, ctx)
    }

    private suspend fun ext(name: String, ctx: Ctx, call: suspend () -> JSONObject?): ParsedVideo = result(call() ?: throw ProviderException.upstream("解析「$name」没有结果"), name, ctx)

    private suspend fun result(root: JSONObject, name: String, ctx: Ctx): ParsedVideo {
        val o = root.optJSONObject("data")?.takeIf { it.has("url") } ?: root
        val r = PlayerResult.fromJSON(o)
        val url = r.urls.firstOrNull()?.second.orEmpty()
        val headers = LinkedHashMap(r.headers)
        for (k in o.keys()) if (k.equals("user-agent", true) || k.equals("referer", true) || k.equals("ua", true)) J.str(o.opt(k)).takeIf { it.isNotEmpty() }?.let { headers[TVBoxUrl.headerName(k)] = it }
        if (!TVBoxUrl.isHttp(url) && !TVBoxUrl.isVideo(url) && !url.startsWith("proxy://")) throw ProviderException.upstream("解析「$name」没有给出播放地址" + (if (r.message.isEmpty()) "" else "：${r.message}"))
        if ((J.int(o.opt("parse")) == 1 || r.jx == 1) && !TVBoxUrl.isVideo(url)) return sniff(url, headers, ctx, name)
        return ParsedVideo(r.urls, headers, name)
    }

    private suspend fun sniff(url: String, headers: Map<String, String>, ctx: Ctx, via: String = ""): ParsedVideo {
        if (!TVBoxUrl.isHttp(url)) throw ProviderException.unsupported("无法解析的播放地址：${url.take(60)}")
        val host = TVBoxUrl.host(url)
        val scripts = ctx.scripts + SniffRules.rulesFor(host, config.rules).flatMap { it.script }
        val s = sniffer.sniff(SniffRequest(url, headers, scripts.distinct(), config.rules, config.ads, allowPrivate, timeoutMs, ctx.manual))
        return ParsedVideo(listOf("" to s.url), s.headers, via)
    }

    /** 超级解析: JSON parses and (at most two) browser parses race; the first playable address wins and cancels the rest. */
    private suspend fun superParse(url: String, ctx: Ctx): ParsedVideo = withContext(Dispatchers.Default) {
        val jsons = candidates(1, ctx.flag)
        val webs = candidates(0, ctx.flag)
        val exts = if (jar == null) emptyList() else candidates(2, ctx.flag) + candidates(3, ctx.flag)
        if (jsons.isEmpty() && webs.isEmpty() && exts.isEmpty()) return@withContext sniff(url, ctx.headers, ctx)
        val results = Channel<Result<ParsedVideo>>(Channel.UNLIMITED)
        val tasks = (jsons + exts + webs).distinct()
        val web = Semaphore(2)
        var last: Throwable? = null
        coroutineScope {
            val racers = tasks.map { p ->
                launch {
                    val r = try { Result.success(if (p.type == 0) web.withPermit { run(p, url, ctx) } else run(p, url, ctx)) } catch (e: CancellationException) { throw e } catch (e: Exception) { Result.failure(e) }
                    results.send(r)
                }
            }
            var winner: ParsedVideo? = null
            withTimeoutOrNull(timeoutMs * 2) {
                repeat(tasks.size) {
                    val r = results.receive()
                    r.onSuccess { winner = it }.onFailure { last = it }
                    if (winner != null) return@withTimeoutOrNull
                }
            }
            racers.forEach { it.cancel() }
            winner ?: throw (last as? ProviderException ?: ProviderException.upstream("所有解析都没有返回播放地址"))
        }
    }
}
