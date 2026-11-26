package app.iduanju.core.tvbox

import app.iduanju.core.util.NetGuard
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.ConnectionPool
import okhttp3.Credentials
import okhttp3.Dispatcher
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.dnsoverhttps.DnsOverHttps
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.UnknownHostException
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class NetRequest(
    val url: String, val method: String = "GET", val headers: Map<String, String> = emptyMap(), val body: ByteArray? = null,
    val timeoutMs: Long = 15_000, val redirect: Boolean = true, val verify: Boolean = true, val maxBytes: Int = MAX_BYTES, val tag: Any? = null,
    /** False: not even the app's own proxy, on any hop (what comes back is sent on to a remote server). */
    val loopback: Boolean = true,
) {
    fun tagged(t: Any) = NetRequest(url, method, headers, body, timeoutMs, redirect, verify, maxBytes, t, loopback)

    companion object { const val MAX_BYTES = 20 shl 20 }
}

class NetResponse(val code: Int, val url: String, val headers: Map<String, List<String>>, val body: ByteArray) {
    val ok: Boolean get() = code in 200..299
    fun header(name: String): String? = headers.entries.firstOrNull { it.key.equals(name, true) }?.value?.lastOrNull()
    fun text(charset: String? = null): String = TextDecode.decode(body, header("Content-Type"), charset)
}

/** Blocking HTTP seam: real client in the app, a table of canned replies in tests. */
fun interface TVBoxHttp {
    @Throws(IOException::class) fun execute(r: NetRequest): NetResponse
    /** Aborts the requests carrying [tag]. */
    fun cancel(tag: Any) {}
    /** [execute] for something big: the body goes to [to] instead of memory. */
    @Throws(IOException::class) fun save(r: NetRequest, to: File): NetResponse = execute(r).also { to.writeBytes(it.body) }
}

/** The same client with [tag] on every request that has none of its own. */
fun TVBoxHttp.tagged(tag: Any): TVBoxHttp {
    val base = this
    return object : TVBoxHttp {
        override fun execute(r: NetRequest) = base.execute(if (r.tag == null) r.tagged(tag) else r)
        override fun cancel(tag: Any) = base.cancel(tag)
    }
}

/** [TVBoxHttp.execute] off the caller's thread; cancelling the coroutine aborts the request at once. */
suspend fun TVBoxHttp.fetch(r: NetRequest): NetResponse = suspendCancellableCoroutine { cont ->
    val req = r.tagged(r.tag ?: Any())
    cont.invokeOnCancellation { cancel(req.tag!!) }
    Dispatchers.IO.asExecutor().execute {
        if (!cont.isActive) return@execute
        try { val v = execute(req); if (cont.isActive) cont.resume(v) } catch (e: Throwable) { if (cont.isActive) cont.resumeWithException(e) }
    }
}

fun TVBoxHttp.text(url: String, headers: Map<String, String> = emptyMap(), timeoutMs: Long = 15_000, tag: Any? = null): String {
    val r = execute(NetRequest(url, headers = headers, timeoutMs = timeoutMs, tag = tag))
    if (!r.ok) throw IOException("HTTP ${r.code} · ${TVBoxUrl.host(url)}")
    return r.text()
}

object TextDecode {
    private val CT = Regex("charset=[\"']?([\\w-]+)", RegexOption.IGNORE_CASE)
    private val META = Regex("<meta[^>]+charset=[\"']?\\s*([\\w-]+)", RegexOption.IGNORE_CASE)
    private val XML = Regex("^\\s*<\\?xml[^>]+encoding=[\"']([\\w-]+)", RegexOption.IGNORE_CASE)

    fun charset(name: String?): java.nio.charset.Charset? = name?.let { n -> runCatching { charset(if (n.equals("gb2312", true) || n.equals("gbk", true)) "GB18030" else n) }.getOrNull() }

    fun decode(b: ByteArray, contentType: String? = null, forced: String? = null): String {
        charset(forced)?.let { return String(b, it) }
        if (b.size >= 3 && b[0] == 0xEF.toByte() && b[1] == 0xBB.toByte() && b[2] == 0xBF.toByte()) return String(b, 3, b.size - 3, Charsets.UTF_8)
        charset(contentType?.let { CT.find(it)?.groupValues?.get(1) })?.let { return String(b, it) }
        val head = String(b, 0, minOf(b.size, 2048), Charsets.ISO_8859_1)
        charset((META.find(head) ?: XML.find(head))?.groupValues?.get(1))?.let { return String(b, it) }
        return TVBoxDecoder.text(b)
    }
}

/** Address policy + rewrites of one config: hosts, extra headers, DoH, private-network permission. */
class NetRules(
    val hosts: Map<String, String> = emptyMap(), val headers: List<TVBoxHeaderRule> = emptyList(), val doh: TVBoxDoh? = null,
    /** Private ranges are reachable only when the config itself lives there or the user allowed LAN access. */
    val allowPrivate: Boolean = false,
)

