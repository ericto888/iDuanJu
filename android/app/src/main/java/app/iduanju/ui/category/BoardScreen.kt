package app.iduanju.ui.category

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridItemSpanScope
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import app.iduanju.IdjApp
import app.iduanju.core.hongguo.HGSeries
import app.iduanju.ui.components.ErrorState
import app.iduanju.ui.components.GlassSpinner
import app.iduanju.ui.components.GlassTextButton
import app.iduanju.ui.components.LocalLayoutMetrics
import app.iduanju.ui.components.PosterSkeleton
import app.iduanju.ui.home.BoardSpec
import app.iduanju.ui.profile.SubPage
import app.iduanju.ui.theme.IdjThemeColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Survives opening a drama from the board: list, paging cursor and scroll position stay when coming back. */
class BoardState : ViewModel() {
    val items = mutableStateListOf<HGSeries>()
    val nextOffset = mutableIntStateOf(0)
    val hasMore = mutableStateOf(true)
    val loading = mutableStateOf(false)
    val err = mutableStateOf<String?>(null)
    val grid = LazyGridState()
}

/** iOS BoardListView: the full board behind a home section's 「全部」 (numbered grid, paged). */
@Composable
fun BoardScreen(board: BoardSpec, onBack: () -> Unit, onOpenDetail: (String) -> Unit) {
    val c = IdjThemeColors
    val vm: BoardState = viewModel()
    val items = vm.items
    var nextOffset by vm.nextOffset
    var hasMore by vm.hasMore
    var loading by vm.loading
    var err by vm.err

    fun load() {
        if (loading) return
        loading = true; err = null
        vm.viewModelScope.launch {
            try {
                val p = withContext(Dispatchers.IO) { IdjApp.instance.hongguo.rank(board.sub, board.genre, nextOffset, items.map { it.seriesId }) }
                val seen = items.mapTo(HashSet()) { it.seriesId }
                items.addAll(p.items.filter { seen.add(it.seriesId) })
                nextOffset = p.nextOffset ?: (nextOffset + p.items.size); hasMore = p.hasMore && p.items.isNotEmpty()
            } catch (e: Exception) { err = e.message ?: "加载失败" }
            loading = false
        }
    }
    LaunchedEffect(Unit) { if (items.isEmpty()) load() }
    val grid = vm.grid
    LaunchedEffect(grid) {
        snapshotFlow { grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }.collect { last -> if (hasMore && !loading && err == null && last >= items.size - 3) load() }
    }

    val cols = LocalLayoutMetrics.current.posterCols
    val bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val full: LazyGridItemSpanScope.() -> GridItemSpan = { GridItemSpan(maxLineSpan) }
    SubPage(board.title, onBack, { grid.firstVisibleItemIndex > 0 || grid.firstVisibleItemScrollOffset > 4 }) { top ->
        LazyVerticalGrid(GridCells.Fixed(cols), Modifier.fillMaxSize(), state = grid,
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = top + 8.dp, bottom = bottom + 24.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(0.dp)) {
            itemsIndexed(items, key = { _, s -> s.seriesId }, contentType = { _, _ -> "poster" }) { i, s -> NumberedPosterCell(s, i + 1, onOpenDetail) }
            if (items.isEmpty()) {
                if (err != null) item("error", full, "state") { ErrorState("加载失败", note = err) { load() } }
                else items(cols * 4, key = { "skeleton$it" }, contentType = { "skeleton" }) { PosterSkeleton(Modifier.padding(bottom = 16.dp)) }
            } else item("footer", full, "footer") {
                Box(Modifier.fillMaxWidth().padding(8.dp), contentAlignment = Alignment.Center) {
                    when {
                        loading -> GlassSpinner(size = 24.dp)
                        err != null -> GlassTextButton("$err · 点击重试", color = c.secondary, fontSize = 13.sp) { load() }
                        !hasMore -> Text("没有更多了", color = c.tertiary, fontSize = 12.sp)
                    }
                }
            }
        }
    }
}
