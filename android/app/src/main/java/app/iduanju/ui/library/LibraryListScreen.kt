package app.iduanju.ui.library

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.IdjApp
import app.iduanju.data.WatchProgress
import app.iduanju.ui.components.*
import app.iduanju.ui.profile.CoverCell
import app.iduanju.ui.profile.SubPage
import app.iduanju.ui.theme.IdjThemeColors
import coil.compose.AsyncImage

/** iOS LibraryListView: 我的收藏 (3-column grid) / 观看历史 (rows with progress; ✕ or a long press removes a record). */
@Composable
fun LibraryListScreen(kind: String, onBack: () -> Unit, onOpenDetail: (String) -> Unit) {
    val lib = IdjApp.instance.library
    val fav = kind == "favorites"
    var confirmClear by remember { mutableStateOf(false) }
    val grid = rememberLazyGridState()
    val bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + 24.dp
    if (confirmClear) GlassConfirm(
        onDismissRequest = { confirmClear = false },
        title = "清空全部观看记录？",
        message = "只删除本机的观看进度，收藏不受影响。",
        confirmText = "清空 ${lib.history.size} 条记录",
        destructive = true,
        onConfirm = { lib.clearHistory(); confirmClear = false },
    )
    SubPage(if (fav) "我的收藏" else "观看历史", onBack, { grid.firstVisibleItemIndex > 0 || grid.firstVisibleItemScrollOffset > 4 },
        trailing = { if (!fav && lib.history.isNotEmpty()) GlassTextButton("清空") { confirmClear = true } }) { top ->
        if (fav) {
            val items by remember { derivedStateOf { lib.favorites.entries.sortedByDescending { it.value.third }.map { Triple(it.key, it.value.first, it.value.second) } } }
            if (items.isEmpty()) EmptyState("还没有收藏", Modifier.padding(top = top + 80.dp), icon = Icons.Outlined.FavoriteBorder)
            else LazyVerticalGrid(GridCells.Fixed(LocalLayoutMetrics.current.posterCols), Modifier.fillMaxSize(), grid,
                PaddingValues(start = 16.dp, end = 16.dp, top = top + 8.dp, bottom = bottom),
                horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                items(items, key = { it.first }, contentType = { "poster" }) { (sid, title, cover) ->
                    CoverCell(title, cover, Modifier.animateItem()) { onOpenDetail(sid) }
                }
            }
        } else {
            val items by remember { derivedStateOf { lib.continueWatching } }
            if (items.isEmpty()) EmptyState("还没有观看记录", Modifier.padding(top = top + 80.dp), icon = Icons.Outlined.Schedule)
            else LazyVerticalGrid(GridCells.Fixed(LocalLayoutMetrics.current.listCols), Modifier.fillMaxSize(), grid,
                PaddingValues(start = 16.dp, end = 8.dp, top = top + 8.dp, bottom = bottom),
                horizontalArrangement = Arrangement.spacedBy(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                items(items, key = { it.seriesId }, contentType = { "history" }) { p ->
                    HistoryRow(p, onOpenDetail, { lib.removeProgress(it) }, Modifier.animateItem())
                }
            }
        }
    }
}

@Composable
private fun HistoryRow(p: WatchProgress, onOpen: (String) -> Unit, onRemove: (String) -> Unit, modifier: Modifier) {
    val c = IdjThemeColors
    var menu by remember { mutableStateOf(false) }
    Box(modifier) {
        Row(
            Modifier.fillMaxWidth().pressLongClick(0.98f, longLabel = "删除观看记录", onLongClick = { menu = true }) { onOpen(p.seriesId) },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(Modifier.size(64.dp, 86.dp).clip(RoundedCornerShape(8.dp)).background(c.glass)) {
                AsyncImage(p.cover, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(p.title, color = c.text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                val s = p.seconds.toInt()
                Text("${p.resumeLabel} · ${s / 60}:${"%02d".format(s % 60)}", color = c.secondary, fontSize = 12.sp)
                GlassProgressBar({ p.fraction }, height = 4.dp)
            }
            PlainIconButton(Icons.Rounded.Close, "删除观看记录", tint = c.secondary, iconSize = 18.dp) { onRemove(p.seriesId) }
        }
        GlassMenu(menu, { menu = false }) {
            GlassMenuItem("删除观看记录", icon = Icons.Outlined.Delete, destructive = true) { menu = false; onRemove(p.seriesId) }
        }
    }
}
