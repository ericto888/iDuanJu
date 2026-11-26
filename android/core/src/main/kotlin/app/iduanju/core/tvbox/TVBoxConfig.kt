package app.iduanju.core.tvbox

import app.iduanju.core.util.Bytes
import app.iduanju.core.util.J
import org.json.JSONArray
import org.json.JSONObject

enum class SiteKind(val wire: String, val badge: String) {
    CmsXml("cms-xml", "CMS"), CmsJson("cms-json", "CMS"), Remote("remote", "T4"),
    Jar("jar", "JAR"), Js("js", "JS"), Py("py", "PY"), Unsupported("unsupported", "不支持");

    /** Runs downloaded code on the device: needs the config's trust. */
    val isCode get() = this == Jar || this == Js || this == Py

    companion object {
        fun of(type: Int, api: String): SiteKind {
            val path = api.substringBefore('?').substringBefore('#').lowercase()
            val query = api.substringAfter('?', "").lowercase()
            return when (type) {
                0 -> CmsXml
                1 -> CmsJson
                4 -> Remote
                3 -> when {
                    api.startsWith("csp_") -> Jar
                    path.endsWith(".py") || api.startsWith("py_") -> Py
                    path.endsWith(".js") || query.endsWith(".js") -> Js
                    query.endsWith(".py") -> Py
                    else -> Unsupported
                }
                else -> Unsupported
            }
        }
    }
}

data class TVBoxSite(
    val key: String, val name: String, val type: Int, val api: String,
    /** Text handed to the spider: a plain string, or the compact JSON of an object / array. */
    val ext: String = "", val jar: String = "", val playUrl: String = "", val click: String = "",
    val searchable: Boolean = true, val quickSearch: Boolean = true, val filterable: Boolean = true, val changeable: Boolean = true,
    val hide: Boolean = false, val timeoutMs: Long = DEFAULT_TIMEOUT_MS, val headers: Map<String, String> = emptyMap(),
    /** Category names to keep, in this order (empty = everything the site returns). */
    val categories: List<String> = emptyList(), val adult: Boolean = false,
) {
    val kind: SiteKind get() = SiteKind.of(type, api)

    companion object { const val DEFAULT_TIMEOUT_MS = 15_000L }
}

data class TVBoxParse(val name: String, val type: Int, val url: String, val flags: List<String> = emptyList(), val headers: Map<String, String> = emptyMap(), val ext: String = "")

data class TVBoxRule(val name: String, val hosts: List<String>, val regex: List<String>, val exclude: List<String>, val script: List<String>) {
    fun matches(host: String): Boolean = hosts.any { h -> h == "*" || host == h.lowercase() || host.endsWith("." + h.lowercase().removePrefix("*.").removePrefix(".")) || host.contains(h.lowercase()) }
}

data class TVBoxHeaderRule(val host: String, val headers: Map<String, String>)
data class TVBoxDoh(val name: String, val url: String, val ips: List<String>)

data class TVBoxLive(
    val name: String, val type: Int = 0, val url: String = "", val api: String = "", val ext: String = "", val jar: String = "",
    val epg: String = "", val logo: String = "", val ua: String = "", val referer: String = "", val origin: String = "",
    val headers: Map<String, String> = emptyMap(), val timeZone: String = "", val timeoutMs: Long = TVBoxSite.DEFAULT_TIMEOUT_MS,
    val pass: Boolean = false, val catchup: Catchup? = null, val groups: List<LiveGroup> = emptyList(),
) {
    /** What identifies this list inside its config (contract: `repoId + "|live|" + url`). */
    val identity: String get() = url.ifEmpty { if (api.isNotEmpty()) "$api $ext" else name }
    /** type 3 = the list comes from a spider's `liveContent`. */
    val kind: SiteKind? get() = if (api.isEmpty()) null else SiteKind.of(3, api).takeIf { it != SiteKind.Unsupported }
    val requestHeaders: Map<String, String> get() = buildMap {
        putAll(headers)
        if (ua.isNotEmpty()) put("User-Agent", ua)
        if (referer.isNotEmpty()) put("Referer", referer)
        if (origin.isNotEmpty()) put("Origin", origin)
    }
}

