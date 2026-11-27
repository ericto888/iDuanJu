package app.iduanju.core.plugin

import app.iduanju.core.cms.CMSCategory
import app.iduanju.core.hongguo.*
import app.iduanju.core.util.ContentFilter
import app.iduanju.core.util.NetGuard
import app.iduanju.core.util.ProviderException
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

/** iOS PluginOut — sanitising readers for plugin output. */
object PluginOut {
    val allowedHeaders = setOf("referer", "user-agent", "origin", "accept", "accept-language")
    fun s(v: Any?, max: Int = 300): String = when (v) { is String -> v; is Number -> v.toString(); else -> "" }.trim().take(max)
    fun url(v: Any?): String { val u = s(v, 2000); return if (u.startsWith("https://") || u.startsWith("http://")) u else "" }
    fun strings(v: Any?, max: Int = 30): List<String> { val a = v as? JSONArray ?: return emptyList(); return (0 until minOf(a.length(), max)).map { s(a.opt(it), 60) }.filter { it.isNotEmpty() } }
    fun headers(v: Any?): Map<String, String> { val o = v as? JSONObject ?: return emptyMap(); return o.keys().asSequence().filter { it.lowercase() in allowedHeaders }.associateWith { s(o.opt(it), 500) }.filterValues { value -> value.none { it.code<32 || it.code==127 } } }
    fun categories(v: Any?): List<CMSCategory> {
        val a = v as? JSONArray ?: return emptyList()
        return (0 until minOf(a.length(), 60)).mapNotNull { i -> val c = a.optJSONObject(i) ?: return@mapNotNull null
            val id = s(c.opt("id")); val name = s(c.opt("name"), 40)
            if (id.isEmpty() || name.isEmpty() || ContentFilter.isBlocked(listOf(name, id))) null else CMSCategory(id, name) }
    }
    fun objs(v: Any?, max: Int): List<JSONObject> { val a = v as? JSONArray ?: return emptyList(); return (0 until minOf(a.length(), max)).mapNotNull { a.optJSONObject(it) } }
}

/** iOS JSVideoProvider — maps idj1 video/shortdrama plugin output onto the app's series/episode/stream models. */
class PluginVideo(val inst: PluginInstance, private val extraDomains: List<String> = emptyList()) {
    val m get() = inst.bundle.manifest
    val pid get() = m.id
    private val media get() = DomainPolicy(m.mediaDomains + m.httpDomains + extraDomains)
    var categories: List<CMSCategory> = emptyList(); private set

    private fun cover(u: String, headers: Map<String, String> = emptyMap()): String {
        val h = runCatching { java.net.URI(u).host }.getOrNull() ?: return ""
        if (!media.allows(h) || NetGuard.isIPLiteral(h)) return ""
        return if (headers.isNotEmpty()) PluginMedia.ref(pid, u, headers) else u
    }

    private fun series(o: JSONObject): HGSeries? {
        val id = PluginOut.s(o.opt("id")); val title = PluginOut.s(o.opt("title"), 200)
        if (id.isEmpty() || title.isEmpty()) return null
        val tags = PluginOut.strings(o.opt("tags")) + PluginOut.strings(o.opt("badges"))
        if (ContentFilter.isBlocked(listOf(title) + tags)) return null
        return HGSeries(seriesId = sid(pid, id), title = title, cover = cover(PluginOut.url(o.opt("cover")), PluginOut.headers(o.opt("coverHeaders"))), subtitle = PluginOut.s(o.opt("remarks"), 40).ifEmpty { null },
            author = PluginOut.strings(o.opt("actors")).joinToString(" ").ifEmpty { null }, orientation = if (o.optString("orientation") == "portrait") "portrait" else null, tags = tags)
    }

    private fun page(v: Any?, p: Int): HGPage {
        val o = v as? JSONObject ?: JSONObject()
        val items = PluginOut.objs(o.opt("items"), 500).mapNotNull(::series)
        return HGPage(items, o.optBoolean("hasMore") && items.isNotEmpty(), p + 1)
    }

