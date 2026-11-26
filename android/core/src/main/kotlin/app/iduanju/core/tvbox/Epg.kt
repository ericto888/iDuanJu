package app.iduanju.core.tvbox

import app.iduanju.core.util.Bytes
import app.iduanju.core.util.J
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.BufferedInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.GZIPInputStream

data class Programme(val start: Long, val end: Long, val title: String, val desc: String = "")

object EpgParser {
    /** `{name}` / `{date}` templates (also `{id}`, `{epg}`, `{logo}`). */
    fun url(template: String, name: String, date: String, id: String = ""): String =
        template.replace("{name}", name).replace("{date}", date).replace("{id}", id.ifEmpty { name }).replace("{epg}", name)

    fun isTemplate(u: String) = u.contains("{name}") || u.contains("{date}") || u.contains("{epg}") || u.contains("{id}")

    /** Guide names differ in spacing, dashes and case: `CCTV-1 综合` ~ `cctv1综合`. */
    fun key(name: String): String = name.lowercase(Locale.ROOT).filter { it.isLetterOrDigit() || it == '+' }

    fun day(at: Long, zone: TimeZone = TimeZone.getDefault()): String = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = zone }.format(Date(at))

    /** DIYP-style `{"epg_data":[{"title","start":"08:00","end":"09:00"}]}`; end before start runs past midnight. */
    fun json(text: String, date: String, zone: TimeZone = TimeZone.getDefault()): List<Programme> {
        val o = when (val v = runCatching { LenientJson.parse(text) }.getOrNull()) { is JSONObject -> v; is JSONArray -> JSONObject().put("epg_data", v); else -> return emptyList() }
        val rows = listOf("epg_data", "data", "list", "programs", "epg").firstNotNullOfOrNull { o.optJSONArray(it) } ?: return emptyList()
        val f = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).apply { timeZone = zone }
        fun at(raw: String): Long? {
            val t = raw.trim()
            t.toLongOrNull()?.let { return if (it > 100_000_000_000L) it else if (it > 1_000_000_000L) it * 1000 else null }
            val hm = Regex("(\\d{1,2}):(\\d{2})").find(t) ?: return null
            val d = Regex("\\d{4}-\\d{2}-\\d{2}").find(t)?.value ?: date
            return runCatching { f.parse("$d ${hm.value}")?.time }.getOrNull()
        }
        return J.arr(rows).mapNotNull { e ->
            val p = e as? JSONObject ?: return@mapNotNull null
            val title = J.firstNonEmpty(J.str(p.opt("title")), J.str(p.opt("name")))
            val start = at(J.firstNonEmpty(J.str(p.opt("start")), J.str(p.opt("start_time")), J.str(p.opt("startTime")))) ?: return@mapNotNull null
            var end = at(J.firstNonEmpty(J.str(p.opt("end")), J.str(p.opt("end_time")), J.str(p.opt("endTime")))) ?: return@mapNotNull null
            if (end <= start) end += 86_400_000L
            if (title.isEmpty() || start !in SANE || end !in SANE) null else Programme(start, end, title.trim(), J.str(p.opt("desc")))
        }.sortedBy { it.start }
    }

    /** 2000 – 2100: anything else is a typo in the guide. */
    private val SANE = 946_684_800_000L..4_102_444_800_000L

    /** XMLTV, streamed; a document that breaks off counts as far as it goes. [wanted] = guide keys to keep (null = everything); returns key → programmes inside the window. */
    fun xmltv(input: InputStream, wanted: Set<String>?, from: Long, to: Long, zone: TimeZone = TimeZone.getDefault()): Map<String, List<Programme>> {
        val parser = XmlPullParserFactory.newInstance().newPullParser()
        parser.setInput(input, null)
        val names = HashMap<String, MutableSet<String>>()
        val out = HashMap<String, ArrayList<Programme>>()
        var channel = ""
        try {
            while (true) {
                when (parser.next()) {
                    XmlPullParser.END_DOCUMENT -> break
                    XmlPullParser.START_TAG -> when (parser.name) {
                        "channel" -> { channel = parser.getAttributeValue(null, "id").orEmpty(); names.getOrPut(channel) { linkedSetOf(key(channel)) } }
                        "display-name" -> { val n = key(parser.nextText()); if (n.isNotEmpty()) names.getOrPut(channel) { linkedSetOf() } += n }
                        "programme" -> {
                            val id = parser.getAttributeValue(null, "channel").orEmpty()
                            val keys = names[id] ?: setOf(key(id))
                            val start = time(parser.getAttributeValue(null, "start").orEmpty(), zone)
                            val stop = time(parser.getAttributeValue(null, "stop").orEmpty(), zone)
                            if ((wanted != null && keys.none { it in wanted }) || start == null || stop == null || stop < from || start > to) continue
                            var title = ""
                            while (!(parser.next() == XmlPullParser.END_TAG && parser.name == "programme")) {
                                if (parser.eventType == XmlPullParser.END_DOCUMENT) break
                                if (parser.eventType == XmlPullParser.START_TAG && parser.name == "title" && title.isEmpty()) title = parser.nextText().trim()
                            }
                            if (title.isNotEmpty()) for (k in keys) if (wanted == null || k in wanted) out.getOrPut(k) { ArrayList() } += Programme(start, stop, title)
                        }
                    }
                }
            }
        } catch (_: Exception) { }
        return out.mapValues { (_, v) -> v.distinctBy { it.start }.sortedBy { it.start } }
    }

    private val STAMP = Regex("^(\\d{8})(\\d{2})(\\d{2})(\\d{2})?\\s*([+-]\\d{2}:?\\d{2}|Z)?")
    private fun time(raw: String, zone: TimeZone): Long? {
        val m = STAMP.find(raw.trim()) ?: return null
        val z = m.groupValues[5]
        val f = SimpleDateFormat("yyyyMMddHHmmss", Locale.US)
        f.timeZone = when { z.isEmpty() -> zone; z == "Z" -> TimeZone.getTimeZone("UTC"); else -> TimeZone.getTimeZone("GMT" + z.substring(0, 3) + ":" + z.takeLast(2)) }
        return runCatching { f.parse(m.groupValues[1] + m.groupValues[2] + m.groupValues[3] + m.groupValues[4].ifEmpty { "00" })?.time }.getOrNull()
    }
}

