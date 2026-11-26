package app.iduanju.ui.category

import androidx.compose.foundation.background
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.FilterList
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.ui.graphics.graphicsLayer
import app.iduanju.core.hongguo.HGFilterOption
import app.iduanju.core.hongguo.HGFilterRow
import app.iduanju.ui.components.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridItemSpanScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.IdjApp
import app.iduanju.core.hongguo.HGPanel
import app.iduanju.core.hongguo.HGRankGenre
import app.iduanju.core.hongguo.HGRankSub
import app.iduanju.core.hongguo.HGSeries
import app.iduanju.ui.home.HomeFmt
import app.iduanju.ui.home.rootBottomInset
import app.iduanju.ui.theme.IdjThemeColors
import coil.compose.AsyncImage
import com.kyant.backdrop.Backdrop
import com.kyant.backdrop.backdrops.layerBackdrop
import com.kyant.backdrop.backdrops.rememberLayerBackdrop
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.lifecycle.viewModelScope

/** ui-redesign 01–03 (iOS CategoryView twin): 榜单 = segmented 剧种 + chips + top-3 posters + ranked rows;
 *  筛选找片 = card panel that collapses into a sticky glass strip. */
@Composable
fun CategoryScreen(onOpenDetail: (String) -> Unit, onSearch: (() -> Unit)? = null) {
    val c = IdjThemeColors
    // State lives in a ViewModel scoped to the 找剧 back-stack entry: opening a drama and coming back keeps the
    // list, filters, paging cursor and scroll position, and in-flight loads are not cancelled by leaving.
    val vm: CategoryState = androidx.lifecycle.viewmodel.compose.viewModel()
    val scope = vm.scope
    var filterMode by vm.filterMode
    var genre by vm.genre
    var sub by vm.sub
    var panel by vm.panel
    var panelErr by vm.panelErr
    val selected = vm.selected
    val names = vm.names
    val items = vm.items
    var nextOffset by vm.nextOffset
    var session by vm.session
    var hasMore by vm.hasMore
    var loading by vm.loading
    var err by vm.err
    var gen by vm.gen
    var panelGen by vm.panelGen

    fun load(reset: Boolean) {
        if (loading && !reset) return
        if (reset) { items.clear(); nextOffset = 0; session = null; hasMore = false; gen++ }
        val myGen = gen
        val isFilter = filterMode
        val selectedIds = selected.values.filter { it.isNotEmpty() }.sorted()
        val seenIds = items.map { it.seriesId }
        val requestOffset = nextOffset
        val requestSession = session
        val requestGenre = genre
        val requestSub = sub
        loading = true; err = null
        scope.launch {
            try {
                val p = withContext(Dispatchers.IO) {
                    if (!isFilter) IdjApp.instance.hongguo.rank(requestSub, requestGenre, requestOffset, seenIds)
                    else IdjApp.instance.hongguo.category(selectedIds, requestOffset, requestSession, seenIds)
                }
                if (myGen != gen) return@launch
                val seen = items.mapTo(HashSet()) { it.seriesId }
                items.addAll(p.items.filter { seen.add(it.seriesId) })
                nextOffset = p.nextOffset ?: (nextOffset + p.items.size); session = p.sessionId; hasMore = p.hasMore && p.items.isNotEmpty()
            } catch (e: Exception) { if (myGen == gen) err = e.message ?: "加载失败" }
            if (myGen == gen) loading = false
        }
    }
    suspend fun loadPanel() {
        val selectedGenre = selected["genre"] ?: ""
        val token = ++panelGen
        panelErr = null
        try {
            val fresh = withContext(Dispatchers.IO) { IdjApp.instance.hongguo.panel(selectedGenre) }
            if (token == panelGen && selectedGenre == (selected["genre"] ?: "")) panel = fresh
        } catch (e: kotlinx.coroutines.CancellationException) { throw e }
        catch (e: Exception) { if (token == panelGen) panelErr = e.message }
    }
    LaunchedEffect(filterMode, genre, sub) {
        val key = "$filterMode/$genre/$sub"
        // Returning from detail re-enters composition with the same key: keep the cached list, no refetch.
        if (vm.loadedKey == key && (items.isNotEmpty() || loading)) { android.util.Log.i("IDJ", "category cache hit $key items=${items.size}"); return@LaunchedEffect }
        if (filterMode && panel == null) loadPanel()
        if (!genre.subs.contains(sub)) sub = genre.subs[0]
        if (!filterMode || panel != null) { vm.loadedKey = "$filterMode/$genre/$sub"; android.util.Log.i("IDJ", "category load ${vm.loadedKey}"); load(true) }
    }
    val grid = vm.grid
    LaunchedEffect(Unit) { if(app.iduanju.BuildConfig.DEBUG && app.iduanju.ui.UiEvidence.scroll) { kotlinx.coroutines.delay(2500); grid.scrollToItem(3) } }
    LaunchedEffect(grid) {
        snapshotFlow { grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }.collect { last ->
            if (hasMore && !loading && last >= grid.layoutInfo.totalItemsCount - 4) load(false)
        }
    }
    val scrolled by remember { derivedStateOf { grid.firstVisibleItemIndex > 0 || grid.firstVisibleItemScrollOffset > 6 } }
    // The filter card is item 1; once it has scrolled off, the sticky strip takes its place.
    val collapsed by remember { derivedStateOf { filterMode && panel != null && grid.firstVisibleItemIndex >= 2 } }

    fun selectOption(row: HGFilterRow, value: String) {
        if (row.type == "genre") {
            selected.clear(); names.clear(); if (value.isNotEmpty()) { selected["genre"] = value; names["genre"] = row.items.firstOrNull { it.id == value }?.name ?: "" }
            gen++; items.clear(); hasMore = false; panel = null
            scope.launch { loadPanel(); if (panel != null) load(true) }
        } else {
            if (value.isEmpty()) { selected.remove(row.type); names.remove(row.type) }
            else { selected[row.type] = value; names[row.type] = row.items.firstOrNull { it.id == value }?.name ?: "" }
            load(true)
        }
    }
    fun resetAll() { selected.clear(); names.clear(); gen++; items.clear(); panel = null; scope.launch { loadPanel(); if (panel != null) load(true) } }
    val picks by remember { derivedStateOf {
        panel?.rows?.mapNotNull { r -> selected[r.type]?.takeIf { it.isNotEmpty() }?.let { id -> r.type to (r.items.firstOrNull { it.id == id }?.name ?: names[r.type] ?: "") } }?.filter { it.second.isNotEmpty() } ?: emptyList()
    } }
    val cols = LocalLayoutMetrics.current.posterCols
    val full: LazyGridItemSpanScope.() -> GridItemSpan = { GridItemSpan(maxLineSpan) }
    // Sampled by the sticky strip only, so the grid is recorded just while that strip can appear.
    val pageColor = c.bg
    val gridBackdrop = rememberLayerBackdrop {
        drawRect(pageColor)
        drawContent()
    }

    DSPage(glow = !scrolled) {
        LazyVerticalGrid(GridCells.Fixed(cols), Modifier.fillMaxSize().statusBarsPadding().then(if (filterMode) Modifier.layerBackdrop(gridBackdrop) else Modifier), state = grid,
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = rootBottomInset() + 12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(0.dp)) {
            item("tabs", full, "tabs") {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    UnderlineTabs(listOf(false, true), filterMode, { if (it) "筛选找片" else "榜单" }, onSelect = { if (it != filterMode) filterMode = it },
                        modifier = Modifier.padding(start = 4.dp).weight(1f))
                    if (onSearch != null) RoundIconButton(Icons.Rounded.Search, "搜索", size = 40.dp, onClick = onSearch)
                }
            }
            val count = items.size
            if (!filterMode) {
                item("rankhead", full, "rankhead") {
                    Column {
                        SegmentedTabs(HGRankGenre.entries, genre, { it.label }, { genre = it }, Modifier.padding(top = 22.dp))
                        ChipRow(genre.subs, sub, { it.label }, { sub = it }, start = 0.dp, modifier = Modifier.padding(top = 12.dp))
                        Spacer(Modifier.height(18.dp))
                    }
                }
                items(minOf(count, 3), key = { "top" + items[it].seriesId }, contentType = { "poster" }) { i -> PosterCell(items[i], i + 1, onOpen = onOpenDetail) }
                items((count - 3).coerceAtLeast(0), key = { items[it + 3].seriesId }, span = { full() }, contentType = { "rank" }) { i ->
                    Column(Modifier.padding(top = if (i == 0) 12.dp else 0.dp)) {
                        if (i > 0) Hairline()
                        RankRow(items[i + 3], i + 4, onOpenDetail)
                    }
                }
                if (count == 0 && err == null && (loading || vm.loadedKey == null)) {
                    items(cols, key = { "skeleton$it" }, contentType = { "skeleton" }) { PosterSkeleton(Modifier.padding(bottom = 12.dp)) }
                    items(5, key = { "rowSkeleton$it" }, span = { full() }, contentType = { "rowSkeleton" }) { RowSkeleton(thumb = 62.dp) }
                }
            } else {
                item("panel", full, "panel") {
                    Box(Modifier.padding(top = 22.dp, bottom = 16.dp)) {
                        val p = panel
                        when {
                            p != null -> FilterPanel(p, selected, picks, ::selectOption, onRemove = { t -> p.rows.firstOrNull { it.type == t }?.let { selectOption(it, "") } }, onReset = ::resetAll)
                            panelErr != null -> ErrorState("加载失败", note = panelErr) { scope.launch { loadPanel(); if (panel != null) load(true) } }
                            else -> SkeletonBlock(Modifier.fillMaxWidth().height(230.dp), 20.dp)
                        }
                    }
                }
                items(count, key = { items[it].seriesId }, contentType = { "poster" }) { i ->
                    val s = items[i]
                    PosterCell(s, null, s.tags.take(2).joinToString(" · ").ifEmpty { null }, onOpenDetail, Modifier.padding(bottom = 16.dp))
                }
                if (count == 0 && loading) items(cols * 2, key = { "skeleton$it" }, contentType = { "skeleton" }) { PosterSkeleton(Modifier.padding(bottom = 16.dp)) }
            }
            item("footer", full, "footer") {
                Box(Modifier.fillMaxWidth().padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
                    when {
                        err != null && items.isEmpty() -> ErrorState("加载失败", note = err) { load(true) }
                        loading -> if (items.isNotEmpty()) GlassSpinner(size = 24.dp)
                        err != null -> GlassTextButton("$err · 点击重试", color = c.secondary, fontSize = 13.sp) { load(false) }
                        !hasMore && items.isNotEmpty() -> Text("没有更多了", color = c.tertiary, fontSize = 12.sp)
                    }
                }
            }
        }
        // `.topfade`
        Box(Modifier.statusBarsPadding().fillMaxWidth().height(if (collapsed) 70.dp else 24.dp).graphicsLayer { alpha = if (scrolled) 1f else 0f }
            .background(remember(c.bg) { Brush.verticalGradient(0f to c.bg, 0.42f to c.bg, 1f to c.bg.copy(alpha = 0f)) }))
        AnimatedVisibility(collapsed, Modifier.statusBarsPadding().padding(horizontal = 12.dp).padding(top = 2.dp),
            enter = slideInVertically(DS.panel()) { -it } + fadeIn(Motion.fade()), exit = slideOutVertically(DS.panel()) { -it } + fadeOut(Motion.fade())) {
            StickyStrip(picks.map { it.second }, gridBackdrop) { scope.launch { grid.animateScrollToItem(0) } }
        }
    }
}

