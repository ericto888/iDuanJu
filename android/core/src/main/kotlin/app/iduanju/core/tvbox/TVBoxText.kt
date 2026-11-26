package app.iduanju.core.tvbox

import app.iduanju.core.util.Bytes
import app.iduanju.core.util.J
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.net.URLDecoder
import java.util.zip.GZIPInputStream
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Address helpers shared by configs, sites and live lists. Strings stay raw: no re-encoding of what the config author wrote. */
object TVBoxUrl {
    private val SCHEME = Regex("^[A-Za-z][A-Za-z0-9+.-]*:")

    fun isHttp(u: String) = u.startsWith("http://", true) || u.startsWith("https://", true)
    fun isLocal(u: String) = u.startsWith("clan://", true) || u.startsWith("file://", true)

    /** `./x` and `../x` against [base]; every other string is returned unchanged. */
    fun resolve(base: String, ref: String): String {
        val r = ref.trim()
        if (r.startsWith("img+./") || r.startsWith("img+../")) return "img+" + resolve(base, r.substring(4))
        if (base.isEmpty() || !(r.startsWith("./") || r.startsWith("../"))) return ref
        return join(base, r)
    }

    /** Browser-style join (used by scripts, parses and playlists). */
    fun join(base: String, ref: String): String {
        val r = ref.trim()
        if (r.isEmpty()) return base
        if (SCHEME.containsMatchIn(r) || base.isEmpty()) return r
        val scheme = SCHEME.find(base)?.value ?: return r
        if (r.startsWith("//")) return scheme + r
        val clean = base.substringBefore('#').substringBefore('?')
        val rootEnd = clean.indexOf('/', clean.indexOf("://").let { if (it < 0) scheme.length else it + 3 })
        val root = if (rootEnd < 0) clean else clean.substring(0, rootEnd)
        val path = if (rootEnd < 0) "/" else clean.substring(rootEnd)
        if (r.startsWith("?")) return clean + r
        if (r.startsWith("#")) return base.substringBefore('#') + r
        val cut = r.indexOfFirst { it == '?' || it == '#' }
        val tail = if (cut < 0) "" else r.substring(cut)
        val rel = if (cut < 0) r else r.substring(0, cut)
        val segs = ArrayDeque<String>()
        if (!rel.startsWith("/")) path.substringBeforeLast('/').split('/').filter { it.isNotEmpty() }.forEach(segs::addLast)
        val parts = rel.split('/')
        parts.forEachIndexed { i, p ->
            when {
                p == ".." -> segs.removeLastOrNull()
                p == "." || (p.isEmpty() && i < parts.lastIndex) -> {}
                else -> segs.addLast(p)
            }
        }
        val dir = parts.last().let { it == "." || it == ".." } && segs.isNotEmpty()
        return root + "/" + segs.joinToString("/") + (if (dir) "/" else "") + tail
    }

    /** Recursively resolves `./` and `../` strings inside a parsed config (nested `ext` objects included). */
    fun resolveTree(v: Any?, base: String) {
        when (v) {
            is JSONObject -> v.keys().asSequence().toList().forEach { k ->
                when (val x = v.opt(k)) { is String -> resolve(base, x).let { if (it != x) v.put(k, it) }; else -> resolveTree(x, base) }
            }
            is JSONArray -> for (i in 0 until v.length()) when (val x = v.opt(i)) {
                is String -> resolve(base, x).let { if (it != x) v.put(i, it) }
                else -> resolveTree(x, base)
            }
        }
    }

    fun host(u: String): String = u.substringAfter("://", "").substringBefore('/').substringBefore('?').substringBefore('#').substringAfterLast('@')
        .let { if (it.startsWith("[")) it.substringBefore(']').removePrefix("[") else it.substringBefore(':') }.lowercase()

    /** File name of an address without query, e.g. `live.txt`. */
    fun fileName(u: String): String = u.substringBefore('?').substringBefore('#').trimEnd('/').substringAfterLast('/')

    data class Picture(val url: String, val headers: Map<String, String>)

    private val PIC_MARK = Regex("@(Referer|User-Agent|Cookie|Headers|Origin)=", RegexOption.IGNORE_CASE)

    /** `url@Referer=…@User-Agent=…@Cookie=…@Headers={json}` → address + request headers. */
    fun picture(raw: String): Picture {
        val marks = PIC_MARK.findAll(raw).toList()
        val headers = LinkedHashMap<String, String>()
        marks.forEachIndexed { i, m ->
            val value = raw.substring(m.range.last + 1, marks.getOrNull(i + 1)?.range?.first ?: raw.length).trim()
            when (m.groupValues[1].lowercase()) {
                "headers" -> LenientJson.objectOrNull(value)?.let { o -> o.keys().forEach { k -> headers[k] = J.str(o.opt(k)) } }
                "referer" -> headers["Referer"] = value
                "user-agent" -> headers["User-Agent"] = value
                "cookie" -> headers["Cookie"] = value
                "origin" -> headers["Origin"] = value
            }
        }
        val u = (marks.firstOrNull()?.let { raw.substring(0, it.range.first) } ?: raw).trim()
        return Picture(if (u.startsWith("//")) "https:$u" else u, headers)
    }

