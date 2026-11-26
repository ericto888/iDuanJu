package app.iduanju.core.tvbox

import app.iduanju.core.util.Bytes
import app.iduanju.core.util.J
import app.iduanju.core.util.NetGuard
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Contract §4 "JAR 桥接": authentication of the LAN bridge. Requests carry `X-Idj-Time` (unix seconds or milliseconds),
 * `X-Idj-Nonce` and `X-Idj-Sign = hex HMAC-SHA256(code, time \n nonce \n hex sha256(body))`; proxied media addresses carry
 * `idj_exp` / `idj_sign = hex HMAC-SHA256(code, "proxy" \n exp \n original query)`.
 */
class BridgeAuth(private val code: () -> String, private val now: () -> Long = System::currentTimeMillis) {
    private val nonces = object : LinkedHashMap<String, Long>(256, 0.75f, false) { override fun removeEldestEntry(e: MutableMap.MutableEntry<String, Long>) = size > 8192 }
    private val failures = HashMap<String, MutableList<Long>>()

    /** null = accepted, otherwise the reason. */
    @Synchronized fun verify(time: String, nonce: String, sign: String, body: ByteArray): String? {
        if (code().length < 6) return "桥接没有配对码"
        val t = time.trim().toLongOrNull() ?: return "缺少时间戳"
        val ms = if (t > 100_000_000_000L) t else t * 1000
        if (kotlin.math.abs(now() - ms) > SKEW_MS) return "两台设备的时间相差超过 60 秒"
        if (nonce.length !in 8..128) return "随机串无效"
        val expect = hmac(code(), "$time\n$nonce\n" + Bytes.hex(Bytes.sha256(body)))
        if (!same(expect, sign)) return "配对码不正确"
        val cutoff = now() - 3 * SKEW_MS
        nonces.entries.iterator().let { while (it.hasNext()) if (it.next().value < cutoff) it.remove() else break }
        if (nonces.containsKey(nonce)) return "重复的请求"
        nonces[nonce] = now()
        return null
    }

    /** More than ten wrong signatures per minute from one address: locked out until the minute has passed. */
    @Synchronized fun locked(ip: String): Boolean = failures[ip]?.let { l -> l.removeAll { it < now() - 60_000 }; l.size >= 10 } ?: false
    @Synchronized fun failed(ip: String) { if (failures.size > 512) failures.clear(); failures.getOrPut(ip) { ArrayList() }.add(now()) }

    fun signedProxy(origin: String, query: String, ttlMs: Long = PROXY_TTL_MS): String {
        val exp = (now() + ttlMs) / 1000
        return "$origin/bridge/proxy?$query" + (if (query.isEmpty()) "" else "&") + "idj_exp=$exp&idj_sign=" + Bytes.hex(hmac(code(), "proxy\n$exp\n$query"))
    }

    /** Original query of a signed proxy request, or null when the signature is wrong or expired. */
    fun openProxy(rawQuery: String): String? {
        val cut = rawQuery.lastIndexOf("idj_exp=").takeIf { it >= 0 } ?: return null
        val tail = HashMap<String, String>().also { LocalServer.parseQuery(rawQuery.substring(cut), it) }
        val exp = tail["idj_exp"]?.toLongOrNull() ?: return null
        val query = rawQuery.substring(0, cut).trimEnd('&')
        return if (exp * 1000 >= now() && same(hmac(code(), "proxy\n$exp\n$query"), tail["idj_sign"].orEmpty())) query else null
    }

    private fun same(expect: ByteArray, given: String): Boolean {
        val g = given.trim()
        val b = (if (g.length == 64) Bytes.fromHex(g.lowercase()) else null) ?: Bytes.b64decode(g) ?: return false
        return MessageDigest.isEqual(expect, b)
    }

    companion object {
        const val SKEW_MS = 60_000L
        const val PROXY_TTL_MS = 4 * 3600_000L
        /** No look-alike characters: typed by hand on the other device. */
        private const val ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

        /** 12 characters (60 bits): a signature sniffed on the LAN must not be worth brute-forcing offline. */
        fun newCode(): String = SecureRandom().let { r -> (1..12).map { ALPHABET[r.nextInt(ALPHABET.length)] }.joinToString("") }
        fun hmac(code: String, text: String): ByteArray = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(code.toByteArray(), "HmacSHA256")) }.doFinal(text.toByteArray())
        fun sign(code: String, time: String, nonce: String, body: ByteArray): String = Bytes.hex(hmac(code, "$time\n$nonce\n" + Bytes.hex(Bytes.sha256(body))))
    }
}

/** What the bridge may run: implemented by the engine, which only knows imported and trusted configs. */
interface BridgeTarget {
    /** Result text, or throws [Denied] with the reason shown on the other device. */
    fun call(siteKey: String, api: String, ext: String, jar: String, method: String, args: JSONArray): String
    fun proxy(params: Map<String, String>): ProxyReply
    val proxyPort: Int

    class Denied(message: String) : Exception(message)
}

