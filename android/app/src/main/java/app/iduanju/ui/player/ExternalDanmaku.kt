package app.iduanju.ui.player

import app.iduanju.core.hongguo.HGDanmaku
import app.iduanju.core.hongguo.HGDanmakuResult
import app.iduanju.core.tvbox.LenientJson
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream

/** Comments delivered with a TVBox stream: Bilibili XML (`<d p="time,mode,size,color,…">`) or DPlayer-style JSON. */
internal object ExternalDanmaku {
    private const val MAX_BYTES = 8 shl 20
    private const val MAX_ITEMS = 6_000
    /** Seconds; NaN, infinite and absurd values fall out with the comparison. */
    private const val MAX_TIME = 360_000.0
    private val node = Regex("""<d\s+[^>]*?p="([^"]*)"[^>]*>(.*?)</d>""", RegexOption.DOT_MATCHES_ALL)

    /** Blocking; call off the main thread. [lan]: may the address lead into the local network. */
    fun fetch(url: String, lan: Boolean = true): HGDanmakuResult = try {
        val text = PlayerHttp.client(lan).newCall(Request.Builder().url(url).header("User-Agent", app.iduanju.core.cms.MacCMS.UA).build()).execute().use { resp ->
            if (!resp.isSuccessful) return HGDanmakuResult(emptyList(), error = "弹幕 HTTP ${resp.code}")
            val body = resp.body ?: return HGDanmakuResult(emptyList())
            // OkHttp only undoes gzip; the Bilibili endpoint answers with a raw deflate stream.
            val raw = body.byteStream()
            val stream = if (resp.header("Content-Encoding").equals("deflate", true)) InflaterInputStream(raw, Inflater(true)) else raw
            String(readLimited(stream), Charsets.UTF_8)
        }
        val items = parse(text)
        HGDanmakuResult(items.take(MAX_ITEMS), truncated = items.size > MAX_ITEMS)
    } catch (e: Exception) { HGDanmakuResult(emptyList(), error = "弹幕加载失败") }

    private fun readLimited(s: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(32 * 1024)
        while (true) {
            val n = s.read(buf)
            if (n < 0) break
            out.write(buf, 0, n)
            if (out.size() > MAX_BYTES) break
        }
        return out.toByteArray()
    }

    fun parse(text: String): List<HGDanmaku> {
        val t = text.trimStart('﻿', ' ', '\n', '\r', '\t')
        return (if (t.startsWith("{") || t.startsWith("[")) json(t) else xml(t)).filter { it.text.isNotBlank() && it.time in 0.0..MAX_TIME }.sortedBy { it.time }
    }

    private fun xml(t: String): List<HGDanmaku> = node.findAll(t).mapNotNull { m ->
        val p = m.groupValues[1].split(',')
        val time = p.getOrNull(0)?.toDoubleOrNull() ?: return@mapNotNull null
        HGDanmaku(time, unescape(m.groupValues[2]), color = color(p.getOrNull(3)), mode = mode(p.getOrNull(1)))
    }.toList()

    private fun json(t: String): List<HGDanmaku> = runCatching {
        val root = LenientJson.parse(t)
        val list: JSONArray = when (root) {
            is JSONArray -> root
            is JSONObject -> listOf("danmuku", "danmaku", "data", "comments", "list").firstNotNullOfOrNull { k ->
                root.optJSONArray(k) ?: root.optJSONObject(k)?.let { it.optJSONArray("danmuku") ?: it.optJSONArray("comments") ?: it.optJSONArray("list") }
            } ?: JSONArray()
            else -> JSONArray()
        }
        (0 until list.length()).mapNotNull { i -> item(list.opt(i)) }
    }.getOrDefault(emptyList())

    private fun item(v: Any?): HGDanmaku? = when (v) {
        // [time, mode, color, author, text]
        is JSONArray -> {
            val time = v.optDouble(0, Double.NaN)
            val text = (4 downTo 1).firstNotNullOfOrNull { v.optString(it).takeIf { s -> s.isNotBlank() && it == 4 || v.length() <= 4 && it == v.length() - 1 } }
            if (time.isNaN() || text == null) null else HGDanmaku(time, text, color = color(v.optString(2)), mode = mode(v.optString(1)))
        }
        is JSONObject -> {
            val p = v.optString("p").split(',')
            val time = if (v.has("time")) v.optDouble("time", Double.NaN) else p.getOrNull(0)?.toDoubleOrNull() ?: Double.NaN
            val text = v.optString("text").ifBlank { v.optString("m").ifBlank { v.optString("content") } }
            if (time.isNaN() || text.isBlank()) null
            else HGDanmaku(time, text, color = color(v.optString("color").ifBlank { p.getOrNull(2).orEmpty() }), mode = mode(v.optString("mode").ifBlank { p.getOrNull(1).orEmpty() }))
        }
        else -> null
    }

    private fun mode(s: String?): HGDanmaku.Mode = when (s?.trim()?.lowercase()) {
        "5", "top" -> HGDanmaku.Mode.top
        "4", "bottom" -> HGDanmaku.Mode.bottom
        else -> HGDanmaku.Mode.scroll
    }

    private fun color(s: String?): String {
        val v = s?.trim().orEmpty()
        if (v.startsWith("#") && (v.length == 7 || v.length == 4)) return if (v.length == 7) v else "#" + v.drop(1).map { "$it$it" }.joinToString("")
        val n = v.toLongOrNull() ?: return "#FFFFFF"
        return "#%06X".format(n and 0xFFFFFF)
    }

    private fun unescape(s: String): String = s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&#39;", "'").replace("&amp;", "&").trim()
}
