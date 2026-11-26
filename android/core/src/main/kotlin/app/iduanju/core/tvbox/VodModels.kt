package app.iduanju.core.tvbox

import app.iduanju.core.hongguo.HGEpisode
import app.iduanju.core.hongguo.HGPlayLine
import app.iduanju.core.hongguo.HGSeries
import app.iduanju.core.hongguo.HGSeriesDetail
import app.iduanju.core.util.ContentFilter
import app.iduanju.core.util.J
import app.iduanju.core.util.ProviderException
import org.json.JSONArray
import org.json.JSONObject

/** Namespaced ids: `tvb:<uid>:<vod_id>` (episodes `…#<line>#<index>`), `tvl:<uid>` (channels `tvl:<uid>#<index>`). */
object TVBoxId {
    const val VOD = "tvb:"
    const val LIVE = "tvl:"

    fun isVod(sid: String) = sid.startsWith(VOD)
    fun isLive(sid: String) = sid.startsWith(LIVE)
    fun isTVBox(sid: String) = isVod(sid) || isLive(sid)
    fun vod(uid: String, id: String) = "$VOD$uid:$id"
    fun live(uid: String) = "$LIVE$uid"
    fun episode(uid: String, id: String, line: Int, index: Int) = "$VOD$uid:$id#$line#$index"

    data class Vod(val uid: String, val id: String)
    fun parseVod(sid: String): Vod? {
        if (!isVod(sid)) return null
        val rest = sid.substring(VOD.length)
        val i = rest.indexOf(':')
        return if (i <= 0 || i == rest.lastIndex) null else Vod(rest.substring(0, i), rest.substring(i + 1))
    }

    data class Ep(val uid: String, val id: String, val line: Int, val index: Int)
    private val EP = Regex("^(.*)#(\\d+)#(\\d+)$", RegexOption.DOT_MATCHES_ALL)
    fun parseEpisode(vid: String): Ep? {
        val v = parseVod(vid) ?: return null
        val m = EP.find(v.id) ?: return null
        return Ep(v.uid, m.groupValues[1], m.groupValues[2].toInt(), m.groupValues[3].toInt())
    }

    fun liveUid(sid: String): String = sid.removePrefix(LIVE).substringBefore('#')
    fun liveIndex(vid: String): Int = vid.substringAfterLast('#', "").toIntOrNull() ?: -1
}

data class VodCategory(val id: String, val name: String)
data class VodFilter(val key: String, val name: String, val initial: String, val options: List<Pair<String, String>>)

/** One card of a list. [folder]: opens a nested list (`vod_tag=folder`); [action]: handled by the spider's `action`. */
data class VodItem(
    val uid: String, val id: String, val title: String, val cover: String, val remark: String, val tags: List<String> = emptyList(),
    val folder: Boolean = false, val action: String = "", val landscape: Boolean = false,
) {
    val sid: String get() = TVBoxId.vod(uid, id)
    fun series(): HGSeries = HGSeries(seriesId = sid, title = title, cover = cover, subtitle = remark.ifEmpty { null }, orientation = if (landscape) "landscape" else "portrait", tags = tags)
}

data class VodHome(val categories: List<VodCategory>, val filters: Map<String, List<VodFilter>>, val items: List<VodItem>)
data class VodPage(val items: List<VodItem>, val page: Int, val hasMore: Boolean)

/** TVBox result JSON → app models; the content filter is applied to everything that leaves here. */
object VodMapper {
    fun s(v: Any?, max: Int = 300): String = J.str(v).trim().take(max)

    fun root(text: String, what: String): JSONObject {
        if (text.isBlank()) return JSONObject()
        return LenientJson.objectOrNull(text) ?: throw ProviderException.upstream("站点返回的${what}不是 JSON")
    }

    private val TAGS = Regex("<[^>]+>")
    fun plain(html: String): String = html.replace(Regex("(?i)<br\\s*/?>|</p>"), "\n").replace(TAGS, "").replace("&nbsp;", " ").replace("&amp;", "&").replace("&quot;", "\"").replace("&lt;", "<").replace("&gt;", ">").replace("&#39;", "'")
        .replace('　', ' ').lines().joinToString("\n") { it.trim() }.replace(Regex("\n{2,}"), "\n").trim()