@Composable
private fun FilterPanel(p: HGPanel, selected: Map<String, String>, picks: List<Pair<String, String>>, onSelect: (HGFilterRow, String) -> Unit,
                        onRemove: (String) -> Unit, onReset: () -> Unit) {
    val c = IdjThemeColors
    Column(Modifier.fillMaxWidth().dsCard(20.dp).padding(start = 14.dp, top = 14.dp)) {
        p.rows.firstOrNull { it.type == "genre" }?.let { row ->
            val opts = listOf(HGFilterOption("", "全部")) + row.items
            SegmentedTabs(opts, opts.firstOrNull { it.id == (selected["genre"] ?: "") } ?: opts[0], { it.name }, { onSelect(row, it.id) },
                Modifier.padding(end = 14.dp, bottom = 8.dp))
        }
        p.rows.filter { it.type != "genre" }.forEach { row ->
            val opts = listOf(HGFilterOption("", "全部")) + row.items
            Row(Modifier.heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(row.name, color = c.tertiary, fontSize = 13.sp, maxLines = 1, modifier = Modifier.widthIn(min = 36.dp).padding(end = 6.dp))
                ChipRow(opts, opts.firstOrNull { it.id == (selected[row.type] ?: "") } ?: opts[0], { it.name }, { onSelect(row, it.id) },
                    neutral = { it.id.isEmpty() }, start = 0.dp)
            }
        }
        Hairline(Modifier.padding(top = 6.dp))
        Row(Modifier.heightIn(min = 48.dp).padding(end = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            Text("已选", color = c.tertiary, fontSize = 13.sp)
            Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                if (picks.isEmpty()) Text("全部剧集", color = c.tertiary, fontSize = 13.sp)
                picks.forEach { (t, name) ->
                    Row(Modifier.heightIn(min = 28.dp).clip(CircleShape).background(c.glass).testTag("filter.pick.$name").pressClick(label = "移除 $name") { onRemove(t) }
                        .padding(start = 9.dp, end = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(name, color = c.text, fontSize = 12.sp)
                        Icon(Icons.Rounded.Close, null, Modifier.size(10.dp), tint = c.tertiary)
                    }
                }
            }
            Row(Modifier.graphicsLayer { alpha = if (picks.isEmpty()) 0.4f else 1f }.testTag("filter.reset").pressClick(enabled = picks.isNotEmpty(), label = "重置", onClick = onReset)
                .heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Icon(Icons.Rounded.Refresh, null, Modifier.size(14.dp), tint = c.accent)
                Text("重置", color = c.accent, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
private fun StickyStrip(names: List<String>, backdrop: Backdrop, onExpand: () -> Unit) {
    val c = IdjThemeColors
    Row(Modifier.fillMaxWidth().glassSurface(RoundedCornerShape(23.dp), backdrop = backdrop, shadowRadius = 15.dp).pointerInput(Unit) {}.heightIn(min = 46.dp).padding(start = 14.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(Icons.Rounded.FilterList, null, Modifier.size(17.dp), tint = c.accent)
        Text(if (names.isEmpty()) "全部剧集" else names.joinToString(" · "), Modifier.weight(1f, fill = false), color = c.text, fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (names.isNotEmpty()) Box(Modifier.defaultMinSize(18.dp, 18.dp).clip(CircleShape).background(c.accent).padding(horizontal = 5.dp), contentAlignment = Alignment.Center) {
            Text("${names.size}", color = c.onAccent, fontSize = 11.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.weight(1f))
        Row(Modifier.heightIn(min = 32.dp).clip(CircleShape).background(c.glass).testTag("filter.expand").pressClick(label = "展开筛选", onClick = onExpand).padding(start = 12.dp, end = 8.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text("展开", color = c.secondary, fontSize = 13.sp)
            Icon(Icons.Rounded.KeyboardArrowDown, null, Modifier.size(16.dp), tint = c.secondary)
        }
    }
}

/** Grid / shelf cell (`.cell`): poster + 14 sp title + 12 sp subtitle. */
@Composable
internal fun PosterCell(s: HGSeries, rank: Int?, subtitle: String? = null, onOpen: (String) -> Unit, modifier: Modifier = Modifier) {
    val c = IdjThemeColors
    Column(modifier.pressClick(0.97f, label = s.title) {
        app.iduanju.data.Catalog.rememberPreview(s.seriesId, s.title, s.cover)
        onOpen(s.seriesId)
    }) {
        PosterArt(s.cover, Modifier.fillMaxWidth().aspectRatio(3f / 4f), rank = rank, badge = HomeFmt.progress(s)?.let { DS.spaced(it) })
        Text(s.title, color = c.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 7.dp))
        val sub = subtitle ?: if (s.playCount > 0) DS.count(s.playCount) + "热度" else HomeFmt.meta(s)
        if (sub.isNotEmpty()) Text(sub, color = c.secondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 2.dp))
    }
}

/** Ranked row from #4 (`.rrow`): numeral · 62×84 poster · title, tags, episodes + heat. */
@Composable
internal fun RankRow(s: HGSeries, rank: Int, onOpen: (String) -> Unit) {
    val c = IdjThemeColors
    Row(Modifier.fillMaxWidth().pressClick(0.98f, label = s.title) {
        app.iduanju.data.Catalog.rememberPreview(s.seriesId, s.title, s.cover)
        onOpen(s.seriesId)
    }.padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.width(26.dp), contentAlignment = Alignment.Center) { RankNumeral(rank) }
        Box(Modifier.size(62.dp, 84.dp).clip(RoundedCornerShape(9.dp)).background(c.glass)) {
            AsyncImage(s.cover, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        }
        Column(Modifier.weight(1f)) {
            Text(s.title, color = c.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val tags = (s.tags + if (s.isNew) listOf("新剧") else emptyList()).take(3)
            if (tags.isNotEmpty()) Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(5.dp)) { tags.forEach { DSTag(it) } }
            Row(Modifier.padding(top = 7.dp), horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                HomeFmt.progress(s)?.let { Text(DS.spaced(it), color = c.secondary, fontSize = 12.sp) }
                if (s.playCount > 0) {
                    Icon(Icons.Rounded.LocalFireDepartment, null, Modifier.size(12.dp), tint = c.accentWarm)
                    Text(DS.count(s.playCount), color = c.accentWarm, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

/** Board grids (BoardScreen) use the same redesigned cell. */
@Composable
internal fun NumberedPosterCell(s: HGSeries, rank: Int?, onOpen: (String) -> Unit) = PosterCell(s, rank, null, onOpen, Modifier.padding(bottom = 16.dp))


class CategoryState : androidx.lifecycle.ViewModel() {
    val scope get() = viewModelScope
    val filterMode = mutableStateOf(app.iduanju.BuildConfig.DEBUG && app.iduanju.ui.UiEvidence.page == "filter")
    val genre = mutableStateOf(HGRankGenre.all)
    val sub = mutableStateOf(HGRankSub.hotSearch)
    val panel = mutableStateOf<HGPanel?>(null)
    val panelErr = mutableStateOf<String?>(null)
    val selected = androidx.compose.runtime.mutableStateMapOf<String, String>()
    val names = androidx.compose.runtime.mutableStateMapOf<String, String>()
    val items = androidx.compose.runtime.mutableStateListOf<HGSeries>()
    val nextOffset = androidx.compose.runtime.mutableIntStateOf(0)
    val session = mutableStateOf<String?>(null)
    val hasMore = mutableStateOf(false)
    val loading = mutableStateOf(false)
    val err = mutableStateOf<String?>(null)
    val gen = androidx.compose.runtime.mutableIntStateOf(0)
    val panelGen = androidx.compose.runtime.mutableIntStateOf(0)
    var loadedKey: String? = null
    val grid = androidx.compose.foundation.lazy.grid.LazyGridState()
}
