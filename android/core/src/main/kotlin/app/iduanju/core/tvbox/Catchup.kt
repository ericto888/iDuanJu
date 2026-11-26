package app.iduanju.core.tvbox

import app.iduanju.core.util.J
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** 回看: builds the replay address of a programme from a live address and a `catchup` template. */
data class Catchup(val type: String, val source: String, val days: Int = 0, val replace: String = "") {
    fun toJSON(): JSONObject = JSONObject().put("type", type).put("source", source).put("days", days).put("replace", replace)

    val usable: Boolean get() = type.isNotEmpty() || source.isNotEmpty()

    /** [start] / [end] / [now] in epoch milliseconds; null when the type is unknown. */
    fun url(stream: String, start: Long, end: Long, now: Long = System.currentTimeMillis(), zone: TimeZone = TimeZone.getDefault()): String? {
        val base = replace.split(',', limit = 2).let { if (it.size == 2 && it[0].isNotEmpty()) stream.replace(it[0], it[1]) else stream }
        val text = expand(source, start, end, now, zone)
        return when (type.ifEmpty { if (source.startsWith("http", true)) "default" else "append" }) {
            "default" -> when { text.isEmpty() -> null; TVBoxUrl.isHttp(text) || text.contains("://") -> text; else -> append(base, text) }
            "append" -> if (text.isEmpty()) null else append(base, text)
            "shift", "timeshift" -> append(base, text.ifEmpty { "utc=${start / 1000}&lutc=${now / 1000}" }.let { if (it.startsWith("?") || it.startsWith("&")) it else "?$it" })
            "flussonic", "flussonic-hls", "fs", "flussonic-ts" -> flussonic(base, start, end, type == "flussonic-ts")
            "xc" -> xtream(base, start, end, zone)
            else -> if (text.isEmpty()) null else if (text.contains("://")) text else append(base, text)
        }
    }

    private fun append(base: String, tail: String): String =
        if (tail.startsWith("?") && base.contains('?')) base + "&" + tail.substring(1) else if (tail.startsWith("&") && !base.contains('?')) base + "?" + tail.substring(1) else base + tail

    private fun flussonic(base: String, start: Long, end: Long, ts: Boolean): String {
        val query = base.substringAfter('?', "").let { if (it.isEmpty()) "" else "?$it" }
        val path = base.substringBefore('?')
        val dir = path.substringBeforeLast('/')
        val file = path.substringAfterLast('/')
        val from = start / 1000
        if (ts || file == "mpegts") return "$dir/timeshift_abs-$from.ts$query"
        return "$dir/${file.substringBeforeLast('.')}-$from-${(end - start) / 1000}.${file.substringAfterLast('.', "m3u8")}$query"
    }

    private val xc get() = Regex("^(https?://[^/]+)/(?:live/)?([^/]+)/([^/]+)/([^/]+?)(\\.[^/.]+)?$")
    private fun xtream(base: String, start: Long, end: Long, zone: TimeZone): String? = xc.find(base)?.let { m ->
        val (host, user, pass, id, ext) = m.destructured
        val f = SimpleDateFormat("yyyy-MM-dd:HH-mm", Locale.US).apply { timeZone = zone }
        "$host/timeshift/$user/$pass/${(end - start) / 60_000}/${f.format(Date(start))}/$id${ext.ifEmpty { ".ts" }}"
    }

    companion object {
        fun fromJSON(o: JSONObject): Catchup? = Catchup(J.str(o.opt("type")).lowercase(), J.str(o.opt("source")), J.int(o.opt("days")), J.str(o.opt("replace"))).takeIf { it.usable }

        /** Carrier IPTV lists without any template: `/PLTV/` streams replay through `/TVOD/`. */
        fun implied(stream: String): Catchup? = if (stream.contains("/PLTV/")) Catchup("append", "?playseek=\${(b)yyyyMMddHHmmss}-\${(e)yyyyMMddHHmmss}", 7, "/PLTV/,/TVOD/") else null

        private val TOKEN = Regex("\\$?\\{([^{}]+)\\}")

        fun expand(template: String, start: Long, end: Long, now: Long, zone: TimeZone): String = TOKEN.replace(template) { m -> token(m.groupValues[1].trim(), start, end, now, zone) ?: m.value }

        private fun token(t: String, start: Long, end: Long, now: Long, zone: TimeZone): String? {
            val at = when { t.startsWith("(b)") -> start; t.startsWith("(e)") -> end; else -> null }
            if (at != null) return stamp(t.substring(3), at, zone)
            val name = t.substringBefore(':')
            val arg = t.substringAfter(':', "")
            fun scaled(seconds: Long) = (seconds / (arg.toLongOrNull()?.takeIf { it > 0 } ?: 1)).toString()
            return when (name) {
                "utc", "start", "timestamp", "utcstart" -> if (arg.isEmpty()) (start / 1000).toString() else kodi(arg, start, zone)
                "utcend", "end" -> if (arg.isEmpty()) (end / 1000).toString() else kodi(arg, end, zone)
                "lutc", "now" -> if (arg.isEmpty()) (now / 1000).toString() else kodi(arg, now, zone)
                "duration" -> scaled((end - start) / 1000)
                "offset" -> scaled((now - start) / 1000)
                "Y", "m", "d", "H", "M", "S" -> kodi(name, start, zone)
                else -> null
            }
        }

        /** `yyyyMMddHHmmss`, `yyyyMMddHHmmss|UTC`, `timestamp`, `unix`. */
        private fun stamp(spec: String, at: Long, zone: TimeZone): String {
            val utc = spec.endsWith("|UTC", true) || spec.endsWith(":utc", true)
            val f = spec.removeSuffix("|UTC").removeSuffix("|utc").removeSuffix(":utc").removeSuffix(":UTC")
            if (f == "timestamp" || f == "unix" || f == "utc") return (at / 1000).toString()
            return runCatching { SimpleDateFormat(f, Locale.US).apply { timeZone = if (utc) TimeZone.getTimeZone("UTC") else zone }.format(Date(at)) }.getOrDefault((at / 1000).toString())
        }

        private fun kodi(spec: String, at: Long, zone: TimeZone): String {
            val map = mapOf('Y' to "yyyy", 'm' to "MM", 'd' to "dd", 'H' to "HH", 'M' to "mm", 'S' to "ss")
            return spec.map { c -> map[c]?.let { SimpleDateFormat(it, Locale.US).apply { timeZone = zone }.format(Date(at)) } ?: c.toString() }.joinToString("")
        }
    }
}
