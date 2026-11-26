package app.iduanju.ui.home

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridItemSpanScope
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.VideoLibrary
import androidx.compose.material3.Icon
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.IdjApp
import app.iduanju.core.cms.CMSSite
import app.iduanju.core.cms.MacCMS
import app.iduanju.core.hongguo.HGSeries
import app.iduanju.ui.components.*
import app.iduanju.ui.theme.IdjThemeColors
import com.kyant.backdrop.Backdrop
import com.kyant.backdrop.backdrops.layerBackdrop
import com.kyant.backdrop.backdrops.rememberLayerBackdrop
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * In-memory feed cache so navigating into DetailScreen and pressing Back never re-fetches the site/plugin
 * from scratch or loses the selected category and scroll position. Pull-to-refresh clears and reloads.
 */
private object FeedGridCache {
    class Bucket(
        val items: MutableList<HGSeries> = mutableListOf(),
        var page: Int = 1,
        var hasMore: Boolean = true,
        var loaded: Boolean = false,
        var firstIndex: Int = 0,
        var firstOffset: Int = 0,
    )
    val categories = HashMap<String, List<Pair<String, String>>>()
    val selectedTab = HashMap<String, Int>()
    val buckets = HashMap<String, Bucket>()

    fun bucket(key: String, cat: String): Bucket = buckets.getOrPut("$key|$cat") { Bucket() }
}

/** iOS HomeFeedPage for `.site(cms)`. */
@Composable
fun SiteFeedPage(site: CMSSite, onOpen: (String) -> Unit) {
    LaunchedEffect(site.key) {
        if (site.categories.isEmpty()) {
            val categories = withContext(Dispatchers.IO) { runCatching { MacCMS.fetchCategories(site.api) }.getOrNull() }
            if (!categories.isNullOrEmpty()) IdjApp.instance.cms.cacheCategories(site.key, categories)
        }
    }
    val cats = remember(site.categories) { listOf("" to "最新") + site.categories.map { it.id to it.name } }
    FeedGrid("cms:" + site.key, cats, { cat, page ->
        val o = MacCMS.fetch(site.api, buildMap { put("ac", "detail"); put("pg", page.toString()); if (cat.isNotEmpty()) put("t", cat) })
        if (cat.isEmpty() && page == 1) MacCMS.parseCategories(o).takeIf { it.isNotEmpty() }?.let { IdjApp.instance.cms.cacheCategories(site.key, it) }
        MacCMS.page(o, site.key, page)
    }, onOpen)
}

/** iOS HomeFeedPage for `.site(plugin)` (JSVideoProvider): 推荐 + the categories `home()` returned. */
@Composable
fun PluginFeedPage(p: app.iduanju.plugin.PluginStore.Installed, onOpen: (String) -> Unit) {
    val cacheKey = "plugin:" + p.id
    var cats by remember(p.id) { mutableStateOf(FeedGridCache.categories[cacheKey] ?: listOf("" to "推荐")) }
    FeedGrid(cacheKey, cats, { cat, page ->
        val v = IdjApp.instance.plugins.video(p.id)
        try {
            val r = v.list(cat, page)
            if (cat.isEmpty()) v.categories.takeIf { it.isNotEmpty() }?.let { cs ->
                val list = listOf("" to "推荐") + cs.map { it.id to it.name }
                FeedGridCache.categories[cacheKey] = list
                cats = list
            }
            r
        } catch (e: app.iduanju.core.plugin.PluginException) { throw Exception(e.friendly) }
    }, onOpen)
}

