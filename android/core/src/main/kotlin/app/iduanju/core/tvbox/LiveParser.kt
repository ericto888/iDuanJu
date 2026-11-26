package app.iduanju.core.tvbox

import app.iduanju.core.hongguo.HGEpisode
import app.iduanju.core.util.J
import org.json.JSONArray
import org.json.JSONObject

data class LiveChannel(
    val name: String, val urls: List<String>, val logo: String = "", val tvgId: String = "", val tvgName: String = "",
    val headers: Map<String, String> = emptyMap(), val epg: String = "", val catchup: Catchup? = null, val format: String = "",
    /** Web page addresses that need the sniffer (`parse=1`), plus the script it runs. */
    val parse: Boolean = false, val click: String = "",
    /** `inputstream.adaptive` DRM hints, passed through untouched. */
    val drm: Map<String, String> = emptyMap(),
) {
    /** Name programme guides are matched by. */
    val guideName: String get() = tvgName.ifEmpty { name }

    fun mediaJSON(defaults: Map<String, String> = emptyMap(), epgUrl: String = "", fallbackCatchup: Catchup? = null): String = JSONObject()
        .put("urls", JSONArray(urls)).put("headers", JSONObject((defaults + headers) as Map<*, *>)).put("logo", logo).put("tvgId", tvgId).put("tvgName", tvgName)
        .put("epg", epg.ifEmpty { epgUrl }).put("catchup", (catchup ?: fallbackCatchup)?.toJSON() ?: JSONObject())
        .apply {
            if (format.isNotEmpty()) put("format", format)
            if (parse) put("parse", 1)
            if (click.isNotEmpty()) put("click", click)
            if (drm.isNotEmpty()) put("drm", JSONObject(drm as Map<*, *>))
        }.toString()
}

data class LiveGroup(val name: String, val pass: String, val channels: List<LiveChannel>)
data class LiveList(val groups: List<LiveGroup>, val epg: String = "", val catchup: Catchup? = null) {
    val channels: List<Pair<LiveGroup, LiveChannel>> by lazy { groups.flatMap { g -> g.channels.map { g to it } } }
}

/** What identifies a channel: lists are refreshed between two looks at them, so its [number] (`HGEpisode.ep`) alone may point at another one. */
data class LiveKey(val number: Int, val group: String, val name: String, val url: String = "") {
    /** Index in [channels]: group + name (+ first address), then the name alone, then the number. -1 = none of them. */
    fun find(channels: List<HGEpisode>): Int {
        val byNumber = channels.indexOfFirst { it.ep == number }
        val named = if (name.isEmpty()) emptyList() else channels.indices.filter { channels[it].title == name }
        if (named.isEmpty()) return byNumber
        val near = if (group.isEmpty()) named else named.filter { channels[it].page == group }.ifEmpty { named }
        return near.takeIf { it.size > 1 && url.isNotEmpty() }?.firstOrNull { J.str(J.arr(LenientJson.objectOrNull(channels[it].media.orEmpty())?.opt("urls")).firstOrNull()) == url }
            ?: byNumber.takeIf { it in near } ?: near.first()
    }
}

/** TXT / M3U / JSON channel lists → groups of channels with merged lines. Nothing is fetched here. */
object LiveParser {
    private val ENTRY = Regex("(?m)^[^\\r\\n,{\\[\"<]{1,100},\\s*[A-Za-z0-9]{2,12}://")
    private val CONFIG_KEY = Regex("[\"'](sites|lives|spider|urls|storeHouse)[\"']\\s*:")
    private const val DEFAULT_GROUP = "默认分组"