data class TVBoxDepotEntry(val name: String, val url: String)

/** What an address / file turned out to be. */
sealed class ParsedConfig {
    data class Config(val config: TVBoxConfig) : ParsedConfig()
    data class Depot(val entries: List<TVBoxDepotEntry>) : ParsedConfig()
    /** Not a config at all but a channel list (M3U / TXT / JSON groups). */
    data class Live(val text: String) : ParsedConfig()
}

data class TVBoxConfig(
    val spider: String = "", val sites: List<TVBoxSite> = emptyList(), val lives: List<TVBoxLive> = emptyList(), val parses: List<TVBoxParse> = emptyList(),
    val flags: List<String> = emptyList(), val rules: List<TVBoxRule> = emptyList(), val ads: List<String> = emptyList(),
    val headers: List<TVBoxHeaderRule> = emptyList(), val hosts: Map<String, String> = emptyMap(), val doh: List<TVBoxDoh> = emptyList(),
    val name: String = "", val logo: String = "", val wallpaper: String = "", val notice: String = "",
) {
    /** Contains anything that would execute downloaded code (drives the trust prompt). */
    val hasCode: Boolean get() = sites.any { it.kind.isCode } || lives.any { it.kind?.isCode == true } || parses.any { it.type == 2 || it.type == 3 }

    fun jarOf(site: TVBoxSite): String = site.jar.ifEmpty { spider }
    fun jarOf(live: TVBoxLive): String = live.jar.ifEmpty { spider }

    companion object {
        fun siteUid(repoId: String, key: String): String = uid("$repoId|$key")
        fun liveUid(repoId: String, identity: String): String = uid("$repoId|live|$identity")

        /** First 12 hex digits of the md5; computed for every site of every config, so no formatting helpers. */
        private fun uid(seed: String): String {
            val d = Bytes.md5(seed)
            val out = CharArray(12)
            for (i in 0 until 6) { val b = d[i].toInt() and 0xff; out[i * 2] = HEX[b shr 4]; out[i * 2 + 1] = HEX[b and 15] }
            return String(out)
        }
        private const val HEX = "0123456789abcdef"

        /** [text] is already decoded; [base] resolves relative addresses. */
        fun parse(text: String, base: String): ParsedConfig {
            val t = text.trimStart('﻿', ' ', '\t', '\r', '\n')
            if (LiveParser.looksLikeList(t)) return ParsedConfig.Live(text)
            if (t.startsWith("<")) throw LenientJson.Malformed("这个地址返回的是网页，不是 TVBox 配置")
            val start = t.indexOfFirst { it == '{' || it == '[' }
            if (start < 0) throw LenientJson.Malformed("不是 TVBox 配置或直播列表")
            val root = try { LenientJson.parse(t) } catch (e: LenientJson.Malformed) { if (start == 0) throw e else LenientJson.parse(t.substring(start)) }
            TVBoxUrl.resolveTree(root, base)
            if (root is JSONArray) return if (LiveParser.isJsonGroups(root)) ParsedConfig.Live(text) else throw LenientJson.Malformed("不是 TVBox 配置")
            val o = root as? JSONObject ?: throw LenientJson.Malformed("不是 TVBox 配置")
            depot(o)?.let { return ParsedConfig.Depot(it) }
            val known = listOf("sites", "lives", "spider", "parses").any { o.has(it) }
            if (!known) throw LenientJson.Malformed(J.firstNonEmpty(J.str(o.opt("msg")), J.str(o.opt("message")), J.str(o.opt("error"))).ifEmpty { "不是 TVBox 配置（缺少 sites / lives / spider）" })
            val config = config(o)
            if (config.sites.isEmpty() && config.lives.isEmpty()) {
                val msg = J.firstNonEmpty(J.str(o.opt("msg")), J.str(o.opt("warningText")))
                throw LenientJson.Malformed(msg.ifEmpty { "配置里没有点播站点，也没有直播列表" })
            }
            return ParsedConfig.Config(config)
        }

        private fun depot(o: JSONObject): List<TVBoxDepotEntry>? {
            val urls = o.optJSONArray("urls")
            val store = o.optJSONArray("storeHouse")
            if (urls == null && store == null) return null
            val list = buildList {
                J.arr(store).forEach { e -> (e as? JSONObject)?.let { add(TVBoxDepotEntry(J.str(it.opt("sourceName")).trim(), J.str(it.opt("sourceUrl")).trim())) } }
                J.arr(urls).forEach { e ->
                    when (e) {
                        is JSONObject -> add(TVBoxDepotEntry(J.str(e.opt("name")).trim(), J.str(e.opt("url")).trim()))
                        is String -> add(TVBoxDepotEntry("", e.trim()))
                    }
                }
            }.filter { it.url.isNotEmpty() }.distinctBy { it.url }.mapIndexed { i, e -> if (e.name.isEmpty()) e.copy(name = TVBoxUrl.host(e.url).ifEmpty { "线路 ${i + 1}" }) else e }
            return list.takeIf { it.isNotEmpty() && (store != null || !o.has("sites")) }
        }

        private fun config(o: JSONObject): TVBoxConfig {
            val sites = J.arr(o.opt("sites")).mapNotNull { (it as? JSONObject)?.let(::site) }.distinctBy { it.key }
            return TVBoxConfig(
                spider = J.str(o.opt("spider")).trim(), sites = sites, lives = lives(J.arr(o.opt("lives"))),
                parses = J.arr(o.opt("parses")).mapNotNull { (it as? JSONObject)?.let(::parseEntry) }.distinctBy { it.name },
                flags = strings(o.opt("flags")), rules = J.arr(o.opt("rules")).mapNotNull { (it as? JSONObject)?.let(::rule) }, ads = strings(o.opt("ads")),
                headers = J.arr(o.opt("headers")).mapNotNull { h -> (h as? JSONObject)?.let { TVBoxHeaderRule(J.str(it.opt("host")).trim().lowercase(), headerMap(it.opt("header") ?: it.opt("headers"))) } }.filter { it.host.isNotEmpty() },
                hosts = hosts(o.opt("hosts")),
                doh = J.arr(o.opt("doh")).mapNotNull { d -> (d as? JSONObject)?.let { TVBoxDoh(J.str(it.opt("name")), J.str(it.opt("url")).trim(), strings(it.opt("ips"))) } }.filter { it.url.startsWith("https://") },
                name = J.firstNonEmpty(J.str(o.opt("name")), J.str(o.opt("title"))).take(60), logo = J.str(o.opt("logo")), wallpaper = J.str(o.opt("wallpaper")),
                notice = J.firstNonEmpty(J.str(o.opt("notice")), J.str(o.opt("warningText"))),
            )
        }

        private val ADULT = Regex("🔞|18\\+|18禁|成人|情色|\\bporn\\b", RegexOption.IGNORE_CASE)

        private fun site(o: JSONObject): TVBoxSite? {
            val api = J.str(o.opt("api")).trim()
            val name = J.str(o.opt("name")).trim()
            val key = J.str(o.opt("key")).trim().ifEmpty { name.ifEmpty { api } }
            if (key.isEmpty() || (api.isEmpty() && name.isEmpty())) return null
            val timeout = J.int64(o.opt("timeout"))
            return TVBoxSite(
                key = key, name = name.ifEmpty { key }.take(60), type = J.int(o.opt("type")), api = api, ext = ext(o.opt("ext")), jar = J.str(o.opt("jar")).trim(),
                playUrl = J.str(o.opt("playUrl")).trim(), click = J.str(o.opt("click")).trim(),
                searchable = flag(o, "searchable"), quickSearch = flag(o, "quickSearch"), filterable = flag(o, "filterable"), changeable = flag(o, "changeable"), hide = J.int(o.opt("hide")) == 1,
                timeoutMs = when { timeout <= 0 -> TVBoxSite.DEFAULT_TIMEOUT_MS; timeout < 1000 -> timeout * 1000; else -> timeout }.coerceIn(3_000, 60_000),
                headers = headerMap(o.opt("header") ?: o.opt("headers")), categories = strings(o.opt("categories")), adult = J.bool(o.opt("adult")) || ADULT.containsMatchIn(name),
            )
        }

        private fun flag(o: JSONObject, k: String) = if (!o.has(k) || o.isNull(k)) true else J.str(o.opt(k)) != "0" && J.str(o.opt(k)) != "false"

        /** Objects / arrays become compact JSON, everything else its text. */
        fun ext(v: Any?): String = when (v) { null, JSONObject.NULL -> ""; is JSONObject, is JSONArray -> v.toString(); is String -> v.trim(); else -> J.str(v) }

        fun strings(v: Any?): List<String> = when (v) {
            is JSONArray -> J.arr(v).map { J.str(it).trim() }.filter { it.isNotEmpty() }
            is String -> v.split(',').map { it.trim() }.filter { it.isNotEmpty() }
            else -> emptyList()
        }

        /** Header object, JSON text of one, or `k=v&k=v`. */
        fun headerMap(v: Any?): Map<String, String> = when (v) {
            is JSONObject -> buildMap { v.keys().forEach { k -> val x = v.opt(k); put(TVBoxUrl.headerName(k), if (x is JSONObject || x is JSONArray) x.toString() else J.str(x)) } }.filterValues { it.isNotEmpty() }
            is String -> { val t = v.trim(); if (t.startsWith("{")) LenientJson.objectOrNull(t)?.let { headerMap(it) } ?: emptyMap() else if (t.contains('=')) TVBoxUrl.headerQuery(t) else emptyMap() }
            else -> emptyMap()
        }

        private fun hosts(v: Any?): Map<String, String> = when (v) {
            is JSONArray -> J.arr(v).mapNotNull { e -> J.str(e).split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0].trim().lowercase() to it[1].trim() } }.toMap()
            is JSONObject -> v.keys().asSequence().associate { it.trim().lowercase() to J.str(v.opt(it)).trim() }
            else -> emptyMap()
        }.filter { (k, x) -> k.isNotEmpty() && x.isNotEmpty() }

        private fun parseEntry(o: JSONObject): TVBoxParse? {
            val name = J.str(o.opt("name")).trim()
            val url = J.str(o.opt("url")).trim()
            val type = J.int(o.opt("type"))
            if (name.isEmpty() || (url.isEmpty() && type != 4)) return null
            val ext = o.optJSONObject("ext")
            return TVBoxParse(name, type, url, strings(ext?.opt("flag")), headerMap(ext?.opt("header")), ext(o.opt("ext")))
        }

        private fun rule(o: JSONObject): TVBoxRule? {
            val hosts = strings(o.opt("hosts")) + listOf(J.str(o.opt("host"))).filter { it.isNotBlank() }
            val regex = strings0(o.opt("regex")) + strings0(o.opt("rule"))
            val exclude = strings0(o.opt("exclude")) + strings0(o.opt("filter"))
            val script = strings0(o.opt("script"))
            if (hosts.isEmpty() || (regex.isEmpty() && exclude.isEmpty() && script.isEmpty())) return null
            return TVBoxRule(J.str(o.opt("name")), hosts, regex, exclude, script)
        }

        /** Rule texts may contain commas: never split a plain string. */
        private fun strings0(v: Any?): List<String> = when (v) { is JSONArray -> J.arr(v).map { J.str(it) }.filter { it.isNotEmpty() }; is String -> listOf(v).filter { it.isNotEmpty() }; else -> emptyList() }

        private fun lives(list: List<Any?>): List<TVBoxLive> {
            val out = ArrayList<TVBoxLive>()
            val inline = JSONArray()
            for (e in list) {
                val o = e as? JSONObject ?: continue
                val channels = o.optJSONArray("channels") ?: o.optJSONArray("channel")
                when {
                    channels != null && J.str(o.opt("group")) == "redirect" -> out += redirects(o, channels)
                    channels != null && !o.has("url") && !o.has("api") -> inline.put(o)
                    else -> live(o)?.let(out::add)
                }
            }
            if (inline.length() > 0) out.add(0, TVBoxLive(name = "配置直播", groups = LiveParser.json(inline)))
            return out.distinctBy { it.identity }
        }

        private fun redirects(o: JSONObject, channels: JSONArray): List<TVBoxLive> = J.arr(channels).flatMapIndexed { i, c ->
            val ch = c as? JSONObject ?: return@flatMapIndexed emptyList()
            val urls = strings0(ch.opt("urls"))
            urls.mapIndexedNotNull { j, u ->
                val real = proxyLive(u)
                if (real.isEmpty()) null
                else TVBoxLive(name = J.firstNonEmpty(J.str(ch.opt("name")), J.str(o.opt("name"))).ifEmpty { "直播 ${i + 1}" } + if (urls.size > 1) " ${j + 1}" else "", url = real, epg = J.str(o.opt("epg")), ua = J.str(o.opt("ua")))
            }
        }

        /** `proxy://do=live&type=txt&ext=<base64 address>` → the list address. */
        fun proxyLive(u: String): String {
            if (!u.startsWith("proxy://", true)) return u
            val q = u.substring(8).split('&').mapNotNull { p -> p.indexOf('=').takeIf { it > 0 }?.let { p.substring(0, it) to p.substring(it + 1) } }.toMap()
            val ext = q["ext"] ?: q["url"] ?: return ""
            if (TVBoxUrl.isHttp(ext)) return ext
            val plain = Bytes.b64decode(TVBoxUrl.decode(ext))?.let { String(it, Charsets.UTF_8) }?.trim().orEmpty()
            return if (TVBoxUrl.isHttp(plain) || TVBoxUrl.isLocal(plain)) plain else TVBoxUrl.decode(ext).takeIf { TVBoxUrl.isHttp(it) }.orEmpty()
        }

        private fun live(o: JSONObject): TVBoxLive? {
            val url = proxyLive(J.str(o.opt("url")).trim())
            val api = J.str(o.opt("api")).trim()
            val groups = o.optJSONArray("groups")?.let { LiveParser.json(it) } ?: o.optJSONArray("channels")?.let { LiveParser.json(JSONArray().put(o)) } ?: emptyList()
            if (url.isEmpty() && api.isEmpty() && groups.isEmpty()) return null
            val timeout = J.int64(o.opt("timeout"))
            return TVBoxLive(
                name = J.str(o.opt("name")).trim().ifEmpty { TVBoxUrl.host(url).ifEmpty { "直播" } }.take(60), type = J.int(o.opt("type")), url = url, api = api, ext = ext(o.opt("ext")),
                jar = J.str(o.opt("jar")).trim(), epg = J.str(o.opt("epg")).trim(), logo = J.str(o.opt("logo")).trim(), ua = J.str(o.opt("ua")).trim(), referer = J.str(o.opt("referer")).trim(),
                origin = J.str(o.opt("origin")).trim(), headers = headerMap(o.opt("header") ?: o.opt("headers")), timeZone = J.str(o.opt("timeZone")).trim(),
                timeoutMs = when { timeout <= 0 -> TVBoxSite.DEFAULT_TIMEOUT_MS; timeout < 1000 -> timeout * 1000; else -> timeout }.coerceIn(3_000, 60_000),
                pass = J.bool(o.opt("pass")), catchup = (o.opt("catchup") as? JSONObject)?.let(Catchup::fromJSON), groups = groups,
            )
        }
    }
}
