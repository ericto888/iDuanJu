package app.iduanju.core.tvbox

import app.iduanju.core.util.ProviderException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.concurrent.ExecutorService
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class SpiderTimeout(message: String) : Exception(message)
/** The session was closed (config removed, evicted, stuck) before the call could start. */
class SpiderStopped(message: String) : Exception(message)

/** One shared wake-up thread for call deadlines. */
internal object SpiderClock {
    private val timer = ScheduledThreadPoolExecutor(1) { r -> Thread(r, "tvbox-deadline").apply { isDaemon = true } }.apply { removeOnCancelPolicy = true }
    fun after(ms: Long, block: () -> Unit) = timer.schedule(block, ms, TimeUnit.MILLISECONDS)
}

/**
 * A spider instance and the single thread it lives on. The instance is created and initialised lazily on that thread; every
 * call has a deadline measured from the moment it starts running (not from when it was queued). A call that ignores its
 * interrupt poisons the session ([dead]); the engine then starts a fresh one. [create] is told what aborts the requests of an
 * initialisation that is no longer wanted.
 */
class SpiderSession(val name: String, private val initTimeoutMs: Long = 45_000, val kind: SiteKind = SiteKind.Unsupported, private val create: (onAbort: (() -> Unit) -> Unit) -> Spider) {
    private class Task(private val body: () -> Unit, val abort: () -> Unit) : Runnable { override fun run() = body() }

    private val executor: ExecutorService = ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS, LinkedBlockingQueue()) { r ->
        // spiders parse big documents recursively: give them more than the 1 MB default
        Thread(null, r, "tvbox-$name".take(40), 8L shl 20).apply { isDaemon = true; priority = Thread.NORM_PRIORITY - 1 }
    }
    @Volatile var dead = false
        private set
    @Volatile private var spider: Spider? = null
    /** Set while the spider is being created. */
    @Volatile private var starting: (() -> Unit)? = null
    /** The thread was given up on: whatever it still creates or holds is released when it unwinds. */
    @Volatile private var abandoned = false
    @Volatile private var initError: Throwable? = null
    @Volatile private var initErrorAt = 0L

    private val inFlight = AtomicInteger()
    @Volatile var lastUsed = System.currentTimeMillis()
        private set

    val ready: Boolean get() = spider != null
    val busy: Boolean get() = inFlight.get() > 0

    /** Runs on the spider thread only. [cancelled]: the caller went away, which says nothing about the site. */
    private fun ensure(cancelled: () -> Boolean): Spider {
        spider?.let { return it }
        // a failed initialisation is remembered briefly so a burst of queued calls does not repeat a slow download
        initError?.let { if (System.currentTimeMillis() - initErrorAt < 5_000) throw it }
        return try { create { starting = it }.also { spider = it; initError = null } } catch (e: Throwable) {
            if (!cancelled()) { initError = e; initErrorAt = System.currentTimeMillis() }
            throw e
        } finally { starting = null }
    }

    /** Runs on the spider thread only. */
    private fun release() { val s = spider; spider = null; runCatching { s?.destroy() } }

    /** Creates / initialises the spider ahead of the first real call. */
    suspend fun warm() { run(initTimeoutMs, "初始化") { } }

    suspend fun <T> call(timeoutMs: Long, what: String, block: (Spider) -> T): T {
        inFlight.incrementAndGet()
        try {
            if (spider == null) run(initTimeoutMs, "初始化") { }
            return run(timeoutMs, what, block)
        } finally { lastUsed = System.currentTimeMillis(); inFlight.decrementAndGet() }
    }

    private suspend fun <T> run(timeoutMs: Long, what: String, block: (Spider) -> T): T = suspendCancellableCoroutine { cont ->
        if (dead) { cont.resumeWithException(SpiderStopped("「$name」已停止")); return@suspendCancellableCoroutine }
        val done = AtomicBoolean(false)
        val cancelled = AtomicBoolean(false)
        var worker: Thread? = null
        val lock = Any()
        fun stop() {
            // a call that is still queued must not disturb the one that is running
            val running = synchronized(lock) { worker?.interrupt(); worker != null }
            if (!running) return
            runCatching { spider?.interrupt() ?: starting?.invoke() }
            // the thread gets a grace period to unwind; a spider that keeps spinning is abandoned together with its session
            SpiderClock.after(3_000) { synchronized(lock) { if (worker != null) poison() } }
        }
        fun body() {
            if (!cont.isActive) return
            synchronized(lock) { worker = Thread.currentThread() }
            // cancelled in between: nobody would stop it any more
            if (done.get()) { synchronized(lock) { worker = null }; Thread.interrupted(); return }
            val deadline = SpiderClock.after(timeoutMs) {
                if (done.compareAndSet(false, true)) { stop(); if (cont.isActive) cont.resumeWithException(SpiderTimeout("「$name」$what 超时（${timeoutMs / 1000} 秒）")) }
            }
            try {
                val v = block(ensure { cancelled.get() })
                if (done.compareAndSet(false, true) && cont.isActive) cont.resume(v)
            } catch (e: Throwable) {
                if (done.compareAndSet(false, true) && cont.isActive) cont.resumeWithException(readable(e))
            } finally {
                deadline.cancel(false)
                synchronized(lock) { worker = null }
                Thread.interrupted() // a late interrupt must not leak into the next call
                if (abandoned) release()
            }
        }
        cont.invokeOnCancellation { cancelled.set(true); if (done.compareAndSet(false, true)) stop() }
        val task = Task(::body) { if (done.compareAndSet(false, true) && cont.isActive) cont.resumeWithException(SpiderStopped("「$name」已停止响应，请重试")) }
        try { executor.execute(task) } catch (_: RejectedExecutionException) { if (cont.isActive) cont.resumeWithException(SpiderStopped("「$name」已停止")) }
    }

    private fun readable(e: Throwable): Throwable {
        if (e is CancellationException || e is SpiderTimeout || e is ProviderException) return e
        if (e is InterruptedException || e is java.io.InterruptedIOException) return SpiderTimeout("「$name」请求被中断")
        return SpiderErrors.wrap(name, e)
    }

    private fun poison() {
        dead = true
        abandoned = true
        executor.shutdownNow().forEach { (it as? Task)?.abort?.invoke() }
    }

    fun close() {
        if (dead) return
        dead = true
        runCatching { spider?.interrupt() ?: starting?.invoke() }
        // read on its thread: a spider that is being created right now is destroyed too
        runCatching { executor.execute { release() } }
        executor.shutdown()
        SpiderClock.after(5_000) { if (!executor.isTerminated) abandoned = true; executor.shutdownNow().forEach { (it as? Task)?.abort?.invoke() } }
    }
}

