package app.iduanju.core.tvbox

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.BindException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.Semaphore
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

class HttpIn(
    val method: String, val path: String, val rawQuery: String, val query: Map<String, String>,
    /** Lower-case header names. */
    val headers: Map<String, String>, val body: ByteArray, val remote: InetAddress,
)

/**
 * Small HTTP/1.1 server: one request per connection, streamed replies, `Range` left to the handler. [loopback] servers only
 * listen on 127.0.0.1 and only answer requests addressed to it (no DNS rebinding through a web page) and not sent by one
 * (players and spiders send no `Origin`; a site open in a browser must not be able to fetch through the spiders' proxies).
 */
class LocalServer(private val name: String, private val loopback: Boolean, private val ports: Iterable<Int>, private val handler: (HttpIn) -> ProxyReply) {
    @Volatile var port = 0
        private set
    @Volatile private var socket: ServerSocket? = null
    private var pool: ThreadPoolExecutor? = null
    /** Bodies arrive before anything can be authenticated: only a few big ones at a time. */
    private val bodies = Semaphore(4)

    val running: Boolean get() = socket?.isClosed == false

    /** Starts on the first free port of [ports]; returns the port (0 when every port is taken). */
    @Synchronized fun start(): Int {
        if (running) return port
        for (p in ports) {
            val s = ServerSocket()
            try {
                s.reuseAddress = true
                s.bind(InetSocketAddress(if (loopback) InetAddress.getByName("127.0.0.1") else null, p), 64)
            } catch (_: BindException) { s.close(); continue } catch (_: IOException) { s.close(); continue }
            socket = s
            port = p
            val workers = ThreadPoolExecutor(0, 48, 20, TimeUnit.SECONDS, SynchronousQueue()) { r -> Thread(r, "$name-worker").apply { isDaemon = true } }
            pool = workers
            Thread({ accept(s, workers) }, name).apply { isDaemon = true }.start()
            return p
        }
        return 0
    }

    @Synchronized fun stop() {
        runCatching { socket?.close() }
        socket = null
        pool?.shutdownNow()
        pool = null
        port = 0
    }

    private fun accept(s: ServerSocket, workers: ThreadPoolExecutor) {
        while (!s.isClosed) {
            val c = try { s.accept() } catch (_: IOException) { if (s.isClosed) return else continue }
            try { workers.execute { c.use(::serve) } } catch (_: RejectedExecutionException) { runCatching { c.close() } }
        }
    }

    private fun serve(c: Socket) {
        try {
            c.soTimeout = 20_000
            c.tcpNoDelay = true
            val out = BufferedOutputStream(c.getOutputStream(), 32 * 1024)
            val req = read(BufferedInputStream(c.getInputStream(), 8 * 1024), c.inetAddress) ?: return
            val host = req.headers["host"].orEmpty().substringBeforeLast(':').ifEmpty { req.headers["host"].orEmpty() }
            val reply = when {
                loopback && !req.remote.isLoopbackAddress -> ProxyReply.text("forbidden", 403)
                loopback && host.isNotEmpty() && host != "127.0.0.1" && host != "localhost" -> ProxyReply.text("forbidden", 403)
                loopback && fromWebPage(req.headers) -> ProxyReply.text("forbidden", 403)
                else -> try { handler(req) } catch (e: Throwable) { ProxyReply.text(SpiderErrors.text(e), 500) }
            }
            reply.body.use { write(out, req, reply, it) }
            out.flush()
        } catch (_: IOException) {
            // the player closed the connection (seek / stop)
        } catch (_: Throwable) {
            // a spider's own stream may throw anything: it ends this reply, never the app
        }
    }

    private fun fromWebPage(h: Map<String, String>): Boolean {
        if (h["sec-fetch-site"] == "cross-site") return true
        val origin = h["origin"]?.lowercase()?.substringAfter("://")?.substringBefore(':') ?: return false
        return origin != "127.0.0.1" && origin != "localhost"
    }

