package app.iduanju.tvbox

import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.iduanju.IdjApp
import app.iduanju.core.tvbox.EpgService
import app.iduanju.core.tvbox.LiveChannel
import app.iduanju.core.tvbox.LiveData
import app.iduanju.core.tvbox.LiveGroup
import app.iduanju.core.tvbox.Programme
import app.iduanju.core.tvbox.SiteRef
import app.iduanju.core.tvbox.SpiderErrors
import app.iduanju.core.tvbox.VodFilter
import app.iduanju.core.tvbox.VodHome
import app.iduanju.core.tvbox.VodItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val engine get() = IdjApp.instance.tvbox.engine
internal fun errorText(e: Throwable) = SpiderErrors.text(e).ifEmpty { "加载失败" }

/** One paged list of cards (recommendations, a category, a folder). */
class VodListState(private val scope: CoroutineScope, private val uid: String, val tid: String, private val extend: Map<String, String>) {
    val items = mutableStateListOf<VodItem>()
    val grid = LazyGridState()
    var page by mutableIntStateOf(0)
        private set
    var hasMore by mutableStateOf(true)
        private set
    var loading by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    private var job: Job? = null
    /** The job on screen; a cancelled one ends after its successor has begun. */
    private var run = 0
    private var loadingPage = 0
    /** The first page was given up before it was up to date. */
    private var unfinished = false
    private val seen = HashSet<String>()

    private fun merge(list: List<VodItem>, reset: Boolean): Boolean {
        if (reset) { if (items.size >= list.size && items.take(list.size) == list && page <= 1) return true; items.clear(); seen.clear() }
        val fresh = list.filter { seen.add(it.id + "|" + it.title) }
        items.addAll(fresh)
        return fresh.isNotEmpty()
    }

    /** First page (cached copy first) or the next one; a page that adds nothing ends the list. */
    fun load(refresh: Boolean = false) {
        if (loading || (!refresh && !hasMore)) return
        start(if (refresh) 1 else page + 1, refresh)
    }

    private fun start(target: Int, force: Boolean) {
        val mine = ++run
        loading = true
        loadingPage = target
        error = null
        unfinished = false
        job = scope.launch {
            try {
                engine.category(uid, tid, target, extend, force).collect { s ->
                    val added = merge(s.value.items, reset = target == 1)
                    page = target
                    hasMore = s.value.hasMore && (added || target == 1) && s.value.items.isNotEmpty()
                    if (s.error != null) error = s.error
                }
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error = errorText(e) } finally { if (mine == run) loading = false }
        }
    }

    fun ensure() { if (!loading && (unfinished || page == 0 && items.isEmpty())) start(1, false) }

    /** Left for another list: a script or jar site answers one request at a time, the next one must not wait for this. */
    fun leave() {
        if (!loading) return
        run++
        loading = false
        if (loadingPage == 1) unfinished = true
        job?.cancel()
    }
}

/** Everything shown for one site; kept while the hub is on the back stack. */
class SitePane(private val scope: CoroutineScope, val uid: String) {
    var home by mutableStateOf<VodHome?>(null)
        private set
    var loading by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    val homeGrid = LazyGridState()
    /** "" = 推荐. */
    var category by mutableStateOf("")
    private val picks = mutableStateMapOf<String, Map<String, String>>()
    private val lists = HashMap<String, VodListState>()
    /** Open `vod_tag=folder` entries, innermost last. */
    val folders = mutableStateListOf<VodItem>()
    private var job: Job? = null
    private var run = 0
    private var shown: VodListState? = null

    /** The list on screen (null = 推荐); the one before stops loading. */
    fun show(list: VodListState?) { if (shown !== list) { shown?.leave(); shown = list } }

    fun load(force: Boolean = false) {
        if (loading && !force) return
        job?.cancel()
        val mine = ++run
        loading = true
        error = null
        job = scope.launch {
            try {
                engine.home(uid, force).collect { s ->
                    home = s.value
                    if (s.error != null) error = s.error
                    // a site without recommendations opens on its first category
                    if (category.isEmpty() && s.value.items.isEmpty() && s.fresh) s.value.categories.firstOrNull()?.let { category = it.id }
                }
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error = errorText(e) } finally { if (mine == run) loading = false }
        }
    }

