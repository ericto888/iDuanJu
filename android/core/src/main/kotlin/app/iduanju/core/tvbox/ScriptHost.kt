package app.iduanju.core.tvbox

import app.iduanju.core.util.Bytes
import app.iduanju.core.util.J
import org.json.JSONArray
import org.json.JSONObject
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element
import java.io.ByteArrayInputStream
import java.math.BigInteger
import java.net.URLEncoder
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.security.interfaces.RSAKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.RSAPrivateCrtKeySpec
import java.security.spec.RSAPublicKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.IdentityHashMap
import java.util.zip.GZIPInputStream
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Values scripts persist (`local.*`), one namespace per site. */
interface ScriptStorage {
    fun get(ns: String, k: String): String?
    fun set(ns: String, k: String, v: String)
    fun delete(ns: String, k: String)
}

/** The native half of shared/tvbox/HOST_ABI.md, one instance per script spider. */
class ScriptHost(
    private val siteKey: String, private val http: TVBoxHttp, private val storage: ScriptStorage,
    private val proxyPort: () -> Int, private val log: (String) -> Unit = {},
) {
    /** Tag of every request the script makes, so a timeout can abort them. */
    val tag = Any()

    // html documents live until the spider call returns
    private val nodes = ArrayList<Element>()
    private val ids = IdentityHashMap<Element, Int>()
    private val docs = object : LinkedHashMap<String, Document>(8, 0.75f, true) { override fun removeEldestEntry(e: MutableMap.MutableEntry<String, Document>) = size > 6 }

    fun endCall() { nodes.clear(); ids.clear(); docs.clear() }

    fun call(name: String, argsJson: String): String = try {
        val a = if (argsJson.isBlank()) JSONObject() else JSONObject(argsJson)
        when (val v = dispatch(name, a)) {
            null, Unit -> "{\"v\":null}"
            is String -> "{\"v\":" + JSONObject.quote(v) + "}"
            is Boolean, is Int, is Long -> "{\"v\":$v}"
            is List<*> -> JSONObject().put("v", JSONArray(v)).toString()
            else -> JSONObject().put("v", v).toString()
        }
    } catch (e: Throwable) {
        if (e is InterruptedException || e is VirtualMachineError && e !is StackOverflowError) throw e
        "{\"e\":" + JSONObject.quote(SpiderErrors.text(e)) + "}"
    }

    private fun JSONObject.s(k: String): String = J.str(opt(k))
    private fun JSONObject.bytes(k: String): ByteArray = Bytes.b64decode(s(k)) ?: ByteArray(0)

    private fun dispatch(name: String, a: JSONObject): Any? = when (name) {
        "http" -> request(a)
        "html.load" -> id(HtmlQuery.parse(a.s("html")))
        "html.select" -> HtmlQuery.select(J.arr(a.opt("ids")).mapNotNull { node(J.int(it)) }, a.s("css")).map(::id)
        "html.text" -> node(a)?.text().orEmpty()
        "html.html" -> node(a)?.html().orEmpty()
        "html.outer" -> node(a)?.outerHtml().orEmpty()
        "html.attr" -> node(a)?.let { if (it.hasAttr(a.s("k"))) it.attr(a.s("k")) else null }
        "html.rel" -> rel(node(a), a.s("op")).map(::id)
        "html.xpath" -> node(a)?.let { el -> HtmlQuery.xpath(el, a.s("q")).map { if (it is Element) JSONObject().put("n", id(it)) else JSONObject().put("s", it.toString()) } } ?: emptyList<Any>()
        "pdfh" -> PdfRule.one(doc(a.s("html")), a.s("rule"))
        "pd" -> PdfRule.one(doc(a.s("html")), a.s("rule"), a.s("base"))
        "pdfa" -> PdfRule.list(doc(a.s("html")), a.s("rule"))
        "pdfl" -> PdfRule.pairs(doc(a.s("html")), a.s("rule"), a.s("list"), a.s("url"), a.s("base"))
        "joinUrl" -> TVBoxUrl.join(a.s("base"), a.s("ref"))
        "local.get" -> storage.get(a.s("ns").ifEmpty { siteKey }, a.s("k"))
        "local.set" -> storage.set(a.s("ns").ifEmpty { siteKey }, a.s("k"), a.s("v"))
        "local.delete" -> storage.delete(a.s("ns").ifEmpty { siteKey }, a.s("k"))
        "hash" -> hash(a)
        "cipher" -> Bytes.b64(HostCrypto.cipher(a.s("alg"), a.s("mode"), a.s("pad"), J.bool(a.opt("encrypt")), a.bytes("keyB64"), if (a.s("ivB64").isEmpty()) null else a.bytes("ivB64"), a.bytes("dataB64")))
        "rsa" -> rsa(a)
        "gbk" -> if (a.s("op") == "encode") Bytes.b64(a.s("s").toByteArray(charset("GBK"))) else String(a.bytes("b64"), charset("GBK"))
        "inflate" -> Bytes.b64(inflate(a.bytes("b64"), a.s("kind")))
        "json5" -> LenientJson.parse(a.s("s"))
        "s2t" -> s2t(a.s("s"))
        "t2s" -> t2s(a.s("s"))
        "proxyUrl" -> "http://127.0.0.1:${proxyPort()}/proxy?do=${a.s("kind").ifEmpty { "js" }}&siteKey=" + URLEncoder.encode(a.s("siteKey").ifEmpty { siteKey }, "UTF-8")
        "log" -> log(a.s("m"))
        else -> throw IllegalArgumentException("未知的宿主接口 $name")
    }

    // -- http -------------------------------------------------------------------------------------------------------------
    private fun request(a: JSONObject): JSONObject {
        val headers = J.dict(a.opt("headers")).let { o -> o.keys().asSequence().associateWith { J.str(o.opt(it)) } }
        val body = when { a.s("bodyB64").isNotEmpty() -> a.bytes("bodyB64"); a.has("body") && !a.isNull("body") -> a.s("body").toByteArray(); else -> null }
        val r = http.execute(NetRequest(
            a.s("url"), a.s("method").ifEmpty { "GET" }, headers, body, J.int64(a.opt("timeout")).let { if (it <= 0) 10_000 else it.coerceIn(1_000, 60_000) },
            !a.has("redirect") || J.bool(a.opt("redirect")), !a.has("verify") || J.bool(a.opt("verify")), tag = tag,
        ))
        val h = JSONObject()
        r.headers.forEach { (k, v) -> h.put(k, JSONArray(v)) }
        return JSONObject().put("code", r.code).put("url", r.url).put("headers", h).put("body", if (a.s("out") == "b64") Bytes.b64(r.body) else r.text(a.s("charset").ifEmpty { null }))
    }

    // -- html -------------------------------------------------------------------------------------------------------------
    private fun id(e: Element): Int = ids.getOrPut(e) { nodes.add(e); nodes.size }
    private fun node(id: Int): Element? = nodes.getOrNull(id - 1)
    private fun node(a: JSONObject): Element? = node(J.int(a.opt("id")))
    private fun doc(html: String): Document = docs.getOrPut(html) { HtmlQuery.parse(html) }

    private fun rel(e: Element?, op: String): List<Element> = when {
        e == null -> emptyList()
        op == "parent" -> listOfNotNull(e.parent()).filter { it !is Document }
        op == "children" -> e.children()
        op == "next" -> listOfNotNull(e.nextElementSibling())
        op == "prev" -> listOfNotNull(e.previousElementSibling())
        op == "siblings" -> e.siblingElements()
        else -> emptyList()
    }

    // -- crypto -----------------------------------------------------------------------------------------------------------
    private fun hash(a: JSONObject): String {
        val alg = when (a.s("alg").lowercase()) { "md5" -> "MD5"; "sha1" -> "SHA-1"; "sha256" -> "SHA-256"; "sha512" -> "SHA-512"; else -> throw IllegalArgumentException("不支持的摘要算法 ${a.s("alg")}") }
        val data = a.bytes("b64")
        if (!a.has("hmacB64") || a.isNull("hmacB64")) return Bytes.hex(MessageDigest.getInstance(alg).digest(data))
        val mac = "Hmac" + alg.replace("-", "")
        val key = a.bytes("hmacB64").let { if (it.isEmpty()) ByteArray(1) else it }
        return Bytes.hex(Mac.getInstance(mac).apply { init(SecretKeySpec(key, mac)) }.doFinal(data))
    }

    private fun rsa(a: JSONObject): Any {
        val key = a.s("key"); val pub = J.bool(a.opt("public")); val data = a.bytes("dataB64")
        val sig = a.s("hash").ifEmpty { "sha1" }.uppercase().replace("-", "") + "withRSA"
        return when (a.s("op")) {
            "sign" -> Bytes.b64(Signature.getInstance(sig).apply { initSign(HostCrypto.privateKey(key)); update(data) }.sign())
            "verify" -> Signature.getInstance(sig).apply { initVerify(HostCrypto.publicKey(key)); update(data) }.verify(a.bytes("sigB64"))
            else -> Bytes.b64(HostCrypto.rsa(a.s("op") != "decrypt", key, pub, a.s("pad"), data))
        }
    }

    private fun inflate(b: ByteArray, kind: String): ByteArray = when (kind) {
        "gzip" -> GZIPInputStream(ByteArrayInputStream(b))
        "raw" -> InflaterInputStream(ByteArrayInputStream(b), Inflater(true))
        else -> InflaterInputStream(ByteArrayInputStream(b))
    }.use { TVBoxNet.capped(it, NetRequest.MAX_BYTES) }

    companion object {
        /** Simplified / traditional conversion: ICU on Android, identity elsewhere. */
        @Volatile var s2t: (String) -> String = { it }
        @Volatile var t2s: (String) -> String = { it }
    }
}