    /** [keep]: category names the config wants, in that order. */
    fun home(o: JSONObject, uid: String, keep: List<String>, fix: (String) -> String): VodHome {
        val all = J.arr(o.opt("class")).mapNotNull { c ->
            val e = c as? JSONObject ?: return@mapNotNull null
            val id = s(e.opt("type_id"), 2000); val name = plain(s(e.opt("type_name"), 40))
            if (id.isEmpty() || name.isEmpty() || ContentFilter.isBlocked(listOf(name))) null else VodCategory(id, name)
        }.distinctBy { it.id }
        val cats = if (keep.isEmpty()) all else keep.mapNotNull { n -> all.firstOrNull { it.name == n } }.ifEmpty { all }
        val f = LinkedHashMap<String, List<VodFilter>>()
        (o.opt("filters") as? JSONObject)?.let { fs -> fs.keys().forEach { k -> filters(fs.opt(k)).takeIf { it.isNotEmpty() }?.let { f[k] = it } } }
        return VodHome(cats, f, items(o, uid, fix))
    }

    private fun filters(v: Any?): List<VodFilter> = (if (v is JSONObject) listOf(v) else J.arr(v)).mapNotNull { e ->
        val o = e as? JSONObject ?: return@mapNotNull null
        val options = J.arr(o.opt("value")).mapNotNull { x -> (x as? JSONObject)?.let { s(it.opt("n"), 40) to s(it.opt("v"), 400) } }.filter { it.first.isNotEmpty() && !ContentFilter.isBlocked(listOf(it.first)) }
        val key = s(o.opt("key"), 80)
        if (key.isEmpty() || options.isEmpty()) null else VodFilter(key, s(o.opt("name"), 20).ifEmpty { key }, s(o.opt("init"), 400), options)
    }

    fun items(o: JSONObject, uid: String, fix: (String) -> String): List<VodItem> {
        val ratioOf = { x: JSONObject? -> x?.let { J.double(it.opt("ratio")) } ?: 0.0 }
        val pageRatio = ratioOf(o.optJSONObject("style"))
        return J.arr(o.opt("list")).mapNotNull { e ->
            val v = e as? JSONObject ?: return@mapNotNull null
            val id = J.str(v.opt("vod_id")).trim()
            val title = plain(s(v.opt("vod_name"), 200))
            val action = J.str(v.opt("action"))
            if ((id.isEmpty() && action.isEmpty()) || title.isEmpty()) return@mapNotNull null
            val tags = listOf(s(v.opt("type_name"), 30), s(v.opt("vod_class"), 60)).filter { it.isNotEmpty() }
            if (ContentFilter.isBlocked(listOf(title) + tags)) return@mapNotNull null
            val ratio = ratioOf(v.optJSONObject("style")).let { if (it > 0) it else pageRatio }
            VodItem(uid, id, title, fix(s(v.opt("vod_pic"), 4000)), plain(s(v.opt("vod_remarks"), 60)), tags, s(v.opt("vod_tag"), 20) == "folder" || v.has("cate") && !v.isNull("cate"), action, ratio > 1.1)
        }
    }

    fun page(o: JSONObject, uid: String, page: Int, fix: (String) -> String): VodPage {
        val list = items(o, uid, fix)
        val count = J.int(o.opt("pagecount"))
        val raw = (o.optJSONArray("list")?.length() ?: 0)
        return VodPage(list, page, raw > 0 && (count <= 0 || page < count))
    }

    data class Line(val flag: String, val eps: List<Pair<String, String>>)