    /** categoryId "" = 推荐 (home). */
    fun list(categoryId: String, p: Int): HGPage {
        if (categoryId.isEmpty()) {
            if (p > 1) return HGPage(emptyList(), false)
            val r = inst.call("home", JSONObject()) as? JSONObject ?: JSONObject()
            categories = PluginOut.categories(r.opt("categories"))
            if ((r.optJSONArray("items")?.length() ?: 0) > 0) return page(r, 1)
            val first = categories.firstOrNull() ?: return HGPage(emptyList(), false)
            return page(inst.call("category", JSONObject().put("id", first.id).put("page", 1).put("filters", JSONObject())), 1)
        }
        return page(inst.call("category", JSONObject().put("id", categoryId).put("page", p).put("filters", JSONObject())), p)
    }

    fun search(q: String, p: Int): HGPage = page(inst.call("search", JSONObject().put("keyword", q).put("page", p)), p)

    fun detail(seriesSid: String): HGSeriesDetail {
        val id = parseSid(seriesSid)?.second ?: throw ProviderException.invalid("插件条目 id 无效")
        val o = inst.call("detail", JSONObject().put("id", id)) as? JSONObject ?: JSONObject()
        val title = PluginOut.s(o.opt("title"), 200)
        val tags = PluginOut.strings(o.opt("tags"))
        if (ContentFilter.isBlocked(listOf(title) + tags)) throw ProviderException.unsupported("该内容已被过滤")
        val rawLines = PluginOut.objs(o.opt("lines"), 20)
        val playLines = rawLines.mapIndexedNotNull { li, line ->
            val lineName = PluginOut.s(line.opt("name"), 40).ifEmpty { "线路 ${li + 1}" }
            val lineEps = PluginOut.objs(line.opt("episodes"), 3000).mapIndexedNotNull { i, e ->
                val eid = PluginOut.s(e.opt("id"), 2000); if (eid.isEmpty()) null
                else HGEpisode(i + 1, epVid(pid, id, eid), e.optInt("duration"), PluginOut.s(e.opt("name"), 80).ifEmpty { "第${i + 1}集" }, page = lineName)
            }.mapIndexed { i, e -> e.copy(ep = i + 1) }
            if (lineEps.isEmpty()) null else HGPlayLine(id = "l$li", name = lineName, episodes = lineEps)
        }
        val eps = playLines.firstOrNull()?.episodes.orEmpty()
        return HGSeriesDetail(seriesId = seriesSid, title = title, cover = cover(PluginOut.url(o.opt("cover")), PluginOut.headers(o.opt("coverHeaders"))), desc = org.jsoup.parser.Parser.unescapeEntities(PluginOut.s(o.opt("desc"), 4000), false).replace(Regex("[\\s\\u00a0]+"), " ").trim(),
            author = PluginOut.s(o.opt("director"), 80), actors = PluginOut.strings(o.opt("actors")), totalEps = eps.size, episodes = eps, lines = playLines, tags = tags,
            episodeLabel = if (eps.size > 1) "共${eps.size}集" else "长视频", source = m.name)
    }

    fun resolve(ep: HGEpisode): HGResolvedVideo {
        val (_, sidRaw, eid) = parseEp(ep.vid) ?: throw ProviderException.invalid("插件剧集 id 无效")
        val o = inst.call("play", JSONObject().put("line", ep.page ?: "").put("episodeId", eid).put("id", sidRaw)) as? JSONObject ?: JSONObject()
        val pol = media
        val streams = PluginOut.objs(o.opt("streams"), 12).mapIndexedNotNull { i, st ->
            val u = PluginOut.url(st.opt("url"))
            val url = runCatching { java.net.URI(u) }.getOrNull(); val host = url?.host
            if (url == null || host == null || url.scheme != "https" || url.rawUserInfo != null || (url.port!=-1 && url.port!=443) || !pol.allows(host) || NetGuard.isIPLiteral(host) || (inst.host.fixture==null && NetGuard.resolvesToBlocked(host))) {
                inst.host.log("✕ 丢弃未授权/非 https 的流地址 ${host ?: u.take(40)}"); return@mapIndexedNotNull null
            }
            val fmt = st.optString("format").ifEmpty { if (u.contains(".m3u8")) "hls" else "mp4" }
            val key = PluginOut.s(st.opt("key"), 64)
            val kind = when {
                key.isNotEmpty() || fmt == "cenc" -> HGStreamKind.mp4Cenc
                fmt == "hls" -> HGStreamKind.hls
                else -> HGStreamKind.mp4Clear
            }
            val h = PluginOut.headers(st.opt("headers")).toMutableMap()
            if (h.keys.none { it.equals("user-agent", true) }) h["User-Agent"] = inst.host.learnedUA ?: PluginHost.DEFAULT_UA
            HGStream("p$i", PluginOut.s(st.opt("name"), 40).ifEmpty { host }, u, key = key, kind = kind, headers = h)
        }
        val first = streams.firstOrNull() ?: throw ProviderException.upstream("插件没有返回可播放的地址（需 https 且在 media 白名单内）")
        return HGResolvedVideo(ep.vid, first.url, streams = streams, expiresAt = o.optLong("expiresAt"),
            danmaku = PluginOut.url(o.opt("danmaku")).ifEmpty { null })
    }