/** HTTP face of the bridge (`/bridge/call`, `/bridge/proxy`, `/bridge/ping`), independent of the socket it runs on. */
class BridgeHandler(private val auth: BridgeAuth, private val target: BridgeTarget) {
    fun handle(r: HttpIn): ProxyReply {
        val ip = r.remote.hostAddress.orEmpty()
        if (!r.remote.isLoopbackAddress && !NetGuard.isBlockedIP(ip)) return error(403, "只接受局域网内的连接")
        if (auth.locked(ip)) return error(429, "尝试次数过多，请稍后再试")
        return when (r.path) {
            "/bridge/call", "/bridge/ping" -> call(r, ip)
            "/bridge/proxy" -> proxy(r, ip)
            else -> error(404, "没有这个接口")
        }
    }

    private fun call(r: HttpIn, ip: String): ProxyReply {
        if (r.method != "POST") return error(405, "请使用 POST")
        auth.verify(r.headers["x-idj-time"].orEmpty(), r.headers["x-idj-nonce"].orEmpty(), r.headers["x-idj-sign"].orEmpty(), r.body)?.let { auth.failed(ip); return error(401, it) }
        if (r.path == "/bridge/ping") return json(JSONObject().put("v", "ok"))
        val o = try { J.parse(r.body) } catch (_: Exception) { return error(400, "正文不是 JSON") }
        val args = o.opt("args").let { it as? JSONArray ?: JSONArray() }
        return try {
            val text = target.call(J.str(o.opt("siteKey")), J.str(o.opt("api")), TVBoxConfig.ext(o.opt("ext")), J.str(o.opt("jar")), J.str(o.opt("method")), args)
            json(JSONObject().put("v", rewrite(text, origin(r))))
        } catch (e: BridgeTarget.Denied) { error(403, e.message.orEmpty()) } catch (e: Throwable) { error(502, SpiderErrors.text(e)) }
    }

    private fun proxy(r: HttpIn, ip: String): ProxyReply {
        if (r.method != "GET" && r.method != "HEAD") return error(405, "请使用 GET")
        val query = auth.openProxy(r.rawQuery) ?: run { auth.failed(ip); return error(403, "播放地址已过期或签名无效") }
        val params = LinkedHashMap<String, String>()
        LocalServer.parseQuery(query, params)
        r.headers.forEach { (k, v) -> if (k != "host") params.putIfAbsent(k, v) }
        val reply = target.proxy(params)
        val type = (reply.headers.entries.firstOrNull { it.key.equals("content-type", true) }?.value ?: reply.type).lowercase()
        if (!type.contains("mpegurl") && !type.startsWith("text/") && !type.contains("json") && !type.contains("xml")) return reply
        // playlists point back at the loopback proxy: those lines must go through the bridge too
        val text = reply.body.use { String(TVBoxNet.capped(it, 8 shl 20), Charsets.UTF_8) }
        val out = rewriteText(text, origin(r)).toByteArray()
        return ProxyReply(reply.code, reply.type, out.inputStream(), reply.headers.filterKeys { !it.equals("content-length", true) && !it.equals("content-range", true) }, out.size.toLong())
    }

    private fun origin(r: HttpIn) = "http://" + r.headers["host"].orEmpty()

    /** Rewrites inside JSON string values (Gson escapes `=` and `&`, so plain text replacement would miss them). */
    fun rewrite(text: String, origin: String): String {
        val t = text.trim()
        if (!t.startsWith("{") && !t.startsWith("[")) return rewriteText(text, origin)
        val v = runCatching { LenientJson.parse(t) }.getOrNull() ?: return rewriteText(text, origin)
        return walk(v, origin).toString()
    }

    private fun walk(v: Any?, origin: String): Any? = when (v) {
        is JSONObject -> v.also { o -> o.keys().asSequence().toList().forEach { k -> o.put(k, walk(o.opt(k), origin) ?: JSONObject.NULL) } }
        is JSONArray -> v.also { a -> for (i in 0 until a.length()) a.put(i, walk(a.opt(i), origin) ?: JSONObject.NULL) }
        is String -> rewriteText(v, origin)
        else -> v
    }

    private fun rewriteText(s: String, origin: String): String {
        if (!s.contains("/proxy?") && !s.contains("proxy://")) return s
        val port = target.proxyPort
        return LOCAL.replace(s) { m ->
            val p = m.groupValues[1].toIntOrNull()
            if (m.groupValues[1].isEmpty() || p == port || p == 9978) auth.signedProxy(origin, m.groupValues[2] + m.groupValues[3]) else m.value
        }
    }

    private fun json(o: JSONObject, code: Int = 200) = ProxyReply.text(o.toString(), code, "application/json; charset=utf-8")
    private fun error(code: Int, message: String) = json(JSONObject().put("e", message).put("error", message), code)

    companion object {
        private val LOCAL = Regex("(?:https?://(?:127\\.0\\.0\\.1|localhost):(\\d+)/proxy\\?([^\\s\"'<>\\\\#$]*)|proxy://([^\\s\"'<>\\\\#$]*))")
    }
}