    private fun read(input: InputStream, remote: InetAddress): HttpIn? {
        fun line(limit: Int): String? {
            val sb = ByteArrayOutputStream()
            while (true) {
                val b = input.read()
                if (b < 0) return if (sb.size() == 0) null else sb.toString("UTF-8")
                if (b == '\n'.code) return sb.toString("UTF-8").trimEnd('\r')
                sb.write(b)
                if (sb.size() > limit) throw IOException("请求过长")
            }
        }
        val first = line(64 * 1024)?.split(' ') ?: return null
        if (first.size < 3) return null
        val headers = HashMap<String, String>()
        while (true) {
            val l = line(16 * 1024) ?: return null
            if (l.isEmpty()) break
            val i = l.indexOf(':')
            if (i > 0) headers[l.substring(0, i).trim().lowercase()] = l.substring(i + 1).trim()
            if (headers.size > 100) return null
        }
        val length = headers["content-length"]?.toIntOrNull() ?: 0
        if (length < 0 || length > if (loopback) 256 shl 10 else 4 shl 20) throw IOException("正文过大")
        val body = if (length <= 64 shl 10) body(input, length) else {
            if (!bodies.tryAcquire()) throw IOException("请求过多")
            try { body(input, length) } finally { bodies.release() }
        } ?: return null
        val target = first[1].let { if (it.startsWith("http://", true)) "/" + it.substringAfter("://").substringAfter('/', "") else it }
        val raw = target.substringAfter('?', "")
        val query = LinkedHashMap<String, String>()
        parseQuery(raw, query)
        if (headers["content-type"].orEmpty().startsWith("application/x-www-form-urlencoded")) parseQuery(String(body, Charsets.UTF_8), query)
        return HttpIn(first[0].uppercase(), TVBoxUrl.decode(target.substringBefore('?')), raw, query, headers, body, remote)
    }

    /** Grows with what really arrives. */
    private fun body(input: InputStream, length: Int): ByteArray? {
        val out = ByteArrayOutputStream(minOf(length, 8 shl 10))
        val buf = ByteArray(8 shl 10)
        while (out.size() < length) { val n = input.read(buf, 0, minOf(buf.size, length - out.size())); if (n < 0) return null; out.write(buf, 0, n) }
        return out.toByteArray()
    }

    private fun write(out: OutputStream, req: HttpIn, r: ProxyReply, body: InputStream) {
        val sb = StringBuilder("HTTP/1.1 ").append(r.code).append(' ').append(REASON[r.code] ?: "OK").append("\r\n")
        var type = r.type.ifEmpty { "application/octet-stream" }
        var length = r.length
        for ((k, v) in r.headers) {
            val n = k.lowercase()
            if (v.any { it == '\r' || it == '\n' } || k.any { it <= ' ' || it == ':' }) continue
            when (n) {
                "connection", "transfer-encoding", "keep-alive", "server", "date" -> {}
                "content-type" -> type = v
                "content-length" -> if (length < 0) length = v.toLongOrNull() ?: -1
                else -> sb.append(k).append(": ").append(v).append("\r\n")
            }
        }
        sb.append("Content-Type: ").append(type).append("\r\nConnection: close\r\n")
        val empty = req.method == "HEAD" || r.code == 204 || r.code == 304
        if (length >= 0) sb.append("Content-Length: ").append(length).append("\r\n") else if (!empty) sb.append("Transfer-Encoding: chunked\r\n")
        out.write(sb.append("\r\n").toString().toByteArray(Charsets.UTF_8))
        if (empty) return
        val buf = ByteArray(32 * 1024)
        while (true) {
            val n = body.read(buf)
            if (n < 0) break
            if (n == 0) continue
            if (length < 0) { out.write((Integer.toHexString(n) + "\r\n").toByteArray()); out.write(buf, 0, n); out.write(CRLF); out.flush() } else out.write(buf, 0, n)
        }
        if (length < 0) out.write("0\r\n\r\n".toByteArray())
    }

    companion object {
        private val CRLF = "\r\n".toByteArray()
        private val REASON = mapOf(200 to "OK", 204 to "No Content", 206 to "Partial Content", 301 to "Moved Permanently", 302 to "Found", 304 to "Not Modified", 307 to "Temporary Redirect",
            400 to "Bad Request", 401 to "Unauthorized", 403 to "Forbidden", 404 to "Not Found", 405 to "Method Not Allowed", 416 to "Range Not Satisfiable", 429 to "Too Many Requests", 500 to "Internal Server Error", 502 to "Bad Gateway")

        fun parseQuery(raw: String, into: MutableMap<String, String>) {
            for (p in raw.split('&')) {
                if (p.isEmpty()) continue
                val i = p.indexOf('=')
                fun d(s: String) = try { java.net.URLDecoder.decode(s, "UTF-8") } catch (_: Exception) { s }
                if (i < 0) into[d(p)] = "" else into[d(p.substring(0, i))] = d(p.substring(i + 1))
            }
        }
    }
}
