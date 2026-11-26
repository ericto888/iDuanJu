package app.iduanju.tvbox

import app.iduanju.IdjApp
import app.iduanju.core.tvbox.TVBoxEngine
import app.iduanju.core.tvbox.TVBoxNet
import app.iduanju.core.tvbox.TVBoxUrl
import app.iduanju.core.util.NetGuard
import coil.intercept.Interceptor
import coil.request.ImageResult
import java.io.IOException
import java.net.InetAddress
import java.net.UnknownHostException
import okhttp3.Dns

/** TVBox pictures carry their request headers in the address (`…@Referer=…@User-Agent=…`): works on every screen of the app. */
object TVBoxPictureInterceptor : Interceptor {
    override suspend fun intercept(chain: Interceptor.Chain): ImageResult {
        val raw = chain.request.data as? String ?: return chain.proceed(chain.request)
        if (!raw.startsWith("//") && !raw.contains("@Referer=", true) && !raw.contains("@User-Agent=", true) && !raw.contains("@Headers=", true) && !raw.contains("@Cookie=", true)) return chain.proceed(chain.request)
        val p = TVBoxUrl.picture(raw)
        val request = chain.request.newBuilder().data(p.url).apply { p.headers.forEach { (k, v) -> runCatching { setHeader(k, v) } } }.build()
        return chain.proceed(request)
    }
}

class LanRefused(host: String) : UnknownHostException(TVBoxEngine.LAN_REFUSED + "（$host）")

/** Address policy of a client: private ranges only with [lan], loopback is only ever the app's own proxy. */
open class TVBoxAddressGuard(private val lan: () -> Boolean) : okhttp3.Interceptor, Dns {
    private fun allowed(a: InetAddress) = !a.isLoopbackAddress && (!NetGuard.isBlockedIP(a.hostAddress.orEmpty()) || lan())

    override fun lookup(hostname: String): List<InetAddress> {
        val all = Dns.SYSTEM.lookup(hostname)
        if (hostname == "localhost") return all
        return all.filter { allowed(it) }.ifEmpty { throw LanRefused(hostname) }
    }

    override fun intercept(chain: okhttp3.Interceptor.Chain): okhttp3.Response {
        val u = chain.request().url
        val h = u.host
        val loop = h == "localhost" || h.startsWith("127.") || h == "::1"
        if (loop && u.port != IdjApp.instance.tvbox.engine.runningPort) throw IOException("不允许访问本机端口")
        if (!loop && NetGuard.isIPLiteral(h) && !allowed(InetAddress.getByName(h))) throw LanRefused(h)
        return chain.proceed(chain.request())
    }
}

/** Pictures: a source may not make the app probe the user's network. They open up together with the TVBox LAN permission (or a config that lives there). */
object TVBoxPictureGuard : TVBoxAddressGuard({ IdjApp.instance.tvbox.let { s -> s.state.allowLan || s.repos.any { TVBoxNet.isPrivateAddress(it.record.base) } } })

/** Streams, playlists, subtitles and comments of configs without the LAN permission. */
object TVBoxMediaGuard : TVBoxAddressGuard({ false })
