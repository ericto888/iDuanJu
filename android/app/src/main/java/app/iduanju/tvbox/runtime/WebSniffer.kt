package app.iduanju.tvbox.runtime

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.net.http.SslError
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import app.iduanju.core.tvbox.SniffRequest
import app.iduanju.core.tvbox.SniffResult
import app.iduanju.core.tvbox.SniffRules
import app.iduanju.core.tvbox.Sniffer
import app.iduanju.core.tvbox.TVBoxUrl
import app.iduanju.core.util.NetGuard
import app.iduanju.core.util.ProviderException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.ByteArrayInputStream

/**
 * Hidden browser that loads a play page and reports the first media request. The view lives on the main thread, is never
 * attached to a window and is destroyed on success, failure, timeout and cancellation alike. At most two run at once.
 */
class WebSniffer(private val ctx: Context, private val ownPort: () -> Int) : Sniffer {
    private val gate = Semaphore(2)

    override suspend fun sniff(r: SniffRequest): SniffResult = gate.withPermit {
        val found = CompletableDeferred<SniffResult>()
        val checks = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        var view: WebView? = null
        try {
            // assigned before anything can fail: a cancellation or a header the browser refuses must still find it
            withContext(Dispatchers.Main) { WebView(ctx).let { view = it; open(it, r, found, checks) } }
            withTimeoutOrNull(r.timeoutMs) { found.await() } ?: throw ProviderException.upstream("解析超时，没有嗅探到播放地址")
        } finally {
            checks.cancel()
            withContext(NonCancellable + Dispatchers.Main) { view?.let(::close) }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun open(view: WebView, r: SniffRequest, found: CompletableDeferred<SniffResult>, checks: CoroutineScope) {
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            loadsImagesAutomatically = false
            blockNetworkImage = true
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            cacheMode = WebSettings.LOAD_DEFAULT
            userAgentString = r.headers.entries.firstOrNull { it.key.equals("user-agent", true) }?.value ?: PHONE_UA
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, true)
        view.webChromeClient = object : WebChromeClient() {
            override fun onJsAlert(v: WebView?, url: String?, message: String?, result: android.webkit.JsResult?): Boolean { result?.cancel(); return true }
            override fun onJsConfirm(v: WebView?, url: String?, message: String?, result: android.webkit.JsResult?): Boolean { result?.cancel(); return true }
            override fun onJsPrompt(v: WebView?, url: String?, message: String?, default: String?, result: android.webkit.JsPromptResult?): Boolean { result?.cancel(); return true }
            override fun onPermissionRequest(request: android.webkit.PermissionRequest?) { request?.deny() }
            override fun getDefaultVideoPoster(): Bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
        }
        view.webViewClient = Client(r, found, checks)
        val cookie = r.headers.entries.firstOrNull { it.key.equals("cookie", true) }?.value
        if (cookie != null) cookie.split(';').forEach { CookieManager.getInstance().setCookie(r.url, it.trim()) }
        view.loadUrl(r.url, r.headers.filterKeys { !it.equals("user-agent", true) && !it.equals("cookie", true) })
    }

    private fun close(view: WebView) {
        view.webViewClient = WebViewClient()
        view.webChromeClient = null
        view.stopLoading()
        view.loadUrl("about:blank")
        view.onPause()
        (view.parent as? ViewGroup)?.removeView(view)
        view.removeAllViews()
        view.destroy()
    }

    private inner class Client(private val r: SniffRequest, private val found: CompletableDeferred<SniffResult>, private val checks: CoroutineScope) : WebViewClient() {
        private val main = Handler(Looper.getMainLooper())
        @Volatile private var page = r.url
        private val seen = java.util.Collections.synchronizedSet(HashSet<String>())

        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            val url = request.url.toString()
            val host = request.url.host.orEmpty().lowercase()
            if (found.isCompleted || SniffRules.isAd(host, r.ads) || !reachable(host, request.url.port)) return blocked()
            if (!url.startsWith("http")) return null
            val manual = r.isVideo
            if (manual != null && seen.add(url)) checks.launch { if (manual(url)) done(url, request.requestHeaders) }
            else if (manual == null && SniffRules.isVideo(url, page, r.rules)) { done(url, request.requestHeaders); return blocked() }
            return null
        }

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val url = request.url.toString()
            if (!url.startsWith("http")) return true // app links never leave the sniffer
            if (r.isVideo == null && SniffRules.isVideo(url, page, r.rules)) { done(url, request.requestHeaders); return true }
            return false
        }

        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) { page = url }

        override fun onPageFinished(view: WebView, url: String) {
            if (url == "about:blank" || found.isCompleted) return
            r.scripts.forEachIndexed { i, s -> main.postDelayed({ if (!found.isCompleted) view.evaluateJavascript(s, null) }, 300L * i) }
        }

        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) = handler.cancel()

        override fun onRenderProcessGone(view: WebView, detail: android.webkit.RenderProcessGoneDetail): Boolean {
            found.completeExceptionally(ProviderException.upstream("解析页面崩溃"))
            return true
        }

        private fun done(url: String, sent: Map<String, String>?) {
            val h = LinkedHashMap<String, String>()
            sent?.forEach { (k, v) -> if (KEEP.any { it.equals(k, true) }) h[TVBoxUrl.headerName(k)] = v }
            r.headers.forEach { (k, v) -> if (k.equals("user-agent", true)) h["User-Agent"] = v }
            if ("User-Agent" !in h) h["User-Agent"] = PHONE_UA
            runCatching { CookieManager.getInstance().getCookie(url) }.getOrNull()?.takeIf { it.isNotEmpty() }?.let { h["Cookie"] = it }
            found.complete(SniffResult(url, h))
        }

        /** Same address policy as every other TVBox request; names are resolved on this (non-main) interception thread. */
        private fun reachable(host: String, port: Int): Boolean = when {
            host.isEmpty() -> true
            host == "localhost" || host.startsWith("127.") -> port == ownPort()
            r.allowPrivate -> true
            NetGuard.isIPLiteral(host) -> !NetGuard.isBlockedIP(host)
            else -> !NetGuard.resolvesToBlocked(host)
        }

        private fun blocked() = WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(ByteArray(0)))
    }

    private companion object {
        const val PHONE_UA = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"
        val KEEP = listOf("user-agent", "referer", "origin", "cookie")
    }
}