/** Symmetric / RSA primitives behind the `cipher` and `rsa` host calls. Padding is done here so every mode accepts every padding. */
object HostCrypto {
    fun cipher(alg: String, mode: String, pad: String, encrypt: Boolean, key: ByteArray, iv: ByteArray?, data: ByteArray): ByteArray {
        val a = alg.lowercase()
        if (a == "rc4") return Cipher.getInstance("ARCFOUR").apply { init(if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE, SecretKeySpec(key, "ARCFOUR")) }.doFinal(data)
        val name = when (a) { "aes" -> "AES"; "des" -> "DES"; "3des", "tripledes", "desede" -> "DESede"; else -> throw IllegalArgumentException("不支持的加密算法 $alg") }
        val block = if (name == "AES") 16 else 8
        val m = mode.lowercase().ifEmpty { "cbc" }
        val op = if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE
        val spec = SecretKeySpec(fit(name, key), name)
        if (m == "gcm") return Cipher.getInstance("$name/GCM/NoPadding").apply { init(op, spec, GCMParameterSpec(128, iv ?: ByteArray(12))) }.doFinal(data)
        val input = if (encrypt) padded(data, pad, block) else data
        // CFB / OFB / CTR are stream modes: a partial last block is filled up and cut off again
        val stream = m == "cfb" || m == "ofb" || m == "ctr"
        val fed = if (stream && input.size % block != 0) input.copyOf(input.size + block - input.size % block) else input
        val c = Cipher.getInstance("$name/${m.uppercase()}/NoPadding")
        if (m == "ecb") c.init(op, spec) else c.init(op, spec, IvParameterSpec((iv ?: ByteArray(block)).copyOf(block)))
        val out = c.doFinal(fed).let { if (fed.size != input.size) it.copyOf(input.size) else it }
        return if (encrypt) out else unpadded(out, pad, block)
    }

