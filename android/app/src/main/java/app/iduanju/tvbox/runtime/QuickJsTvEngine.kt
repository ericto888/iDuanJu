package app.iduanju.tvbox.runtime

import app.iduanju.core.tvbox.JsEngine
import app.iduanju.core.tvbox.SpiderErrors
import com.whl.quickjs.android.QuickJSLoader
import com.whl.quickjs.wrapper.JSCallFunction
import com.whl.quickjs.wrapper.JSObject
import com.whl.quickjs.wrapper.ModuleLoader
import com.whl.quickjs.wrapper.QuickJSContext
import org.json.JSONObject

/** QuickJS behind the script-spider contract: ES modules through [modules], one context on the spider's own thread. */
class QuickJsTvEngine : JsEngine {
    private val ctx: QuickJSContext
    private var closed = false

    init {
        synchronized(QuickJsTvEngine::class.java) { if (!loaded) { QuickJSLoader.init(); loaded = true } }
        ctx = QuickJSContext.create()
        ctx.setMemoryLimit(160 * 1024 * 1024)
        // spider threads have an 8 MB stack
        ctx.setMaxStackSize(4 * 1024 * 1024)
    }

    override fun install(call: (String, String) -> String) {
        ctx.globalObject.setProperty("__tv", JSCallFunction { a -> call(a.getOrNull(0)?.toString().orEmpty(), a.getOrNull(1)?.toString().orEmpty()) })
    }

    override fun modules(normalize: (base: String, name: String) -> String, load: (name: String) -> String) {
        ctx.setModuleLoader(object : ModuleLoader() {
            override fun isBytecodeMode() = false
            override fun getModuleBytecode(name: String?): ByteArray? = null
            // a Java exception must not cross the native module callback: the module itself throws instead
            override fun getModuleStringCode(name: String?): String = try { load(name.orEmpty()) } catch (e: Throwable) { "throw new Error(" + JSONObject.quote(SpiderErrors.text(e)) + ");" }
            override fun moduleNormalizeName(base: String?, name: String?): String = normalize(base.orEmpty(), name.orEmpty())
        })
    }

    private fun plain(v: Any?): Any? = if (v is JSObject) { val s = v.toString(); v.release(); s } else v

    override fun script(code: String, name: String): Any? = plain(ctx.evaluate(code, name))
    override fun module(code: String, name: String) { plain(ctx.evaluateModule(code, name)) }

    override fun close() {
        if (closed) return
        closed = true
        runCatching { ctx.destroy() }
    }

    companion object { @Volatile private var loaded = false }
}
