package app.iduanju.core.tvbox

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL

class BridgeTest {
    private var now = 1_800_000_000_000L
    private var code = "ABCD2345"
    private val auth = BridgeAuth({ code }, { now })
    private val calls = ArrayList<String>()
    private val target = object : BridgeTarget {
        override fun call(siteKey: String, api: String, ext: String, jar: String, method: String, args: JSONArray): String {
            calls += "$siteKey|$api|$ext|$jar|$method|$args"
            if (api == "csp_No") throw BridgeTarget.Denied("没有导入")
            // Gson output: '=' and '&' are escaped
            return """{"url":"http://127.0.0.1:9981/proxy?do=bili&id=1","vod_play_url":"1${'$'}http://127.0.0.1:9978/proxy?do=x#2${'$'}https://v.example/proxy?do=y","pic":"proxy://do=csp&u=1","other":"http://127.0.0.1:5000/proxy?x=1"}"""
        }
        override fun proxy(params: Map<String, String>) = if (params["do"] == "m3u8") ProxyReply.text("#EXTM3U\nhttp://127.0.0.1:9981/proxy?do=ts&n=1\n", type = "application/vnd.apple.mpegurl") else ProxyReply(206, "video/mp2t", (params.toString()).byteInputStream(), mapOf("Content-Range" to "bytes 0-9/10"))
        override val proxyPort = 9981
    }
    private val handler = BridgeHandler(auth, target)

    private fun post(body: String, time: Long = now / 1000, nonce: String = "nonce-" + System.nanoTime(), sign: String? = null, ip: String = "192.168.1.9", path: String = "/bridge/call"): Pair<Int, JSONObject> {
        val b = body.toByteArray()
        val h = mapOf("x-idj-time" to "$time", "x-idj-nonce" to nonce, "x-idj-sign" to (sign ?: BridgeAuth.sign(code, "$time", nonce, b)), "host" to "192.168.1.2:9979")
        val r = handler.handle(HttpIn("POST", path, "", emptyMap(), h, b, InetAddress.getByName(ip)))
        return r.code to JSONObject(r.body.readBytes().toString(Charsets.UTF_8))
    }

    private fun get(url: String): ProxyReply {
        val u = URL(url)
        return handler.handle(HttpIn("GET", u.path, u.query.orEmpty(), emptyMap(), mapOf("host" to "192.168.1.2:9979", "range" to "bytes=0-9"), ByteArray(0), InetAddress.getByName("192.168.1.9")))
    }

    @Test fun signedCallsAreAcceptedOnce() {
        val body = """{"siteKey":"k","api":"csp_A","ext":{"a":1},"jar":"https://j.example/a.jar","method":"playerContent","args":["f","id",["qq"]]}"""
        val (status, o) = post(body, nonce = "nonce-0001")
        assertEquals(200, status); assertEquals("""k|csp_A|{"a":1}|https://j.example/a.jar|playerContent|["f","id",["qq"]]""", calls.single())
        assertEquals(401, post(body, nonce = "nonce-0001").first) // replay
        assertEquals(200, post(body, nonce = "nonce-0002").first); assertEquals(200, post(body, time = now).first) // milliseconds work too
        assertEquals(200, post("", path = "/bridge/ping").first)
        val v = JSONObject(o.getString("v"))
        for (k in listOf("url", "pic")) assertTrue(v.getString(k), v.getString(k).startsWith("http://192.168.1.2:9979/bridge/proxy?do="))
        assertTrue(v.getString("vod_play_url").startsWith("1\$http://192.168.1.2:9979/bridge/proxy?do=x&idj_exp=")); assertTrue(v.getString("vod_play_url").endsWith("#2\$https://v.example/proxy?do=y")); assertEquals("http://127.0.0.1:5000/proxy?x=1", v.getString("other"))
    }

    @Test fun tamperedStaleAndForeignRequestsAreRejected() {
        val body = """{"api":"csp_A"}"""
        assertEquals(401, post(body, sign = "00".repeat(32)).first); assertEquals(401, post(body, sign = "").first)
        assertEquals(401, post(body, time = now / 1000 - 61).first); assertEquals(401, post(body, time = now / 1000 + 61).first); assertEquals(200, post(body, time = now / 1000 - 59).first)
        assertEquals(401, post(body, nonce = "short").first)
        assertEquals(401, post("""{"api":"csp_B"}""", sign = BridgeAuth.sign(code, "${now / 1000}", "n", body.toByteArray())).first)
        assertEquals(403, post(body, ip = "8.8.8.8").first)
        val (status, o) = post("""{"api":"csp_No"}"""); assertEquals(403, status); assertEquals("没有导入", o.getString("e"))
        code = ""; assertEquals(401, post(body, sign = "x").first)
    }