    fun ensure() { if (home == null && !loading) load() }

    fun filters(tid: String): List<VodFilter> = home?.filters?.get(tid).orEmpty()
    fun picked(tid: String): Map<String, String> = picks[tid] ?: filters(tid).filter { it.initial.isNotEmpty() }.associate { it.key to it.initial }
    fun pick(tid: String, key: String, value: String) { picks[tid] = picked(tid).let { if (value.isEmpty()) it - key else it + (key to value) } }
    fun resetFilters(tid: String) { picks.remove(tid) }

    fun list(tid: String, extend: Map<String, String> = emptyMap()): VodListState = lists.getOrPut(tid + "|" + extend.toSortedMap()) {
        if (lists.size > 24) lists.clear()
        VodListState(scope, uid, tid, extend)
    }

    fun refresh() {
        val f = folders.lastOrNull()
        if (f != null) list(f.id).load(true) else if (category.isEmpty()) load(true) else list(category, picked(category)).load(true)
    }
}

/** Search in one site (paged) or in all of them (streaming). */
class SearchPane(private val scope: CoroutineScope) {
    var query by mutableStateOf("")
    var submitted by mutableStateOf("")
        private set
    var all by mutableStateOf(false)
    val items = mutableStateListOf<VodItem>()
    val grid = LazyGridState()
    /** uid → (site name, hits) in arrival order. */
    val sites = mutableStateMapOf<String, Pair<String, Int>>()
    var only by mutableStateOf("")
    var done by mutableIntStateOf(0)
        private set
    var total by mutableIntStateOf(0)
        private set
    var failed by mutableIntStateOf(0)
        private set
    var loading by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    private var hasMore = false
    private var page = 0
    private var job: Job? = null
    private var run = 0
    private val seen = HashSet<String>()

    val active get() = submitted.isNotEmpty()

    fun clear() { job?.cancel(); query = ""; submitted = ""; reset() }

    private fun reset() { items.clear(); sites.clear(); seen.clear(); only = ""; done = 0; total = 0; failed = 0; page = 0; hasMore = false; error = null; loading = false }

    fun submit(current: String, searchable: List<TVBoxSiteRef>) {
        val q = query.trim()
        job?.cancel()
        reset()
        submitted = q
        if (q.isEmpty()) return
        if (!all) { more(current); return }
        val mine = ++run
        loading = true
        val uids = searchable.map { it.uid }
        total = uids.size
        job = scope.launch {
            try {
                engine.searchAll(uids, q).collect { hit ->
                    done++
                    if (hit.error != null) failed++
                    val fresh = hit.items.filter { seen.add(it.sid) }
                    if (fresh.isNotEmpty()) { sites[hit.ref.uid] = hit.ref.site.name to fresh.size; items.addAll(rank(fresh, q)) }
                }
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error = errorText(e) } finally { if (mine == run) loading = false }
        }
    }

    /** Exact and prefix matches of a site first. */
    private fun rank(list: List<VodItem>, q: String) = list.sortedBy { if (it.title == q) 0 else if (it.title.startsWith(q)) 1 else if (it.title.contains(q)) 2 else 3 }

    fun more(uid: String) {
        if (all || (page > 0 && (!hasMore || loading))) return
        val mine = ++run
        loading = true
        error = null
        val next = page + 1
        job = scope.launch {
            try {
                val r = engine.search(uid, submitted, next)
                val fresh = r.items.filter { seen.add(it.sid) }
                items.addAll(fresh)
                page = next
                hasMore = r.hasMore && fresh.isNotEmpty()
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error = errorText(e) } finally { if (mine == run) loading = false }
        }
    }
}

class LiveRow(val group: LiveGroup, val channel: LiveChannel, /** Episode number of the channel in the player's list; 0 = locked. */ val number: Int) { val key = group.name + "\u0000" + channel.name }

/** 当前节目 of a row and when it has to be looked up again. */
class NowLine(val text: String, val until: Long)

/** One live source: groups, rows and the current programme per channel. */
class LivePane(private val scope: CoroutineScope, val uid: String) {
    var data by mutableStateOf<LiveData?>(null)
        private set
    var rows by mutableStateOf<List<LiveRow>>(emptyList())
        private set
    var loading by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var group by mutableStateOf(ALL)
    val now = mutableStateMapOf<String, NowLine>()
    val list = androidx.compose.foundation.lazy.LazyListState()
    private var job: Job? = null
    private var run = 0

