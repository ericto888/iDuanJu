package app.iduanju.data

import android.content.Context
import androidx.compose.runtime.mutableStateListOf
import app.iduanju.core.cms.CMSCategory
import app.iduanju.core.cms.CMSSite
import app.iduanju.core.cms.MacCMS
import org.json.JSONArray

/** 苹果 CMS 采集站 list (iOS CMSStore, key stv.cms.sites). Adult sites stay hidden unless the gate is unlocked. */
class CMSStore(ctx: Context) {
    private val sp = ctx.getSharedPreferences("idj", Context.MODE_PRIVATE)
    val sites = mutableStateListOf<CMSSite>()

    init {
        try { val a = JSONArray(sp.getString(KEY, "[]")); for (i in 0 until a.length()) sites.add(CMSSite.fromJSON(a.getJSONObject(i))) } catch (_: Exception) {}
    }

    private fun save() { sp.edit().putString(KEY, JSONArray(sites.map { it.toJSON() }).toString()).apply() }

    fun site(key: String): CMSSite? = sites.firstOrNull { it.key == key }
    val visibleSites: List<CMSSite> get() = sites.filter { it.enabled && (!it.adult || adultUnlocked) }
    private val adultState = androidx.compose.runtime.mutableStateOf(sp.getBoolean("gate.adult", false))
    /** Compose state so home / search / 频道 / 漫画 re-filter as soon as the gate changes in 我的. */
    var adultUnlocked: Boolean
        get() = adultState.value
        set(v) { adultState.value = v; sp.edit().putBoolean("gate.adult", v).apply() }

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private fun onMainSync(block: () -> Unit) {
        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) { block(); return }
        val latch = java.util.concurrent.CountDownLatch(1)
        var err: Throwable? = null
        mainHandler.post { try { block() } catch (t: Throwable) { err = t } finally { latch.countDown() } }
        latch.await()
        err?.let { throw it }
    }

    fun reloadFromPrefs() {
        onMainSync {
            sites.clear()
            try { val a = JSONArray(sp.getString(KEY, "[]")); for (i in 0 until a.length()) sites.add(CMSSite.fromJSON(a.getJSONObject(i))) } catch (_: Exception) {}
            adultState.value = sp.getBoolean("gate.adult", false)
        }
    }

    fun mergeSites(incoming: List<CMSSite>) {
        if (incoming.isEmpty()) return
        onMainSync {
            val existing = sites.map { it.key }.toHashSet()
            var changed = false
            for (s in incoming) {
                if (existing.add(s.key)) { sites.add(s); changed = true }
            }
            if (changed) save()
        }
    }

    /** Validates by fetching the class list (blocking; call off the main thread), then saves. */
    fun add(name: String, apiRaw: String, adult: Boolean, origin: String = "manual"): CMSSite {
        val api = MacCMS.normalize(apiRaw)
        val cats = MacCMS.fetchCategories(api)
        return saveValidated(name, api, adult, origin, cats)
    }

    fun saveValidated(name: String, api: String, adult: Boolean, origin: String, cats: List<CMSCategory>): CMSSite {
        val host = runCatching { java.net.URI(api).host }.getOrNull() ?: "采集站"
        var out: CMSSite? = null
        onMainSync {
            var s = CMSSite(CMSSite.key(api), name.ifBlank { host }, api, adult, true, cats, origin)
            val i = sites.indexOfFirst { it.key == s.key }
            if (i >= 0) { s = s.copy(enabled = sites[i].enabled); sites[i] = s } else sites.add(s)
            save()
            out = s
        }
        return out!!
    }
    fun remove(key: String) { onMainSync { sites.removeAll { it.key == key }; save() } }
    fun setEnabled(key: String, on: Boolean) { onMainSync { val i = sites.indexOfFirst { it.key == key }; if (i >= 0) { sites[i] = sites[i].copy(enabled = on); save() } } }
    fun cacheCategories(key: String, cats: List<CMSCategory>) {
        onMainSync {
            val i = sites.indexOfFirst { it.key == key }; if (i < 0 || sites[i].categories == cats) return@onMainSync
            sites[i] = sites[i].copy(categories = cats); save()
        }
    }

    companion object { const val KEY = "stv.cms.sites" }
}