    @Test fun bruteForceIsLockedOutPerAddress() {
        repeat(10) { post("{}", sign = "00".repeat(32), ip = "192.168.1.77") }
        assertEquals(429, post("{}", ip = "192.168.1.77").first); assertEquals(200, post("""{"api":"x"}""", ip = "192.168.1.78").first)
        now += 61_000; assertEquals(200, post("""{"api":"x"}""", ip = "192.168.1.77").first)
    }

    @Test fun proxyAddressesAreSignedAndExpire() {
        val url = auth.signedProxy("http://192.168.1.2:9979", "do=bili&id=%E4%B8%AD")
        val r = get(url)
        assertEquals(206, r.code); val text = r.body.readBytes().toString(Charsets.UTF_8); assertTrue(text, text.contains("id=中") && text.contains("range=bytes=0-9") && !text.contains("idj_sign"))
        assertEquals(403, get(url.replace("do=bili", "do=other")).code); assertEquals(403, get("http://192.168.1.2:9979/bridge/proxy?do=bili").code)
        val list = get(auth.signedProxy("http://192.168.1.2:9979", "do=m3u8")).body.readBytes().toString(Charsets.UTF_8)
        assertTrue(list, list.contains("http://192.168.1.2:9979/bridge/proxy?do=ts&n=1&idj_exp="))
        now += BridgeAuth.PROXY_TTL_MS + 2000; assertEquals(403, get(url).code)
        assertEquals(404, get("http://192.168.1.2:9979/other?x=1").code)
    }

    @Test fun codesAreTwelveUnambiguousCharacters() {
        val codes = (1..50).map { BridgeAuth.newCode() }
        assertTrue(codes.all { it.length == 12 && it.none { c -> c in "01OIl" } }); assertTrue(codes.toSet().size > 45)
        assertNull(auth.verify("${now / 1000}", "nonce-abcdef", java.util.Base64.getEncoder().encodeToString(BridgeAuth.hmac(code, "${now / 1000}\nnonce-abcdef\n" + app.iduanju.core.util.Bytes.hex(app.iduanju.core.util.Bytes.sha256("x".toByteArray())))), "x".toByteArray()))
        assertNotNull(auth.verify("abc", "nonce-abcdef", "", ByteArray(0)))
    }

    @Test fun servesOverASocketWithChunkedAndHeadReplies() {
        val s = LocalServer("t", true, 19_970..19_990) { r -> if (r.path == "/echo") ProxyReply.text(r.method + r.body.toString(Charsets.UTF_8) + r.query["a"]) else ProxyReply(200, "video/mp2t", ByteArray(100_000) { 7 }.inputStream()) }
        val port = s.start()
        try {
            val c = URL("http://127.0.0.1:$port/echo?a=%E4%B8%AD").openConnection() as HttpURLConnection
            c.doOutput = true; c.outputStream.use { it.write("body".toByteArray()) }
            assertEquals("POSTbody中", c.inputStream.bufferedReader().readText())
            val chunked = URL("http://127.0.0.1:$port/x").openConnection() as HttpURLConnection
            assertEquals(100_000, chunked.inputStream.readBytes().size); assertEquals("chunked", chunked.getHeaderField("Transfer-Encoding"))
            val head = URL("http://127.0.0.1:$port/x").openConnection() as HttpURLConnection
            head.requestMethod = "HEAD"; assertEquals(200, head.responseCode); assertEquals(0, head.inputStream.readBytes().size)
            // a page open in a browser must not reach the spiders' proxies
            fun code(name: String, value: String): Int = java.net.Socket("127.0.0.1", port).use { k ->
                k.getOutputStream().write("GET /echo?a=1 HTTP/1.1\r\nHost: 127.0.0.1:$port\r\n$name: $value\r\n\r\n".toByteArray())
                k.getInputStream().bufferedReader().readLine().split(' ')[1].toInt()
            }
            assertEquals(403, code("Origin", "https://evil.example")); assertEquals(403, code("Sec-Fetch-Site", "cross-site"))
            assertEquals(200, code("Origin", "http://127.0.0.1:$port")); assertEquals(200, code("Range", "bytes=0-"))
            assertNull(head.getHeaderField("Access-Control-Allow-Origin"))
            assertEquals(port, s.start()) // already running
        } finally { s.stop() }
        assertEquals(0, s.port)
    }
}