/** Programme guides with a disk cache: template JSON per channel and day, XMLTV files per address. */
class EpgService(private val dir: File) {
    private val days = ConcurrentHashMap<String, List<Programme>>()
    /** Per address and channel list: usable until, programmes. */
    private val guides = ConcurrentHashMap<String, Pair<Long, Map<String, List<Programme>>>>()
    private val locks = ConcurrentHashMap<String, Mutex>()

    suspend fun programmes(http: TVBoxHttp, epg: String, ch: LiveChannel, channels: Set<String>, at: Long, zone: TimeZone): List<Programme> {
        for (source in epg.split(',').map { it.trim() }.filter { it.contains("://") }) {
            val list = try { if (EpgParser.isTemplate(source)) day(http, source, ch, at, zone) else xml(http, source, ch, channels, at, zone) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { emptyList() }
            if (list.isNotEmpty()) return list
        }
        return emptyList()
    }

    private suspend fun day(http: TVBoxHttp, template: String, ch: LiveChannel, at: Long, zone: TimeZone): List<Programme> {
        val date = EpgParser.day(at, zone)
        val url = EpgParser.url(template, ch.guideName, date, ch.tvgId)
        days[url]?.let { return it }
        val f = File(dir, "d-" + Bytes.hex(Bytes.md5(url)))
        val list = lock(url).withLock {
            days[url]?.let { return it }
            withContext(Dispatchers.IO) {
                val fresh = if (date == EpgParser.day(System.currentTimeMillis(), zone)) 2 * 3600_000L else 24 * 3600_000L
                val cached = if (f.isFile && System.currentTimeMillis() - f.lastModified() < fresh) EpgParser.json(f.readText(), date, zone) else emptyList()
                cached.ifEmpty {
                    val text = http.text(url, emptyMap(), 8_000)
                    EpgParser.json(text, date, zone).also { if (it.isNotEmpty()) write(f, text.toByteArray()) }
                }
            }
        }
        if (days.size > 600) days.clear()
        days[url] = list
        return list
    }

    private suspend fun xml(http: TVBoxHttp, url: String, ch: LiveChannel, channels: Set<String>, at: Long, zone: TimeZone): List<Programme> {
        val map = guide(http, url, channels, zone)
        val keys = listOf(ch.tvgId, ch.tvgName, ch.name).map(EpgParser::key).filter { it.isNotEmpty() }
        val all = keys.firstNotNullOfOrNull { map[it]?.takeIf { l -> l.isNotEmpty() } } ?: return emptyList()
        val c = Calendar.getInstance(zone).apply { timeInMillis = at; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }
        val from = c.timeInMillis
        return all.filter { it.end > from && it.start < from + 86_400_000L }
    }

    private suspend fun guide(http: TVBoxHttp, url: String, channels: Set<String>, zone: TimeZone): Map<String, List<Programme>> {
        val id = url + "|" + channels.hashCode()
        guides[id]?.let { (t, m) -> if (System.currentTimeMillis() < t) return m }
        return lock(url).withLock {
            guides[id]?.let { (t, m) -> if (System.currentTimeMillis() < t) return m }
            withContext(Dispatchers.IO) {
                val f = File(dir, "x-" + Bytes.hex(Bytes.md5(url)))
                if (!f.isFile || System.currentTimeMillis() - f.lastModified() > GUIDE_MS) download(http, url, f)
                val now = System.currentTimeMillis()
                val map = if (f.isFile) runCatching { BufferedInputStream(f.inputStream()).use { s -> EpgParser.xmltv(unzip(s), channels, now - 7 * 86_400_000L, now + 2 * 86_400_000L, zone) } }.getOrDefault(emptyMap()) else emptyMap()
                if (guides.size > 3) guides.clear()
                // nothing usable: asked again soon, but not once per channel
                guides[id] = now + (if (map.isEmpty()) RETRY_MS else 3 * 3600_000L) to map
                map
            }
        }
    }

    /** Only a guide replaces the one on disk; after a failure that one serves on and the server is asked again later. */
    private fun download(http: TVBoxHttp, url: String, f: File) {
        dir.mkdirs()
        val tmp = File(dir, f.name + ".tmp")
        try {
            val r = http.save(NetRequest(url, timeoutMs = 45_000, maxBytes = 60 shl 20), tmp)
            if (!r.ok || !isGuide(tmp)) throw IOException("不是节目单")
            f.delete()
            if (!tmp.renameTo(f)) throw IOException("无法保存节目单")
            tidy()
        } catch (_: Exception) { if (f.isFile) f.setLastModified(System.currentTimeMillis() - GUIDE_MS + RETRY_MS) } finally { tmp.delete() }
    }

    private fun isGuide(f: File): Boolean = runCatching {
        val buf = ByteArray(4096)
        var n = 0
        BufferedInputStream(f.inputStream()).use { s -> val u = unzip(s); while (n < buf.size) { val r = u.read(buf, n, buf.size - n); if (r < 0) break; n += r } }
        val head = String(buf, 0, n, Charsets.ISO_8859_1).lowercase(Locale.ROOT)
        TV.containsMatchIn(head) || (head.contains("<?xml") && !head.contains("<html") && !head.contains("<!doctype html"))
    }.getOrDefault(false)

    private fun unzip(s: BufferedInputStream): InputStream {
        s.mark(4)
        val a = s.read(); val b = s.read()
        s.reset()
        return if (a == 0x1f && b == 0x8b) GZIPInputStream(s, 64 * 1024) else s
    }

    private fun write(f: File, b: ByteArray) {
        dir.mkdirs()
        tidy()
        runCatching { f.writeBytes(b) }
    }

    private fun tidy() { dir.listFiles()?.takeIf { it.size > 800 }?.sortedBy { it.lastModified() }?.take(300)?.forEach { it.delete() } }

    private fun lock(k: String) = locks.getOrPut(k) { Mutex() }

    companion object {
        private const val GUIDE_MS = 6 * 3600_000L
        private const val RETRY_MS = 5 * 60_000L
        private val TV = Regex("<tv[\\s>]")

        /** (now, next) at [at]. */
        fun nowNext(list: List<Programme>, at: Long): Pair<Programme?, Programme?> {
            val i = list.indexOfFirst { at >= it.start && at < it.end }
            return if (i >= 0) list[i] to list.getOrNull(i + 1) else null to list.firstOrNull { it.start > at }
        }
    }
}