/** 最新/推荐 + category chips, 3-column poster grid with in-memory cache, pull-to-refresh, and paging. */
@Composable
fun FeedGrid(key: String, cats: List<Pair<String, String>>, load: (String, Int) -> app.iduanju.core.hongguo.HGPage, onOpen: (String) -> Unit) {
    val c = IdjThemeColors
    val scope = rememberCoroutineScope()
    var sel by remember(key) { mutableIntStateOf((FeedGridCache.selectedTab[key] ?: 0).coerceIn(0, (cats.size - 1).coerceAtLeast(0))) }
    val activeCat = cats.getOrNull(sel)?.first ?: ""
    val bucket = remember(key, activeCat) { FeedGridCache.bucket(key, activeCat) }
    val items = remember(key, activeCat) { mutableStateListOf<HGSeries>().apply { addAll(bucket.items) } }
    var page by remember(key, activeCat) { mutableIntStateOf(bucket.page) }
    var hasMore by remember(key, activeCat) { mutableStateOf(bucket.hasMore) }
    var loading by remember(key, activeCat) { mutableStateOf(false) }
    var refreshing by remember(key, activeCat) { mutableStateOf(false) }
    var error by remember(key, activeCat) { mutableStateOf<String?>(null) }
    var verify by remember(key, activeCat) { mutableStateOf<app.iduanju.core.util.VerificationRequiredException?>(null) }
    // One scroll position per category; the chip row keeps its own across them.
    val grid = rememberSaveable(key, activeCat, saver = LazyGridState.Saver) { LazyGridState(bucket.firstIndex, bucket.firstOffset) }
    val chips = rememberLazyListState()
    ReportScrolled { grid.firstVisibleItemIndex > 0 || grid.firstVisibleItemScrollOffset > 12 }

    DisposableEffect(key, activeCat, grid) {
        onDispose {
            bucket.firstIndex = grid.firstVisibleItemIndex
            bucket.firstOffset = grid.firstVisibleItemScrollOffset
        }
    }

    suspend fun more(reset: Boolean = false) {
        if (loading) return
        if (!reset && !hasMore) return
        loading = true
        if (reset) refreshing = true
        try {
            val targetPage = if (reset) 1 else page
            val p = withContext(Dispatchers.IO) { load(activeCat, targetPage) }
            if (reset) {
                items.clear()
                bucket.items.clear()
            }
            val seen = items.map { it.seriesId }.toHashSet()
            val fresh = p.items.filter { seen.add(it.seriesId) }
            items.addAll(fresh)
            bucket.items.addAll(fresh)
            hasMore = p.hasMore
            page = targetPage + 1
            bucket.hasMore = hasMore
            bucket.page = page
            bucket.loaded = true
            error = null
            verify = null
        } catch (e: CancellationException) { throw e }
        catch (e: app.iduanju.core.util.VerificationRequiredException) { verify = e; error = "需要验证" }
        catch (e: Exception) { error = e.message ?: "加载失败" }
        finally {
            loading = false
            refreshing = false
        }
    }
    LaunchedEffect(key, activeCat) {
        if (!bucket.loaded && items.isEmpty()) more()
    }
    val nearEnd by remember(grid) { derivedStateOf { (grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) >= grid.layoutInfo.totalItemsCount - 6 } }
    LaunchedEffect(nearEnd, items.size) { if (nearEnd && items.isNotEmpty()) more() }

    val cols = LocalLayoutMetrics.current.posterCols
    val full: LazyGridItemSpanScope.() -> GridItemSpan = { GridItemSpan(maxLineSpan) }
    val pageColor = c.bg
    val gridBackdrop = rememberLayerBackdrop {
        drawRect(pageColor)
        drawContent()
    }
    Box(Modifier.fillMaxSize()) {
        GlassPullToRefresh(
            isRefreshing = refreshing,
            onRefresh = { scope.launch { more(reset = true) } },
            modifier = Modifier.fillMaxSize().layerBackdrop(gridBackdrop),
        ) {
            LazyVerticalGrid(GridCells.Fixed(cols), state = grid, modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = rootBottomInset() + 56.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                if (cats.size > 1) item("chips", full, "chips") {
                    CategoryChips(cats, sel, chips) { i ->
                        sel = i
                        FeedGridCache.selectedTab[key] = i
                    }
                }
                items(items, key = { it.seriesId }, contentType = { "poster" }) { HomePosterCard(it, onOpen) }
                if (items.isEmpty()) {
                    val v = verify
                    when {
                        v != null -> item("state", full, "state") { app.iduanju.huangguo.VerifyRequiredState(v) { scope.launch { more() } } }
                        error != null -> item("state", full, "state") { ErrorState("加载失败", note = error) { scope.launch { more() } } }
                        loading || !bucket.loaded -> items(cols * 3, key = { "skeleton$it" }, contentType = { "skeleton" }) { PosterSkeleton() }
                        else -> item("state", full, "state") {
                            EmptyState("该分类暂无内容", note = "部分采集站的父分类不直接提供资源，请选择动作片、国产剧等具体分类。", icon = Icons.Rounded.VideoLibrary)
                        }
                    }
                } else item("footer", full, "footer") {
                    Box(Modifier.fillMaxWidth().padding(12.dp), contentAlignment = Alignment.Center) {
                        val v = verify
                        when {
                            loading && !refreshing -> GlassSpinner(size = 24.dp)
                            v != null -> app.iduanju.huangguo.VerifyRequiredState(v) { scope.launch { more() } }
                            error != null -> GlassTextButton(error!! + " · 点击重试", color = c.secondary, fontSize = 13.sp) { scope.launch { more() } }
                        }
                    }
                }
            }
        }
        RefreshDisc(refreshing, !loading, gridBackdrop, Modifier.align(Alignment.BottomEnd).padding(end = 18.dp, bottom = rootBottomInset() + 12.dp)) {
            scope.launch {
                grid.animateScrollToItem(0)
                more(reset = true)
            }
        }
    }
}

/** Module chips of a site / plugin; the selected one is scrolled into view. */
@Composable
private fun CategoryChips(cats: List<Pair<String, String>>, selected: Int, state: LazyListState, onSelect: (Int) -> Unit) {
    LaunchedEffect(selected) {
        val visible = state.layoutInfo.visibleItemsInfo
        if (visible.isEmpty() || selected <= visible.first().index || selected >= visible.last().index) state.animateScrollToItem((selected - 1).coerceAtLeast(0))
    }
    LazyRow(state = state, horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(vertical = 4.dp)) {
        itemsIndexed(cats, contentType = { _, _ -> "chip" }) { i, (_, name) -> OptionChip(name, i == selected, minHeight = 34.dp) { onSelect(i) } }
    }
}

/** Floating 刷新 disc (iOS `home.dynamic.refresh`), glass over the feed. */
@Composable
private fun RefreshDisc(refreshing: Boolean, enabled: Boolean, backdrop: Backdrop, modifier: Modifier, onClick: () -> Unit) {
    Box(
        modifier.size(46.dp).glassSurface(CircleShape, backdrop = backdrop, shadowRadius = 10.dp)
            .pressClick(0.92f, enabled, "刷新列表", onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (refreshing) GlassSpinner(size = 20.dp, stroke = 2.dp)
        else Icon(Icons.Rounded.Refresh, null, Modifier.size(20.dp), tint = IdjThemeColors.text)
    }
}