    /** `vod_play_from` / `vod_play_url` → lines; blank names get a number, a single unnamed episode is "正片". */
    fun lines(from: String, url: String): List<Line> {
        val names = from.split("$$$")
        return url.split("$$$").mapIndexedNotNull { i, chunk ->
            val raw = chunk.split('#').map { it.trim() }.filter { it.isNotEmpty() }
            val eps = raw.mapIndexedNotNull { j, e ->
                val p = e.split('$')
                val (name, play) = if (p.size > 1) p[0].trim() to p[1].trim() else "" to e
                if (play.isEmpty()) null else name.ifEmpty { if (raw.size == 1) "正片" else "第${j + 1}集" } to play
            }
            if (eps.isEmpty()) null else Line(names.getOrNull(i)?.trim().orEmpty().ifEmpty { "线路${i + 1}" }, eps)
        }
    }

    fun detail(o: JSONObject, uid: String, id: String, site: TVBoxSite, fix: (String) -> String): HGSeriesDetail {
        val v = J.arr(o.opt("list")).firstOrNull() as? JSONObject ?: throw ProviderException.upstream(J.str(o.opt("msg")).ifEmpty { "站点没有返回详情" })
        val title = plain(s(v.opt("vod_name"), 200))
        val tags = (listOf(s(v.opt("type_name"), 30)) + s(v.opt("vod_class"), 80).split(',', '/', ' ')).map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        if (ContentFilter.isBlocked(listOf(title) + tags)) throw ProviderException.unsupported("该内容已被过滤")
        val lines = lines(J.str(v.opt("vod_play_from")), J.str(v.opt("vod_play_url")))
        if (lines.isEmpty()) throw ProviderException.unsupported("站点没有给出播放列表")
        val sid = TVBoxId.vod(uid, id)
        val play = lines.mapIndexed { li, l ->
            HGPlayLine(li.toString(), l.flag, l.eps.mapIndexed { i, (n, u) ->
                HGEpisode(i + 1, TVBoxId.episode(uid, id, li, i), 0, n, page = l.flag, media = JSONObject().put("f", l.flag).put("id", u).toString())
            })
        }
        val eps = play.first().episodes
        val people = { k: String, n: Int -> plain(s(v.opt(k), 400)).split(Regex("[,，/、]|\\s{2,}")).map { it.trim() }.filter { it.isNotEmpty() && it != "未知" }.take(n) }
        val meta = listOf(s(v.opt("vod_year"), 20), s(v.opt("vod_area"), 40), s(v.opt("vod_lang"), 20), plain(s(v.opt("vod_remarks"), 60))).map { it.trim() }.filter { it.isNotEmpty() }.distinct().joinToString(" · ")
        return HGSeriesDetail(
            seriesId = sid, title = title, cover = fix(s(v.opt("vod_pic"), 4000)), desc = listOf(meta, plain(s(v.opt("vod_content"), 6000))).filter { it.isNotEmpty() }.joinToString("\n"),
            author = people("vod_director", 3).joinToString(" / "), actors = people("vod_actor", 16), totalEps = eps.size, episodes = eps, tags = tags,
            episodeLabel = if (eps.size > 1) "共${eps.size}集" else "长视频", source = site.name, lines = play,
        )
    }

    /** `proxy://do=…` and hard-coded `127.0.0.1:9978` addresses → the running local proxy. */
    fun localProxy(u: String, port: Int, siteKey: String): String {
        if (u.startsWith("proxy://")) {
            val q = u.substring(8)
            val need = Regex("(?:^|&)do=(js|py)(?:&|$)").containsMatchIn(q) && !q.contains("siteKey=")
            return "http://127.0.0.1:$port/proxy?$q" + (if (need) "&siteKey=" + java.net.URLEncoder.encode(siteKey, "UTF-8") else "")
        }
        return if (port == 9978) u else u.replace("http://127.0.0.1:9978/proxy", "http://127.0.0.1:$port/proxy").replace("http://localhost:9978/proxy", "http://127.0.0.1:$port/proxy")
    }

    fun filtersJSON(list: List<VodFilter>): JSONArray = JSONArray(list.map { f -> JSONObject().put("key", f.key).put("name", f.name).put("init", f.initial).put("value", JSONArray(f.options.map { JSONObject().put("n", it.first).put("v", it.second) })) })
}