    private fun fit(name: String, key: ByteArray): ByteArray = when (name) {
        "AES" -> if (key.size == 16 || key.size == 24 || key.size == 32) key else key.copyOf(if (key.size < 16) 16 else if (key.size < 24) 24 else 32)
        "DES" -> key.copyOf(8)
        else -> if (key.size >= 24) key.copyOf(24) else key.copyOf(16) + key.copyOf(8)
    }

    private fun padded(d: ByteArray, pad: String, block: Int): ByteArray = when (pad.lowercase()) {
        "none", "nopadding" -> d
        "zero", "zeropadding" -> if (d.size % block == 0) d else d.copyOf(d.size + block - d.size % block)
        else -> { val n = block - d.size % block; d + ByteArray(n) { n.toByte() } }
    }

    private fun unpadded(d: ByteArray, pad: String, block: Int): ByteArray = when (pad.lowercase()) {
        "none", "nopadding" -> d
        "zero", "zeropadding" -> d.copyOf(d.indexOfLast { it != 0.toByte() } + 1)
        else -> {
            val n = if (d.isEmpty()) 0 else d.last().toInt() and 0xff
            if (n !in 1..block || n > d.size || (d.size - n until d.size).any { d[it].toInt() and 0xff != n }) throw IllegalArgumentException("解密失败：填充无效")
            d.copyOf(d.size - n)
        }
    }