    fun hasDanmaku(): Boolean = "danmaku" in m.capabilities || DANMAKU_EXPORT_RE.containsMatchIn(inst.bundle.source)

    /** Official or third-party comments through the plugin's `danmaku` export (docs/plugins/SPEC_ZH.md). Blocking. */
    fun danmaku(episodeVid: String): HGDanmakuResult {
        if (!hasDanmaku()) return HGDanmakuResult(emptyList(), error = "当前片源不支持弹幕")
        val (_, sidRaw, eid) = parseEp(episodeVid) ?: return HGDanmakuResult(emptyList(), error = "插件剧集 id 无效")
        val raw = try {
            val arg = JSONObject()
                .put("episodeKey", eid)
                .put("episodeId", eid)
                .put("seriesId", sidRaw)
                .put("id", sidRaw)
                .put("from", 0)
                .put("to", 0)
            inst.call("danmaku", arg, 27.0)
        } catch (e: PluginException) {
            return HGDanmakuResult(emptyList(), error = e.friendly)
        }
        return parseDanmakuPayload(raw)
    }

    private fun parseDanmakuPayload(raw: Any?): HGDanmakuResult {
        val maxItems = 12_000
        if (raw is String) {
            val items = parseXmlDanmaku(raw, maxItems)
            return HGDanmakuResult(items, truncated = items.size >= maxItems)
        }
        val obj = raw as? JSONObject
        val xml = obj?.optString("xml", "")?.ifEmpty { obj.optString("raw", "") }.orEmpty()
        if (xml.isNotEmpty()) {
            val items = parseXmlDanmaku(xml, maxItems)
            return HGDanmakuResult(items, truncated = items.size >= maxItems)
        }
        val arr: JSONArray = when {
            raw is JSONArray -> raw
            obj != null -> listOf("items", "danmaku", "danmuku", "data", "comments")
                .firstNotNullOfOrNull { obj.optJSONArray(it) } ?: JSONArray()
            else -> JSONArray()
        }
        val items = ArrayList<HGDanmaku>()
        val seen = HashSet<String>()
        for (i in 0 until minOf(arr.length(), maxItems * 2)) {
            val parsed = parseSingleDanmaku(arr.opt(i)) ?: continue
            if (!seen.add(String.format("%.3f|", parsed.time) + parsed.text)) continue
            items.add(parsed)
            if (items.size >= maxItems) break
        }
        items.sortBy { it.time }
        return HGDanmakuResult(items, truncated = (obj?.optBoolean("truncated") == true) || arr.length() > maxItems)
    }

