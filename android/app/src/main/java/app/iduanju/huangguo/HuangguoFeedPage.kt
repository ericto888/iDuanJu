package app.iduanju.huangguo

import android.content.Context
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.iduanju.IdjApp
import app.iduanju.core.huangguo.CoverCrypto
import app.iduanju.core.huangguo.HuangguoClient
import app.iduanju.core.huangguo.HuangguoSub
import app.iduanju.ui.components.EmptyState
import app.iduanju.ui.home.FeedGrid
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Interceptor
import okhttp3.ResponseBody.Companion.toResponseBody

/** SharedPreferences-backed map for HuangguoClient's mirror memory (stv.huangguo.*). */
class PrefsMap(ctx: Context) : AbstractMutableMap<String, String>() {
    private val sp = ctx.getSharedPreferences("idj", Context.MODE_PRIVATE)
    override val entries: MutableSet<MutableMap.MutableEntry<String, String>>
        get() = sp.all.filter { it.key.startsWith("stv.huangguo.") && it.value is String }.map { java.util.AbstractMap.SimpleEntry(it.key, it.value as String) as MutableMap.MutableEntry<String, String> }.toMutableSet()
    override fun get(key: String): String? = sp.getString(key, null)
    override fun put(key: String, value: String): String? { val o = get(key); sp.edit().putString(key, value).apply(); return o }
    override fun remove(key: String): String? { val o = get(key); sp.edit().remove(key).apply(); return o }
}

/** Coil/OkHttp interceptor: decodes 黄果 obfuscated covers (iOS CoverStore + CoverCrypto). */
object CoverDecryptInterceptor : Interceptor {
    private const val BROWSER_UA =
        "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"

    override fun intercept(chain: Interceptor.Chain): okhttp3.Response {
        val orig = chain.request()
        val req = orig.newBuilder().apply {
            if (orig.header("User-Agent").isNullOrEmpty()) header("User-Agent", BROWSER_UA)
            if (orig.header("Accept").isNullOrEmpty()) header("Accept", "image/avif,image/webp,image/apng,image/*,*/*;q=0.8")
        }.build()
        val r = chain.proceed(req)
        val kind = CoverCrypto.kind(req.url.toString())
        if (kind == CoverCrypto.Kind.plain || !r.isSuccessful) return r
        val body = r.body ?: return r
        val bytes = runCatching { CoverCrypto.decrypt(body.bytes(), kind) }.getOrElse { return r.newBuilder().code(502).body(ByteArray(0).toResponseBody()).build() }
        return r.newBuilder().body(bytes.toResponseBody(body.contentType())).removeHeader("Content-Length").build()
    }
}

/**
 * 「黄果」 home page. Adult source: shown only once the adult gate is unlocked (我的 → 片源管理).
 * Chips: 视频站 categories + AI 站 channels + App 源 tabs (iOS splits them across 黄果 / AI剧 pages).
 */
@Composable
/** iOS splits 黄果 across two pages: 「黄果」 = 视频站 + App 源, 「AI剧」 → 黄果 AI 站 ([aiOnly]). */
fun HuangguoFeedPage(onOpen: (String) -> Unit, aiOnly: Boolean = false) {
    if (!IdjApp.instance.cms.adultUnlocked) {
        EmptyState("黄果为成人片源，默认隐藏", Modifier.padding(top = 80.dp), note = "在「我的 → 片源管理」开启成人内容后显示。", icon = Icons.Rounded.Lock)
        return
    }
    val hg = IdjApp.instance.huangguo
    val base = remember(aiOnly) { if (aiOnly) HuangguoClient.aiChannels.map { "ai/" + it.slug to it.title } else HuangguoClient.videoChannels.map { "video/" + it.slug to it.title } }
    var cats by remember(aiOnly) { mutableStateOf(base) }
    LaunchedEffect(aiOnly) {
        if (!aiOnly) runCatching { withContext(Dispatchers.IO) { hg.legacyChannels() } }.getOrNull()?.let { tabs -> cats = base + tabs.map { "legacy/" + it.slug to "App·" + it.title } }
    }
    FeedGrid(if (aiOnly) "huangguo-ai" else "huangguo", cats, { cat, page ->
        val sub = HuangguoSub.valueOf(cat.substringBefore('/')); val slug = cat.substringAfter('/')
        val ch = (HuangguoClient.videoChannels + HuangguoClient.aiChannels).firstOrNull { it.sub == sub && it.slug == slug }
            ?: app.iduanju.core.huangguo.HuangguoChannel(sub, slug, slug)
        hg.list(ch, page)
    }, onOpen)
}
