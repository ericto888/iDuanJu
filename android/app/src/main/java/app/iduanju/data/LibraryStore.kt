package app.iduanju.data

import android.content.Context
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/** Watch progress (iOS WatchProgress) — local only, SharedPreferences JSON. */
data class WatchProgress(
    val seriesId: String, val title: String, val cover: String,
    val episodeIndex: Int, val episodeNumber: Int, val seconds: Double, val duration: Double, val updatedAt: Long,
    /** Channel name and group of a live list; empty for dramas. */
    val episodeTitle: String = "", val episodeGroup: String = "",
) {
    val fraction: Float get() = if (duration > 0) (seconds / duration).toFloat().coerceIn(0f, 1f) else 0f
    val isLive: Boolean get() = seriesId.startsWith("tvl:")
    val resumeLabel: String get() = when {
        isLive && episodeTitle.isNotEmpty() -> "直播 · $episodeTitle"
        isLive -> "直播"
        else -> "看到第${episodeNumber}集"
    }
}

/** iOS LibraryStore: history (continue watching) + favourites + per-series playback choices. Main thread only. */
class LibraryStore(ctx: Context) {
    private val sp = ctx.getSharedPreferences("library", Context.MODE_PRIVATE)
    // Progress is recorded every few seconds while playing: serialising up to 200 entries must not cost a frame.
    private val io = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(1))
    private var pendingSave: Job? = null

    val history = mutableStateListOf<WatchProgress>()
    val favorites = mutableStateMapOf<String, Triple<String, String, Long>>()
    val searchHistory = mutableStateListOf<String>()
    private val lineChoice = LinkedHashMap<String, String>()
    private val qualityChoice = LinkedHashMap<String, String>()

    private val peekCache = java.util.concurrent.ConcurrentHashMap<String, Pair<String, String>>()

    init {
        loadFromPrefsLocked()
    }

    private fun loadFromPrefsLocked() {
        history.clear()
        favorites.clear()
        lineChoice.clear()
        qualityChoice.clear()
        searchHistory.clear()
        peekCache.clear()
        runCatching {
            val a = JSONArray(sp.getString("history", "[]"))
            for (i in 0 until a.length()) a.getJSONObject(i).let {
                val wp = WatchProgress(it.getString("sid"), it.optString("title"), it.optString("cover"), it.optInt("idx"),
                    it.optInt("ep", 1), it.optDouble("sec", 0.0), it.optDouble("dur", 0.0), it.optLong("at"), it.optString("epTitle"), it.optString("epGroup"))
                history.add(wp)
                updatePeek(wp.seriesId, wp.title, wp.cover)
            }
            val f = JSONObject(sp.getString("fav", "{}"))
            f.keys().forEach { k ->
                f.getJSONObject(k).let {
                    val t = it.optString("title"); val c = it.optString("cover")
                    favorites[k] = Triple(t, c, it.optLong("at"))
                    updatePeek(k, t, c)
                }
            }
        }
        runCatching { readMap("lineChoice", lineChoice) }
        runCatching { readMap("qualityChoice", qualityChoice) }
        runCatching { val a = JSONArray(sp.getString("search", "[]")); for (i in 0 until a.length()) searchHistory.add(a.getString(i)) }
    }

    private fun updatePeek(sid: String, title: String, cover: String) {
        if (sid.isEmpty()) return
        val prev = peekCache[sid]
        val t = title.ifEmpty { prev?.first.orEmpty() }
        val c = cover.ifEmpty { prev?.second.orEmpty() }
        if (t.isNotEmpty() || c.isNotEmpty()) peekCache[sid] = t to c
    }

    /** Thread-safe cover/title peek (safe to call from Dispatchers.IO without touching Compose snapshot state). */
    fun peekTitleSafe(sid: String): String = peekCache[sid]?.first.orEmpty()
    fun peekCoverSafe(sid: String): String = peekCache[sid]?.second.orEmpty()

    fun addSearch(q: String) { searchHistory.remove(q); searchHistory.add(0, q); while (searchHistory.size > 20) searchHistory.removeAt(20); saveSearch() }
    fun removeSearch(q: String) { searchHistory.remove(q); saveSearch() }
    fun clearSearch() { searchHistory.clear(); saveSearch() }
    private fun saveSearch() { sp.edit().putString("search", JSONArray(searchHistory.toList()).toString()).apply() }

    val continueWatching: List<WatchProgress> get() = history.sortedByDescending { it.updatedAt }
    fun progress(sid: String): WatchProgress? = history.firstOrNull { it.seriesId == sid }

    fun record(p: WatchProgress) {
        history.removeAll { it.seriesId == p.seriesId }
        history.add(0, p)
        while (history.size > 200) history.removeAt(history.size - 1)
        updatePeek(p.seriesId, p.title, p.cover)
        save()
    }
    fun clearHistory() { history.clear(); save() }
    fun removeProgress(sid: String) { history.removeAll { it.seriesId == sid }; save() }
    fun isFavorite(sid: String) = favorites.containsKey(sid)
    fun toggleFavorite(sid: String, title: String, cover: String) {
        if (favorites.remove(sid) == null) {
            favorites[sid] = Triple(title, cover, System.currentTimeMillis())
            updatePeek(sid, title, cover)
        }
        save()
    }
    fun removeFavorite(sid: String) {
        if (favorites.remove(sid) != null) save()
    }
    fun removeFavorites(sids: Collection<String>) {
        if (sids.isEmpty()) return
        var changed = false
        for (sid in sids) if (favorites.remove(sid) != null) changed = true
        if (changed) save()
    }
    fun clearFavorites() {
        if (favorites.isEmpty()) return
        favorites.clear()
        save()
    }

    /** Flush pending debounced writes synchronously before creating a backup or WebDAV sync. */
    fun flush() {
        pendingSave?.cancel()
        writeSnapshotSync(history.toList(), favorites.toMap())
        sp.edit().putString("search", JSONArray(searchHistory.toList()).toString()).commit()
    }

    /** Reload all library state from SharedPreferences on Main thread after backup restore. */
    fun reloadFromPrefs() {
        pendingSave?.cancel()
        loadFromPrefsLocked()
    }

    /** Smart-merge incoming progress, favorites, and search history on Main thread. */
    fun mergePortable(
        incomingProgress: List<WatchProgress>,
        incomingFavorites: List<Triple<String, Pair<String, String>, Long>>,
        incomingSearch: List<String>,
    ) {
        val bySid = LinkedHashMap<String, WatchProgress>()
        for (p in history) bySid[p.seriesId] = p
        for (inc in incomingProgress) {
            val cur = bySid[inc.seriesId]
            if (cur == null || inc.updatedAt >= cur.updatedAt) bySid[inc.seriesId] = inc
        }
        val mergedHistory = bySid.values.sortedByDescending { it.updatedAt }.take(200)
        history.clear()
        history.addAll(mergedHistory)
        for (p in mergedHistory) updatePeek(p.seriesId, p.title, p.cover)

        for ((sid, pair, at) in incomingFavorites) {
            val cur = favorites[sid]
            if (cur == null || at > cur.third) {
                favorites[sid] = Triple(pair.first, pair.second, at)
                updatePeek(sid, pair.first, pair.second)
            }
        }
        if (incomingSearch.isNotEmpty()) {
            val merged = (searchHistory.toList() + incomingSearch).distinct().take(20)
            searchHistory.clear()
            searchHistory.addAll(merged)
            saveSearch()
        }
        flush()
    }

    // ── per-series playback choices ─────────────────────────────────────────────────────────────────────

    /** 线路 chosen by hand for this title (`HGPlayLine.id`). */
    fun preferredLine(sid: String): String? = lineChoice[sid]
    fun setPreferredLine(sid: String, lineId: String?) = choose("lineChoice", lineChoice, sid, lineId)
    /** 画质 label chosen by hand for this title. */
    fun preferredQuality(sid: String): String? = qualityChoice[sid]
    fun setPreferredQuality(sid: String, quality: String?) = choose("qualityChoice", qualityChoice, sid, quality)

    private fun choose(key: String, map: LinkedHashMap<String, String>, sid: String, value: String?) {
        map.remove(sid)
        if (!value.isNullOrEmpty()) map[sid] = value
        while (map.size > 300) map.remove(map.keys.first())
        sp.edit().putString(key, JSONObject(map as Map<*, *>).toString()).apply()
    }
    private fun readMap(key: String, into: MutableMap<String, String>) {
        val o = JSONObject(sp.getString(key, "{}") ?: "{}")
        o.keys().forEach { into[it] = o.optString(it) }
    }

    private fun writeSnapshotSync(h: List<WatchProgress>, fav: Map<String, Triple<String, String, Long>>) {
        val a = JSONArray()
        h.forEach { a.put(JSONObject().put("sid", it.seriesId).put("title", it.title).put("cover", it.cover).put("idx", it.episodeIndex)
            .put("ep", it.episodeNumber).put("sec", it.seconds).put("dur", it.duration).put("at", it.updatedAt).put("epTitle", it.episodeTitle).put("epGroup", it.episodeGroup)) }
        val f = JSONObject()
        fav.forEach { (k, v) -> f.put(k, JSONObject().put("title", v.first).put("cover", v.second).put("at", v.third)) }
        sp.edit().putString("history", a.toString()).putString("fav", f.toString()).commit()
    }

    private fun save() {
        val h = history.toList()
        val fav = favorites.toMap()
        pendingSave?.cancel()
        pendingSave = io.launch {
            delay(120)
            writeSnapshotSync(h, fav)
        }
    }
}