    data class Stream(val url: String, val headers: Map<String, String>, val label: String)

    /** `url|User-Agent=…&Referer=…$线路名` */
    fun stream(raw: String): Stream {
        val t = raw.trim()
        val label = if (t.contains('$')) t.substringAfter('$').substringBefore('$').trim() else ""
        val body = t.substringBefore('$').trim()
        val bar = body.indexOf('|')
        if (bar < 0) return Stream(body, emptyMap(), label)
        return Stream(body.substring(0, bar).trim(), headerQuery(body.substring(bar + 1)), label)
    }

    private val HEADERS = Regex("(?:user-?agent|ua|refer+er|origin|cookie|host|authorization|accept[\\w-]*|range|x-[\\w-]+|sec-[\\w-]+|http-[\\w-]+)=.*", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))

    /** A play address of a site: `url|User-Agent=…` like in lists, but `$` and other `|` are part of it. */
    fun vod(raw: String): Stream {
        val t = raw.trim()
        var bar = t.indexOf('|')
        while (bar >= 0 && !HEADERS.matches(t.substring(bar + 1))) bar = t.indexOf('|', bar + 1)
        return if (bar < 0) Stream(t, emptyMap(), "") else Stream(t.substring(0, bar).trim(), headerQuery(t.substring(bar + 1)), "")
    }

    fun headerQuery(q: String): Map<String, String> = buildMap {
        for (pair in q.split('&')) {
            val i = pair.indexOf('=')
            if (i > 0) put(headerName(pair.substring(0, i)), decode(pair.substring(i + 1)))
        }
    }

    fun decode(s: String): String = try { URLDecoder.decode(s.replace("+", "%2B"), "UTF-8") } catch (_: Exception) { s }

    fun headerName(raw: String): String = when (val k = raw.trim().lowercase()) {
        "ua", "useragent", "user-agent", "http-user-agent" -> "User-Agent"
        "referer", "referrer", "http-referrer", "http-referer" -> "Referer"
        "origin", "http-origin" -> "Origin"
        "cookie", "http-cookie" -> "Cookie"
        else -> if (k == "host" || k == "authorization") k.replaceFirstChar { it.uppercase() } else raw.trim()
    }

    private val MEDIA = Regex("^https?://\\S{8,}?\\.(?:m3u8|mp4|mkv|flv|mp3|m4a|aac|mpd|avi|mov|wmv|webm|rmvb|m4v)(?:[?#&/]\\S*)?$", RegexOption.IGNORE_CASE)
    private val TOS = Regex("^https?://\\S*?(?:video|obj)/tos\\S*", RegexOption.IGNORE_CASE)
    private val PAGE = listOf("url=http", "v=http", "url=https%3a", "url=http%3a", ".css", ".html", ".js?", ".htm?")

    /** Media address by shape only (no request): the sniffer's base rule and the direct-play check. */
    fun isVideo(u: String): Boolean {
        val l = u.lowercase()
        if (l.startsWith("rtmp:") || l.startsWith("rtsp:") || l.startsWith("rtp:") || l.startsWith("udp:") || l.startsWith("mms:")) return true
        if (PAGE.any { l.contains(it) } || l.endsWith(".js") || l.endsWith(".htm")) return false
        return MEDIA.containsMatchIn(u) || TOS.containsMatchIn(u)
    }

    /** P2P schemes need closed-source native libraries; neither platform supports them. */
    fun p2p(u: String): String? = u.substringBefore(':').lowercase().takeIf { it in P2P }
    private val P2P = setOf("thunder", "ed2k", "magnet", "tvbus", "jianpian", "force", "p2p", "mitv", "p3p", "p5p", "p6p", "p7p", "p8p", "p9p", "flashget", "qqdl")
}

/** `spider` / `jar` value: `url;md5;hash`, `img+url`. */
data class SpiderRef(val url: String, val md5: String, val image: Boolean) {
    val isEmpty get() = url.isEmpty()
    /** Identity of the downloaded file. */
    val id: String get() = Bytes.hex(Bytes.md5("$url;$md5;$image"))

    companion object {
        fun parse(raw: String): SpiderRef {
            val t = raw.trim()
            val image = t.startsWith("img+", true)
            val body = if (image) t.substring(4) else t
            val parts = body.split(";md5;", limit = 2)
            val sum = parts.getOrElse(1) { "" }.trim().substringBefore(';')
            return SpiderRef(parts[0].trim(), if (sum.startsWith("http", true)) sum else sum.lowercase(), image)
        }
    }
}

/** Config text as delivered: plain, Base64 behind `xxxxxxxx**` (also inside images), AES-CBC hex (`2423…`), AES-ECB with a key. */
object TVBoxDecoder {
    private val MARK = Regex("[A-Za-z0-9]{8}\\*\\*")
    private val HEX = Regex("^[0-9a-fA-F\\s]+$")