    fun load(force: Boolean = false) {
        if (loading && !force) return
        job?.cancel()
        val mine = ++run
        loading = true
        error = null
        job = scope.launch {
            try {
                engine.liveChannels(uid, force).collect { s -> show(s.value); if (s.error != null) error = s.error }
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error = errorText(e) } finally { if (mine == run) loading = false }
        }
    }

    fun ensure() { if (data == null && !loading) load() }

    /** Recomputed when the list changes or a group is unlocked. */
    suspend fun show(d: LiveData? = data) {
        d ?: return
        val open = IdjApp.instance.tvbox.unlocked(uid)
        val r = withContext(Dispatchers.Default) {
            var n = 0
            d.list.groups.flatMap { g -> val locked = g.pass.isNotEmpty() && g.name !in open; g.channels.map { LiveRow(g, it, if (locked) 0 else ++n) } }
        }
        data = d
        rows = r
        if (group != ALL && group != FAVORITES && d.list.groups.none { it.name == group }) group = ALL
    }

    fun locked(g: LiveGroup) = g.pass.isNotEmpty() && g.name !in IdjApp.instance.tvbox.unlocked(uid)

    /** 当前节目, looked up when a row has stayed on screen for a moment and again when the programme is over. */
    suspend fun nowPlaying(row: LiveRow) {
        while (true) {
            now[row.key]?.let { delay((it.until - System.currentTimeMillis()).coerceAtLeast(0)) }
            delay(250)
            val list: List<Programme> = try { engine.guide(uid, row.channel.name, row.channel.tvgId, row.channel.tvgName) } catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }
            val t = System.currentTimeMillis()
            val (cur, next) = EpgService.nowNext(list, t)
            val until = (cur?.end ?: next?.start ?: Long.MAX_VALUE).coerceIn(t + 60_000, t + 15 * 60_000)
            now[row.key] = NowLine(when { cur != null -> "正在播出：${cur.title}"; next != null -> "稍后：${next.title}"; else -> "" }, until)
        }
    }

    companion object {
        /** Not names a list could use for a group of its own. */
        const val ALL = "\u0000全部"
        const val FAVORITES = "\u0000收藏"
        fun label(group: String) = group.removePrefix("\u0000")
    }
}

/** Hub state that outlives a trip to the detail page or the player. */
class TVBoxHubModel : ViewModel() {
    var mode by mutableIntStateOf(0)
    private val sites = LinkedHashMap<String, SitePane>()
    private val lives = LinkedHashMap<String, LivePane>()
    val search = SearchPane(viewModelScope)
    private var stamp = ""

    /** Panes belong to one state of one config: a switch, refresh or trust change starts over. */
    fun sync(repo: TVBoxRepo?) {
        val s = repo?.let { it.id + it.record.updatedAt + it.record.trust }.orEmpty()
        if (s == stamp) return
        stamp = s
        sites.clear()
        lives.clear()
        search.clear()
    }

    fun site(uid: String): SitePane = sites.getOrPut(uid) { if (sites.size >= 8) sites.remove(sites.keys.first()); SitePane(viewModelScope, uid) }
    fun live(uid: String): LivePane = lives.getOrPut(uid) { if (lives.size >= 6) lives.remove(lives.keys.first()); LivePane(viewModelScope, uid) }

    var message by mutableStateOf<String?>(null)
    var busy by mutableStateOf(false)
        private set

    /** Cards that carry an `action` are handled by the spider itself. */
    fun action(item: VodItem) {
        if (busy) return
        busy = true
        viewModelScope.launch {
            message = try {
                val text = engine.action(item.uid, item.action)
                app.iduanju.core.tvbox.LenientJson.objectOrNull(text)?.let { o -> listOf("msg", "toast", "message").firstNotNullOfOrNull { k -> o.optString(k).takeIf { it.isNotEmpty() && it != "null" } } } ?: if (text.isBlank() || text.startsWith("{")) "已执行" else text.take(200)
            } catch (e: CancellationException) { throw e } catch (e: Exception) { errorText(e) } finally { busy = false }
        }
    }

    fun ref(uid: String): SiteRef? = engine.site(uid)
}