/**
 * The one OkHttp stack behind every TVBox request (configs, CMS, scripts, live lists, parses): shared connection pool and
 * dispatcher, HTTP/2, manual redirects so each hop is checked before it is opened.
 */
class TVBoxNet(private val localDir: File? = null, private val ownPort: () -> Int = { 0 }) {
    /** Built on first use (TLS setup is not free), never on the main thread. */
    val base: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectionPool(ConnectionPool(24, 4, TimeUnit.MINUTES))
            .dispatcher(Dispatcher().apply { maxRequests = 48; maxRequestsPerHost = 8 })
            .connectTimeout(8, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS).writeTimeout(20, TimeUnit.SECONDS)
            .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(true).build()
    }

    private val trustAll: X509TrustManager = object : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    inner class Scope(val rules: NetRules) : TVBoxHttp {
        private val dns = object : Dns {
            private val resolver: Dns by lazy { rules.doh?.let(::dohDns) ?: Dns.SYSTEM }
            override fun lookup(hostname: String): List<InetAddress> {
                val name = rules.hosts[hostname.lowercase()] ?: hostname
                val all = if (NetGuard.isIPLiteral(name)) listOf(InetAddress.getByName(name)) else if (name == "localhost") listOf(InetAddress.getByName("127.0.0.1")) else resolver.lookup(name)
                if (hostname == "localhost") return all
                val ok = all.filter { allowed(it) }
                if (ok.isEmpty()) throw UnknownHostException(if (all.isEmpty()) "无法解析 $hostname" else "$hostname 指向本机或内网地址，已拦截")
                return ok
            }
        }
        private val client by lazy { base.newBuilder().dns(dns).build() }
        /** Only for requests where a script explicitly asked to skip certificate checks. */
        private val unverified by lazy {
            val ssl = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trustAll), SecureRandom()) }
            client.newBuilder().sslSocketFactory(ssl.socketFactory, trustAll).hostnameVerifier { _, _ -> true }.build()
        }

        private fun allowed(a: InetAddress): Boolean = when {
            a.isLoopbackAddress || a.isAnyLocalAddress || a.isMulticastAddress -> false
            rules.allowPrivate -> true
            else -> !NetGuard.isBlockedIP(a.hostAddress.orEmpty())
        }

        /** Literal addresses never reach [dns]: checked here, before every hop. */
        fun check(u: HttpUrl) {
            val h = u.host
            if (isLoopback(h)) { if (u.port != ownPort()) throw IOException("不允许访问本机端口 ${u.port}") else return }
            if (NetGuard.isIPLiteral(h) && !allowed(InetAddress.getByName(h))) throw IOException("$h 是本机或内网地址，已拦截")
        }

        fun parse(url: String): HttpUrl = url.trim().toHttpUrlOrNull() ?: throw IOException("地址无效：${url.take(120)}")

        private fun build(u: HttpUrl, r: NetRequest, method: String, body: ByteArray?): Request {
            val b = Request.Builder().url(u)
            var agent = false
            for ((k, v) in r.headers) {
                if (k.isBlank() || v.any { it < ' ' && it != '\t' }) continue
                if (k.equals("accept-encoding", true) || k.equals("content-length", true)) continue // transparent gzip
                if (k.equals("user-agent", true)) agent = true
                runCatching { b.header(k.trim(), v.trim()) }.onFailure { runCatching { b.addUnsafeHeader(k.trim(), v.trim()) } }
            }
            if (!agent) b.header("User-Agent", UA)
            if (u.username.isNotEmpty() && r.headers.keys.none { it.equals("authorization", true) }) b.header("Authorization", Credentials.basic(u.username, u.password))
            for (rule in rules.headers) if (u.host == rule.host || u.host.endsWith("." + rule.host)) for ((k, v) in rule.headers) runCatching { b.header(k, v) }
            val type = r.headers.entries.firstOrNull { it.key.equals("content-type", true) }?.value
            b.method(method, when { method == "GET" || method == "HEAD" -> null; else -> (body ?: ByteArray(0)).toRequestBody(type?.toMediaTypeOrNull()) })
            r.tag?.let { b.tag(Any::class.java, it) }
            return b.build()
        }

        /** Opens the final response after following checked redirects; the caller closes it. */
        fun open(r: NetRequest): Response {
            val c = (if (r.verify) client else unverified).newBuilder().callTimeout(r.timeoutMs, TimeUnit.MILLISECONDS)
                .connectTimeout(minOf(r.timeoutMs, 10_000), TimeUnit.MILLISECONDS).readTimeout(r.timeoutMs, TimeUnit.MILLISECONDS).build()
            var u = parse(r.url)
            var method = r.method.uppercase()
            var body = r.body
            for (hop in 0..8) {
                check(u)
                if (!r.loopback && isLoopback(u.host)) throw IOException("不允许访问本机地址")
                val resp = c.newCall(build(u, r, method, body)).execute()
                val location = resp.header("Location")
                if (!r.redirect || resp.code !in REDIRECTS || location == null) return resp
                val next = u.resolve(location)
                resp.close()
                u = next ?: throw IOException("跳转地址无效")
                if (resp.code == 303 || ((resp.code == 301 || resp.code == 302) && method == "POST")) { method = "GET"; body = null }
            }
            throw IOException("跳转次数过多")
        }

        override fun cancel(tag: Any) = this@TVBoxNet.cancel(tag)

        override fun save(r: NetRequest, to: File): NetResponse = open(r).use { resp ->
            resp.body?.byteStream()?.use { s -> to.outputStream().use { copy(s, it, r.maxBytes) } }
            NetResponse(resp.code, resp.request.url.toString(), resp.headers.toMultimap(), ByteArray(0))
        }

        override fun execute(r: NetRequest): NetResponse {
            if (TVBoxUrl.isLocal(r.url)) return NetResponse(200, r.url, emptyMap(), local(r.url))
            return open(r).use { resp ->
                val bytes = resp.body?.byteStream()?.use { capped(it, r.maxBytes) } ?: ByteArray(0)
                NetResponse(resp.code, resp.request.url.toString(), resp.headers.toMultimap(), bytes)
            }
        }
    }

    private fun Request.Builder.addUnsafeHeader(k: String, v: String) {
        // header values with non-ASCII characters (Chinese Referer paths) are percent-encoded instead of rejected
        header(k, v.map { if (it.code in 32..126) it.toString() else java.net.URLEncoder.encode(it.toString(), "UTF-8") }.joinToString(""))
    }

    private val doh = ConcurrentHashMap<String, Dns>()
    private fun dohDns(d: TVBoxDoh): Dns = doh.getOrPut(d.url) {
        val url = d.url.toHttpUrlOrNull() ?: return Dns.SYSTEM
        DnsOverHttps.Builder().client(base).url(url).apply {
            val ips = d.ips.filter { NetGuard.isIPLiteral(it) }.map { InetAddress.getByName(it) }
            if (ips.isNotEmpty()) bootstrapDnsHosts(ips)
        }.build().let { secure -> object : Dns { override fun lookup(hostname: String) = try { secure.lookup(hostname) } catch (_: IOException) { Dns.SYSTEM.lookup(hostname) } } }
    }

    /** Files imported by the user: `clan://localhost/x`, `file:///x` — only inside the import folder. */
    fun local(url: String): ByteArray {
        val f = localFile(url) ?: throw IOException("本地文件不存在：${TVBoxUrl.fileName(url)}（请先导入该文件）")
        return f.readBytes()
    }

    fun localFile(url: String): File? {
        val dir = localDir?.canonicalFile ?: return null
        val path = TVBoxUrl.decode(url.substringAfter("://").substringBefore('?').substringBefore(";md5;")).removePrefix("localhost").trimStart('/')
        return listOf(File(dir, path), File(dir, path.substringAfterLast('/'))).map { it.canonicalFile }.firstOrNull { it.isFile && it.path.startsWith(dir.path + File.separator) }
    }

    /** Aborts everything a spider session or a screen still has in flight. */
    fun cancel(tag: Any) {
        fun Call.mine() = request().tag(Any::class.java) === tag
        base.dispatcher.runningCalls().filter { it.mine() }.forEach { it.cancel() }
        base.dispatcher.queuedCalls().filter { it.mine() }.forEach { it.cancel() }
    }

    companion object {
        /** Many config hosts answer browsers with a landing page. */
        const val UA = "okhttp/4.12.0"
        private val REDIRECTS = setOf(301, 302, 303, 307, 308)

        fun capped(s: InputStream, max: Int): ByteArray = ByteArrayOutputStream().also { copy(s, it, max) }.toByteArray()

        private fun copy(s: InputStream, out: OutputStream, max: Int) {
            val buf = ByteArray(16 * 1024)
            var size = 0
            while (true) {
                val n = s.read(buf)
                if (n < 0) return
                if (size + n > max) throw IOException("内容超过 ${max shr 20} MB")
                out.write(buf, 0, n)
                size += n
            }
        }

        fun isLoopback(host: String) = host == "localhost" || host.endsWith(".localhost") || host == "::1" || host.startsWith("127.")

        /** True when a config address itself sits in a private network (then its relative resources may too). Imported files do not. */
        fun isPrivateAddress(url: String): Boolean {
            val h = if (TVBoxUrl.isHttp(url)) TVBoxUrl.host(url) else ""
            return when {
                h.isEmpty() -> false
                h == "localhost" || h.endsWith(".local") || h.endsWith(".lan") -> true
                NetGuard.isIPLiteral(h) -> NetGuard.isBlockedIP(h)
                else -> false
            }
        }
    }
}