/** Failures of downloaded code (LinkageError included) as one readable Chinese line. */
object SpiderErrors {
    /** Android: `Unable to resolve host "x": No address associated with hostname`. */
    private val HOST = Regex("\"([^\"]+)\"")

    fun wrap(name: String, e: Throwable): Exception = ProviderException.unsupported("「$name」${text(e)}")

    fun text(e: Throwable): String {
        var t: Throwable = e
        while ((t is java.lang.reflect.InvocationTargetException || t is RuntimeException || t is ExceptionInInitializerError) && t.cause != null && t.cause !== t) t = t.cause!!
        val m = t.message?.trim()?.lineSequence()?.firstOrNull()?.take(160).orEmpty()
        return when (t) {
            is ProviderException, is SpiderTimeout, is SpiderStopped -> m
            is NoSuchMethodError, is NoSuchFieldError, is AbstractMethodError, is IncompatibleClassChangeError -> "与当前版本不兼容：缺少接口 ${m.substringAfterLast(';').ifEmpty { m }}"
            is NoClassDefFoundError, is ClassNotFoundException -> "与当前版本不兼容：缺少类 ${m.substringAfterLast('/').substringAfterLast('.').trim('"', ';')}"
            is UnsatisfiedLinkError -> "依赖的本地库无法加载"
            is VerifyError, is LinkageError -> "代码无法加载：$m"
            is OutOfMemoryError -> "内存不足"
            is StackOverflowError -> "脚本递归过深"
            is java.net.UnknownHostException -> if (m.contains("拦截") || m.contains("无法解析")) m else "无法解析域名 " + (HOST.find(m)?.groupValues?.get(1) ?: m.substringBefore(':'))
            is java.net.SocketTimeoutException -> "网络超时"
            is javax.net.ssl.SSLException -> "安全连接失败"
            is java.net.ConnectException -> "无法连接服务器"
            is NullPointerException -> "站点返回的数据不完整" + (if (m.isEmpty()) "" else "（$m）")
            is java.io.IOException -> m.ifEmpty { "网络错误" }
            else -> m.ifEmpty { t.javaClass.simpleName }
        }
    }
}
