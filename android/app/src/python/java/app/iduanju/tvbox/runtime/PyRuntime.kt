package app.iduanju.tvbox.runtime

import android.content.Context
import app.iduanju.core.tvbox.PyEngine
import app.iduanju.core.tvbox.ScriptHost
import app.iduanju.core.util.ProviderException
import com.chaquo.python.PyException
import com.chaquo.python.PyObject
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/** Embedded CPython (Chaquopy), started on first use on the calling spider thread. */
object PyRuntime {
    const val INCLUDED = true
    fun create(ctx: Context): PyEngine? = Engine(ctx.applicationContext)

    private class Engine(private val ctx: Context) : PyEngine {
        private val runner: PyObject by lazy {
            if (!Python.isStarted()) Python.start(AndroidPlatform(ctx))
            Python.getInstance().getModule("idj_runner")
        }

        private fun <T> guard(f: () -> T): T = try { f() } catch (e: PyException) { throw ProviderException.unsupported(e.message.orEmpty().substringAfter("RuntimeError: ").lineSequence().first().take(200)) }

        override fun load(key: String, source: String, ext: String, siteKey: String, url: String, host: ScriptHost) {
            PyHost.bind(key, siteKey, host)
            guard { runner.callAttr("load", key, source, ext, siteKey, url) }
        }
        override fun call(key: String, method: String, argsJson: String): String = guard { runner.callAttr("call", key, method, argsJson).toString() }
        override fun unload(key: String) { runCatching { guard { runner.callAttr("unload", key) } }; PyHost.unbind(key) }
    }
}

/** Entry point of `_idj_host.call`; scripts may call it from their own worker threads as well. */
object PyHost {
    private val current = ThreadLocal<ScriptHost>()
    private val bySite = ConcurrentHashMap<String, ScriptHost>()
    private val keys = ConcurrentHashMap<String, String>()

    fun bind(key: String, siteKey: String, host: ScriptHost) { current.set(host); bySite[siteKey] = host; keys[key] = siteKey }
    fun unbind(key: String) { keys.remove(key)?.let { if (it !in keys.values) bySite.remove(it) } }

    @JvmStatic fun call(name: String, args: String): String {
        val host = current.get() ?: runCatching { JSONObject(args) }.getOrNull()?.let { o -> bySite[o.optString("siteKey")] ?: bySite[o.optString("ns")] } ?: bySite.values.firstOrNull()
            ?: return "{\"e\":\"脚本还没有加载\"}"
        return host.call(name, args)
    }
}