    private fun parseSingleDanmaku(entry: Any?): HGDanmaku? {
        if (entry is JSONArray && entry.length() >= 5) {
            val t = numVal(entry.opt(0)) ?: return null
            if (!t.isFinite() || t < 0 || t > 604_800) return null
            val txt = PluginOut.s(entry.opt(4), 200)
            if (txt.isEmpty()) return null
            return HGDanmaku(t, txt, 0, normColor(entry.opt(2)), normMode(entry.opt(1)))
        }
        val row = entry as? JSONObject ?: return null
        val p = row.optString("p", "")
        if (p.isNotEmpty()) {
            val txt = PluginOut.s(row.opt("m") ?: row.opt("text") ?: row.opt("c"), 200)
            if (txt.isEmpty()) return null
            val fields = p.split(",")
            val t = fields.firstOrNull()?.toDoubleOrNull() ?: return null
            if (!t.isFinite() || t < 0 || t > 604_800) return null
            val colorInt = (if (fields.size >= 5) fields[3] else fields.getOrNull(2))?.toIntOrNull()
            val color = colorInt?.let { String.format("#%06X", it.coerceIn(0, 0xFFFFFF)) } ?: normColor(row.opt("color"))
            val mode = normMode(fields.getOrNull(1) ?: row.opt("mode"))
            return HGDanmaku(t, txt, row.optInt("likes", 0).coerceAtLeast(0), color, mode)
        }
        val text = PluginOut.s(row.opt("text") ?: row.opt("content") ?: row.opt("m"), 200)
        if (text.isEmpty() || text.length > 200) return null
        val time = numVal(row.opt("time")) ?: numVal(row.opt("progress"))?.let { it / 1000.0 } ?: return null
        if (!time.isFinite() || time < 0 || time > 604_800) return null
        return HGDanmaku(time, text, row.optInt("likes", 0).coerceAtLeast(0), normColor(row.opt("color")), normMode(row.opt("mode")))
    }

    private fun parseXmlDanmaku(xml: String, limit: Int): List<HGDanmaku> {
        val out = ArrayList<HGDanmaku>()
        val re = Regex("""<d\b[^>]*\bp\s*=\s*"([^"]+)"[^>]*>([\s\S]*?)</d>""", RegexOption.IGNORE_CASE)
        for (m in re.findAll(xml)) {
            val p = m.groupValues[1]
            val body = m.groupValues[2]
                .replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
                .replace("&quot;", "\"").replace("&apos;", "'").trim()
            val item = parseSingleDanmaku(JSONObject().put("p", p).put("m", body)) ?: continue
            out.add(item)
            if (out.size >= limit) break
        }
        out.sortBy { it.time }
        return out
    }

    private fun numVal(v: Any?): Double? = when (v) {
        is Number -> v.toDouble()
        is String -> v.trim().toDoubleOrNull()
        else -> null
    }

    private fun normColor(raw: Any?): String {
        if (raw is Number) return String.format("#%06X", raw.toInt().coerceIn(0, 0xFFFFFF))
        val s = PluginOut.s(raw, 16).trim()
        if (Regex("^#[0-9A-Fa-f]{6}$").matches(s)) return s.uppercase()
        if (Regex("^[0-9A-Fa-f]{6}$").matches(s)) return "#" + s.uppercase()
        s.toIntOrNull()?.let { return String.format("#%06X", it.coerceIn(0, 0xFFFFFF)) }
        return "#FFFFFF"
    }

    private fun normMode(raw: Any?): HGDanmaku.Mode = when (PluginOut.s(raw, 12).lowercase()) {
        "top", "5" -> HGDanmaku.Mode.top
        "bottom", "4" -> HGDanmaku.Mode.bottom
        else -> HGDanmaku.Mode.scroll
    }

    companion object {
        private val DANMAKU_EXPORT_RE = Regex("""(?:async\s+)?danmaku\s*(?:\(|:)""")
        private fun b64(s: String) = Base64.getUrlEncoder().withoutPadding().encodeToString(s.toByteArray())
        private fun unb64(s: String) = String(Base64.getUrlDecoder().decode(s))
        fun isPlugin(id: String) = id.startsWith("plugin:")
        fun sid(pid: String, id: String) = "plugin:$pid:${b64(id)}"
        fun parseSid(s: String): Pair<String, String>? { val p = s.split(":"); return if (p.size == 3 && p[0] == "plugin") runCatching { p[1] to unb64(p[2]) }.getOrNull() else null }
        fun epVid(pid: String, id: String, ep: String) = "plugin:$pid:${b64(id)}:${b64(ep)}"
        fun parseEp(s: String): Triple<String, String, String>? { val p = s.split(":"); return if (p.size == 4 && p[0] == "plugin") runCatching { Triple(p[1], unb64(p[2]), unb64(p[3])) }.getOrNull() else null }
        fun pluginId(s: String): String? = s.split(":").takeIf { it.size >= 3 && it[0] == "plugin" }?.get(1)
    }
}
