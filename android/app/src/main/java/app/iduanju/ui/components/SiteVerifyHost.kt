package app.iduanju.ui.components

import android.annotation.SuppressLint
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.iduanju.ui.theme.IdjThemeColors
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Visible user-interactive WebView verification modal (mirrors iOS `SiteVerifySheet`).
 * When a plugin encounters a Cloudflare/human verification interstitial, this opens a visible WebView
 * so the user can complete the verification directly, then syncs the resulting session cookies & UA.
 */
object SiteVerifyHost {
    data class Pending(
        val title: String,
        val url: String,
        val finish: (cookies: String?, ua: String?) -> Unit,
    )

    var pending by mutableStateOf<Pending?>(null)
        private set

    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Blocks the calling IO thread while the user completes verification in the visible WebView dialog.
     * Returns true if the user completed verification and cookies were synced, false on cancel/timeout.
     */
    fun requestUserVerificationBlocking(
        title: String,
        url: String,
        onSynced: (cookies: String, ua: String) -> Unit,
    ): Boolean {
        if (Looper.myLooper() == Looper.getMainLooper()) return false
        synchronized(lock) {
            val latch = CountDownLatch(1)
            val completed = AtomicBoolean(false)
            val resultOk = AtomicBoolean(false)
            val finishFn: (String?, String?) -> Unit = { cookies, ua ->
                if (completed.compareAndSet(false, true)) {
                    if (cookies != null) {
                        onSynced(cookies, ua.orEmpty())
                        resultOk.set(true)
                    }
                    mainHandler.post { pending = null }
                    latch.countDown()
                }
            }
            mainHandler.post {
                pending = Pending(title = title, url = url, finish = finishFn)
            }
            latch.await(120, TimeUnit.SECONDS)
            if (completed.compareAndSet(false, true)) {
                mainHandler.post { pending = null }
            }
            return resultOk.get()
        }
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun SiteVerifyHostOverlay() {
    val req = SiteVerifyHost.pending ?: return
    val c = IdjThemeColors
    var webView by remember(req) { mutableStateOf<WebView?>(null) }
    var pageTitle by remember(req) { mutableStateOf("") }

    fun completeWithCurrentCookies() {
        val cm = CookieManager.getInstance()
        runCatching { cm.flush() }
        val cookies = runCatching { cm.getCookie(req.url) }.getOrNull().orEmpty()
        val ua = runCatching { webView?.settings?.userAgentString }.getOrNull().orEmpty()
        req.finish(cookies, ua)
    }

    Dialog(
        onDismissRequest = { req.finish(null, null) },
        properties = DialogProperties(usePlatformDefaultWidth = false, dismissOnClickOutside = false),
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .background(c.bg)
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                GlassTextButton("取消", color = c.secondary, fontSize = 16.sp) { req.finish(null, null) }
                Text(
                    "${req.title} · 站点验证",
                    color = c.text,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f).semantics { heading() },
                )
                GlassTextButton("完成", fontSize = 16.sp, fontWeight = FontWeight.SemiBold) { completeWithCurrentCookies() }
            }
            Hairline()
            Row(
                Modifier.fillMaxWidth().background(c.glass).padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Outlined.Shield, null, Modifier.size(18.dp), tint = c.accentWarm)
                Text(
                    if (pageTitle.isNotEmpty()) "请在下方完成人机验证后点击右上角「完成」 · $pageTitle"
                    else "请在下方页面完成人机验证，验证通过后点击右上角「完成」返回",
                    color = c.secondary,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            AndroidView(
                factory = { ctx ->
                    WebView(ctx).apply {
                        val cm = CookieManager.getInstance()
                        cm.setAcceptCookie(true)
                        cm.setAcceptThirdPartyCookies(this, true)
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        settings.useWideViewPort = true
                        settings.loadWithOverviewMode = true
                        webChromeClient = object : WebChromeClient() {
                            override fun onReceivedTitle(view: WebView?, title: String?) {
                                if (!title.isNullOrBlank()) pageTitle = title
                            }
                        }
                        webViewClient = object : WebViewClient() {
                            override fun onPageFinished(view: WebView?, url: String?) {
                                runCatching { CookieManager.getInstance().flush() }
                            }
                        }
                        webView = this
                        loadUrl(req.url)
                    }
                },
                modifier = Modifier.weight(1f).fillMaxWidth(),
            )
        }
    }

    DisposableEffect(req) {
        onDispose {
            webView?.stopLoading()
            webView?.destroy()
            webView = null
        }
    }
}