    fun looksLikeList(text: String): Boolean {
        val t = text.trimStart('﻿', ' ', '\t', '\r', '\n')
        if (t.startsWith("#EXTM3U", true) || t.startsWith("#EXTINF", true)) return true
        if (t.startsWith("{") || t.startsWith("[") || t.startsWith("<")) return false
        // a config may open with comment lines that look like `name,address` rows
        val first = t.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() && !it.startsWith("//") && !it.startsWith("/*") && !(it.startsWith("#") && !it.startsWith("#EXT", true)) }
        if (first != null && (first[0] == '{' || first[0] == '[')) return false
        if (t.contains('{') && CONFIG_KEY.containsMatchIn(t)) return false
        return t.contains("#genre#", true) || ENTRY.containsMatchIn(t.take(20_000))
    }

    fun isJsonGroups(a: JSONArray): Boolean = J.arr(a).any { it is JSONObject && (it.has("channel") || it.has("channels")) }

    fun parse(raw: String, skipPass: Boolean = false): LiveList {
        val t = raw.trimStart('﻿', ' ', '\t', '\r', '\n')
        if (t.startsWith("[") || t.startsWith("{")) {
            val v = runCatching { LenientJson.parse(t) }.getOrNull()
            val arr = v as? JSONArray ?: (v as? JSONObject)?.let { it.optJSONArray("groups") ?: it.optJSONArray("lives") ?: it.optJSONArray("data") }
            if (arr != null) return LiveList(json(arr).map { if (skipPass) it.copy(pass = "") else it })
        }
        // an HLS media / master playlist pasted as a "list" is a single channel
        if (t.startsWith("#EXTM3U", true) && (t.contains("#EXT-X-STREAM-INF") || t.contains("#EXT-X-TARGETDURATION"))) return LiveList(emptyList())
        return if (t.contains("#EXTINF", true) || t.startsWith("#EXTM3U", true)) m3u(t) else LiveList(text(t, skipPass))
    }

    /** Insertion-ordered (group, channel) accumulator that merges lines of the same channel. */
    private class Builder {
        val groups = LinkedHashMap<String, LinkedHashMap<String, LiveChannel>>()
        val pass = HashMap<String, String>()

        fun group(name: String, password: String = "") { groups.getOrPut(name) { LinkedHashMap() }; if (password.isNotEmpty()) pass[name] = password }

        fun add(group: String, ch: LiveChannel) {
            val map = groups.getOrPut(group) { LinkedHashMap() }
            val old = map[ch.name]
            if (old == null) { map[ch.name] = ch; return }
            val own = ch.headers.isNotEmpty() && ch.headers != old.headers
            val urls = ch.urls.map { u ->
                if (!own || u.contains('|')) u
                else u.substringBefore('$') + "|" + ch.headers.entries.joinToString("&") { (k, v) -> "$k=" + java.net.URLEncoder.encode(v, "UTF-8").replace("+", "%20") } + (if (u.contains('$')) "$" + u.substringAfter('$') else "")
            }
            map[ch.name] = old.copy(urls = (old.urls + urls).distinct(), logo = old.logo.ifEmpty { ch.logo }, tvgId = old.tvgId.ifEmpty { ch.tvgId }, tvgName = old.tvgName.ifEmpty { ch.tvgName }, catchup = old.catchup ?: ch.catchup)
        }

        fun build(): List<LiveGroup> = groups.mapNotNull { (n, map) -> if (map.isEmpty()) null else LiveGroup(n, pass[n].orEmpty(), map.values.toList()) }
    }

    /** `url#url2` — a '#' only separates when an address follows it. */
    private fun splitUrls(s: String): List<String> {
        val out = ArrayList<String>()
        for (p in s.split('#')) { if (p.contains("://") || out.isEmpty()) out += p.trim() else out[out.lastIndex] = out.last() + "#" + p }
        return out.filter { it.contains("://") }
    }

    private class Setting {
        val headers = LinkedHashMap<String, String>()
        val drm = LinkedHashMap<String, String>()
        var parse = false
        var click = ""
        var format = ""

        fun clear() { headers.clear(); drm.clear(); parse = false; click = ""; format = "" }

        /** Directive line (`ua=…`, `#EXTVLCOPT:`, `#KODIPROP:`, `#EXTHTTP:` …). */
        fun take(line: String): Boolean {
            val l = line.lowercase()
            fun value() = line.substringAfter('=').trim().trim('"')
            when {
                l.startsWith("#extvlcopt:") -> {
                    val body = line.substring(11); val k = body.substringBefore('=').trim().lowercase()
                    when (k) { "http-user-agent", "http-referrer", "http-referer", "http-origin", "http-cookie" -> headers[TVBoxUrl.headerName(k)] = value() }
                }
                l.startsWith("#exthttp:") -> LenientJson.objectOrNull(line.substring(9).trim())?.let { o -> o.keys().forEach { k -> headers[TVBoxUrl.headerName(k)] = J.str(o.opt(k)) } }
                l.startsWith("#kodiprop:") -> {
                    val body = line.substring(10); val k = body.substringBefore('=').trim().lowercase()
                    when {
                        k.endsWith("stream_headers") || k.endsWith("common_headers") || k.endsWith("manifest_headers") -> headers += TVBoxUrl.headerQuery(value())
                        k.endsWith("manifest_type") -> format = mime(value())
                        k.endsWith("license_type") -> drm["type"] = value()
                        k.endsWith("license_key") -> drm["key"] = value()
                        k.endsWith("drm_legacy") -> value().split('|').let { drm["type"] = it[0]; it.getOrNull(1)?.let { key -> drm["key"] = key } }
                    }
                }
                l.startsWith("ua=") -> headers["User-Agent"] = value()
                l.startsWith("referer=") -> headers["Referer"] = value()
                l.startsWith("origin=") -> headers["Origin"] = value()
                l.startsWith("header=") -> headers += TVBoxConfig.headerMap(line.substringAfter('='))
                l.startsWith("parse=") -> parse = value() == "1"
                l.startsWith("click=") -> click = value()
                l.startsWith("format=") -> format = mime(value())
                else -> return false
            }
            return true
        }
    }

    fun mime(f: String): String = when (f.lowercase()) {
        "hls", "m3u8" -> "application/x-mpegURL"
        "dash", "mpd" -> "application/dash+xml"
        "flv" -> "video/x-flv"
        "ts", "mpegts" -> "video/mp2t"
        else -> f
    }

    private fun text(t: String, skipPass: Boolean): List<LiveGroup> {
        val b = Builder()
        val setting = Setting()
        var group = DEFAULT_GROUP
        for (raw in t.lineSequence()) {
            val line = raw.trim()
            if (line.isEmpty() || setting.take(line)) continue
            val comma = line.indexOf(',')
            if (comma < 0) continue
            val left = line.substring(0, comma).trim()
            val right = line.substring(comma + 1).trim()
            if (right.contains("#genre#", true)) {
                setting.clear()
                val cut = left.lastIndexOf('_')
                group = (if (cut > 0) left.substring(0, cut) else left).ifEmpty { DEFAULT_GROUP }
                b.group(group, if (cut > 0 && !skipPass) left.substring(cut + 1).trim() else "")
                continue
            }
            val urls = splitUrls(right)
            if (left.isNotEmpty() && urls.isNotEmpty()) b.add(group, LiveChannel(left, urls, headers = setting.headers.toMap(), parse = setting.parse, click = setting.click, format = setting.format, drm = setting.drm.toMap()))
        }
        return b.build()
    }

    private val ATTR = Regex("([A-Za-z][\\w-]*)=(?:\"([^\"]*)\"|([^\\s,\"]+))")
    private fun attrs(line: String): Map<String, String> = ATTR.findAll(line).associate { it.groupValues[1].lowercase() to it.groupValues[2].ifEmpty { it.groupValues[3] } }

    /** Title after the first comma outside quotes. */
    private fun splitInf(line: String): Pair<String, String> {
        var quoted = false
        for (i in line.indices) {
            if (line[i] == '"') quoted = !quoted
            else if (line[i] == ',' && !quoted) return line.substring(0, i) to line.substring(i + 1).trim()
        }
        val c = line.lastIndexOf(',')
        return if (c < 0) line to "" else line.substring(0, c) to line.substring(c + 1).trim()
    }

    private fun catchup(a: Map<String, String>): Catchup? {
        val type = a["catchup"] ?: a["catchup-type"] ?: ""
        val source = a["catchup-source"].orEmpty()
        if (type.isEmpty() && source.isEmpty()) return null
        return Catchup(type.lowercase(), source, (a["catchup-days"] ?: a["tvg-rec"] ?: a["timeshift"])?.toDoubleOrNull()?.toInt() ?: 0, a["catchup-replace"].orEmpty())
    }

    private fun m3u(t: String): LiveList {
        val b = Builder()
        val setting = Setting()
        var epg = ""
        var defaults: Catchup? = null
        var inf: Map<String, String>? = null
        var name = ""
        var extGroup = ""
        for (raw in t.lineSequence()) {
            val line = raw.trim()
            when {
                line.isEmpty() -> {}
                line.startsWith("#EXTM3U", true) -> {
                    val a = attrs(line)
                    epg = J.firstNonEmpty(a["x-tvg-url"].orEmpty(), a["url-tvg"].orEmpty(), a["tvg-url"].orEmpty(), epg)
                    defaults = catchup(a) ?: defaults
                }
                line.startsWith("#EXTINF", true) -> { val (head, title) = splitInf(line); inf = attrs(head); name = title }
                line.startsWith("#EXTGRP:", true) -> extGroup = line.substring(8).trim()
                line.startsWith("#") -> setting.take(line)
                else -> {
                    val a = inf
                    if (a == null) {
                        // plain `name,url` rows mixed into an M3U
                        val comma = line.indexOf(',')
                        if (comma > 0 && line.indexOf("://") > comma) b.add(extGroup.ifEmpty { DEFAULT_GROUP }, LiveChannel(line.substring(0, comma).trim(), splitUrls(line.substring(comma + 1).trim())))
                    } else if (line.contains("://") || line.startsWith("/")) {
                        val title = name.ifEmpty { a["tvg-name"].orEmpty() }.ifEmpty { a["tvg-id"].orEmpty() }.ifEmpty { TVBoxUrl.host(line) }
                        val own = LinkedHashMap(setting.headers)
                        (a["http-user-agent"] ?: a["user-agent"])?.let { own.putIfAbsent("User-Agent", it) }
                        (a["http-referrer"] ?: a["http-referer"] ?: a["referer"])?.let { own.putIfAbsent("Referer", it) }
                        val group = (a["group-title"] ?: extGroup).substringBefore(';').trim().ifEmpty { DEFAULT_GROUP }
                        b.add(group, LiveChannel(
                            title, splitUrls(line).ifEmpty { listOf(line) }, a["tvg-logo"].orEmpty(), a["tvg-id"].orEmpty(), a["tvg-name"].orEmpty(), own,
                            epg = a["tvg-url"].orEmpty(), catchup = catchup(a) ?: defaults, format = setting.format, parse = setting.parse, click = setting.click, drm = setting.drm.toMap(),
                        ))
                    }
                    inf = null; name = ""; setting.clear()
                }
            }
        }
        return LiveList(b.build(), epg, defaults)
    }

    fun json(a: JSONArray): List<LiveGroup> {
        val b = Builder()
        for (e in J.arr(a)) {
            val g = e as? JSONObject ?: continue
            val channels = g.optJSONArray("channel") ?: g.optJSONArray("channels") ?: continue
            val name = J.firstNonEmpty(J.str(g.opt("group")), J.str(g.opt("name"))).ifEmpty { DEFAULT_GROUP }
            b.group(name, J.str(g.opt("pass")).trim())
            for (c in J.arr(channels)) {
                val o = c as? JSONObject ?: continue
                val urls = ((o.opt("urls") as? JSONArray)?.let { list -> J.arr(list).map { J.str(it).trim() } } ?: splitUrls(J.firstNonEmpty(J.str(o.opt("urls")), J.str(o.opt("url")))))
                    .map(TVBoxConfig::proxyLive).filter { it.isNotEmpty() }
                val title = J.str(o.opt("name")).trim()
                if (title.isEmpty() || urls.isEmpty()) continue
                val headers = LinkedHashMap(TVBoxConfig.headerMap(o.opt("header") ?: o.opt("headers")))
                J.str(o.opt("ua")).takeIf { it.isNotEmpty() }?.let { headers["User-Agent"] = it }
                J.str(o.opt("referer")).takeIf { it.isNotEmpty() }?.let { headers["Referer"] = it }
                J.str(o.opt("origin")).takeIf { it.isNotEmpty() }?.let { headers["Origin"] = it }
                b.add(name, LiveChannel(
                    title, urls, J.str(o.opt("logo")), J.str(o.opt("tvgId")), J.str(o.opt("tvgName")), headers, J.str(o.opt("epg")).takeIf { it.contains("://") }.orEmpty(),
                    (o.opt("catchup") as? JSONObject)?.let(Catchup::fromJSON), mime(J.str(o.opt("format"))), J.int(o.opt("parse")) == 1, J.str(o.opt("click")),
                ))
            }
        }
        return b.build()
    }
}