    /** Splits `address;pk;key`. */
    fun splitKey(url: String): Pair<String, String> {
        val i = url.indexOf(";pk;")
        return if (i < 0) url.trim() to "" else url.substring(0, i).trim() to url.substring(i + 4).trim()
    }

    fun decode(bytes: ByteArray, key: String = ""): String {
        val raw = if (bytes.size > 2 && bytes[0] == 0x1f.toByte() && bytes[1] == 0x8b.toByte()) gunzip(bytes) else bytes
        val text = text(raw)
        if (looksPlain(text)) return text
        // an image carrier is not valid UTF-8: search the marker byte-for-byte
        val carrier = String(raw, Charsets.ISO_8859_1)
        return decode(if (MARK.containsMatchIn(carrier)) carrier else text, key)
    }

    fun decode(text: String, key: String = ""): String {
        var data = text
        if (looksPlain(data)) return data
        MARK.find(data)?.let { m ->
            val b = base64(data.substring(m.range.last + 1))
            if (b != null) { if (looksImage(b)) return decode(b, key); data = text(b) }
        }
        val compact = data.trim()
        if (compact.startsWith("2423") && HEX.matches(compact)) return cbc(compact.filterNot { it.isWhitespace() })
        if (key.isNotEmpty() && !looksPlain(data)) return ecb(compact, key)
        return data
    }

    /** Bytes hidden in an image (`img+` spiders): Base64 behind the marker, or appended after the image data. */
    fun carried(bytes: ByteArray): ByteArray? {
        val s = String(bytes, Charsets.ISO_8859_1)
        return MARK.find(s)?.let { base64(s.substring(it.range.last + 1)) }
    }

    private fun looksPlain(t: String): Boolean {
        val c = t.trimStart('﻿', ' ', '\t', '\r', '\n')
        return c.startsWith("{") || c.startsWith("[") || c.startsWith("//") || c.startsWith("/*") || c.startsWith("#") || c.startsWith("<")
    }

    private fun looksImage(b: ByteArray) = b.size > 3 && ((b[0] == 0xFF.toByte() && b[1] == 0xD8.toByte()) || (b[0] == 0x89.toByte() && b[1] == 'P'.code.toByte()))

    fun text(b: ByteArray): String {
        val utf = String(b, Charsets.UTF_8)
        if (!utf.contains('�')) return utf
        return runCatching { charset("GB18030").newDecoder().decode(java.nio.ByteBuffer.wrap(b)).toString() }.getOrDefault(utf)
    }

    private fun base64(s: String): ByteArray? {
        val sb = StringBuilder(s.length)
        for (c in s) { if (c.isLetterOrDigit() && c.code < 128 || c == '+' || c == '/' || c == '-' || c == '_') sb.append(c) else if (c == '=') break }
        return Bytes.b64decode(sb.toString())
    }

    private fun gunzip(b: ByteArray): ByteArray = GZIPInputStream(ByteArrayInputStream(b)).use { TVBoxNet.capped(it, NetRequest.MAX_BYTES) }

    private fun pad16(s: String) = (s + "0000000000000000").substring(0, maxOf(16, s.length).let { if (s.length <= 16) 16 else it })

    private fun hex(s: String): ByteArray = Bytes.fromHex(s) ?: throw LenientJson.Malformed("配置密文不是有效的十六进制")

    private fun cbc(data: String): String {
        val plain = String(hex(data), Charsets.ISO_8859_1).lowercase()
        val from = plain.indexOf("$#"); val to = plain.indexOf("#$")
        val cut = data.indexOf("2324")
        if (from < 0 || to <= from || plain.length < 13 || cut < 0 || data.length < cut + 30) throw LenientJson.Malformed("配置密文不完整")
        val key = pad16(plain.substring(from + 2, to))
        val iv = pad16(plain.substring(plain.length - 13))
        val body = data.substring(cut + 4, data.length - 26)
        return run("AES/CBC/PKCS5Padding", key, iv, hex(body))
    }

    private fun ecb(data: String, key: String): String {
        val body = if (HEX.matches(data)) hex(data.filterNot { it.isWhitespace() }) else Bytes.b64decode(data) ?: throw LenientJson.Malformed("配置密文无法识别")
        return run("AES/ECB/PKCS5Padding", pad16(key), null, body)
    }

    private fun run(spec: String, key: String, iv: String?, body: ByteArray): String = try {
        val c = Cipher.getInstance(spec)
        val k = SecretKeySpec(key.toByteArray(), "AES")
        if (iv == null) c.init(Cipher.DECRYPT_MODE, k) else c.init(Cipher.DECRYPT_MODE, k, IvParameterSpec(iv.toByteArray()))
        String(c.doFinal(body), Charsets.UTF_8)
    } catch (_: Exception) { throw LenientJson.Malformed("配置解密失败，请检查密钥") }
}
