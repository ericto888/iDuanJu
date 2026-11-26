package app.iduanju.tvbox.runtime

import android.content.Context
import app.iduanju.core.tvbox.PyEngine

/** Build without the embedded Python (`-Pidj.python` not set). */
object PyRuntime {
    const val INCLUDED = false
    @Suppress("UNUSED_PARAMETER") fun create(ctx: Context): PyEngine? = null
}