    private fun der(key: String): ByteArray = Bytes.b64decode(key.replace(Regex("-----[^-]+-----"), "").filterNot { it.isWhitespace() }) ?: throw IllegalArgumentException("RSA 密钥无法识别")

    /** Minimal DER walk: the INTEGERs of one SEQUENCE. */
    private fun integers(d: ByteArray): List<BigInteger>? {
        var p = 0
        fun len(): Int { var n = d[p++].toInt() and 0xff; if (n >= 0x80) { val c = n and 0x7f; n = 0; repeat(c) { n = (n shl 8) or (d[p++].toInt() and 0xff) } }; return n }
        return runCatching {
            if (d[p++] != 0x30.toByte()) return null
            len()
            buildList { while (p < d.size) { if (d[p++] != 0x02.toByte()) return null; val n = len(); add(BigInteger(1, d.copyOfRange(p, p + n))); p += n } }
        }.getOrNull()
    }

    fun publicKey(key: String): PublicKey {
        val d = der(key); val f = KeyFactory.getInstance("RSA")
        integers(d)?.takeIf { it.size == 2 }?.let { return f.generatePublic(RSAPublicKeySpec(it[0], it[1])) }
        return f.generatePublic(X509EncodedKeySpec(d))
    }

    fun privateKey(key: String): PrivateKey {
        val d = der(key); val f = KeyFactory.getInstance("RSA")
        integers(d)?.takeIf { it.size >= 9 }?.let { return f.generatePrivate(RSAPrivateCrtKeySpec(it[1], it[2], it[3], it[4], it[5], it[6], it[7], it[8])) }
        return f.generatePrivate(PKCS8EncodedKeySpec(d))
    }

    /** Block-wise, so inputs longer than the modulus work like the JS libraries' "long" variants. */
    fun rsa(encrypt: Boolean, key: String, public: Boolean, pad: String, data: ByteArray): ByteArray {
        val k = if (public) publicKey(key) else privateKey(key)
        val size = ((k as RSAKey).modulus.bitLength() + 7) / 8
        val spec = when (pad) { "oaep" -> "RSA/ECB/OAEPWithSHA-1AndMGF1Padding"; "none" -> "RSA/ECB/NoPadding"; else -> "RSA/ECB/PKCS1Padding" }
        val step = if (!encrypt || pad == "none") size else size - (if (pad == "oaep") 42 else 11)
        val c = Cipher.getInstance(spec)
        c.init(if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE, k)
        val out = java.io.ByteArrayOutputStream()
        var at = 0
        do { val n = minOf(step, data.size - at); out.write(c.doFinal(data, at, n)); at += n } while (at < data.size)
        return out.toByteArray()
    }
}
