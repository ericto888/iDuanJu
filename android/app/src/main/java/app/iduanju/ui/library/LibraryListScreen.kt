package app.iduanju.ui.library

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.IdjApp
import app.iduanju.data.WatchProgress
import app.iduanju.ui.components.*
import app.iduanju.ui.profile.SubPage
import app.iduanju.ui.theme.IdjThemeColors
import coil.compose.AsyncImage

/**
 * iOS LibraryListView parity:
 * - 我的收藏: long-press menu (立即播放 / 查看详情 / 移出收藏) + top-right 管理 mode with multi-select, corner ✕ delete,
 *   and floating glass batch action dock (全选 / 删除所选 / 清空).
 * - 观看历史: rows with progress; ✕ or long press removes a record.
 */
@Composable
fun LibraryListScreen(
    kind: String,
    onBack: () -> Unit,
    onOpenDetail: (String) -> Unit,
    onPlay: (String, Int) -> Unit = { sid, _ -> onOpenDetail(sid) },
) {
    val c = IdjThemeColors
    val lib = IdjApp.instance.library
    val fav = kind == "favorites"
    val haptics = rememberHaptics()
    var confirmClear by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    val selected = remember { mutableStateListOf<String>() }
    val grid = rememberLazyGridState()
    val navBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val bottom = navBottom + if (fav && editing) 92.dp else 24.dp

    val favItems by remember {
        derivedStateOf { lib.favorites.entries.sortedByDescending { it.value.third }.map { Triple(it.key, it.value.first, it.value.second) } }
    }
    LaunchedEffect(favItems.size) {
        if (favItems.isEmpty() && editing) {
            editing = false
            selected.clear()
        } else {
            val valid = favItems.map { it.first }.toHashSet()
            selected.removeAll { it !in valid }
        }
    }

    if (confirmClear) GlassConfirm(
        onDismissRequest = { confirmClear = false },
        title = if (fav) "清空全部收藏？" else "清空全部观看记录？",
        message = if (fav) "将移出全部 ${lib.favorites.size} 部已收藏作品，观看历史不受影响。" else "只删除本机的观看进度，收藏不受影响。",
        confirmText = if (fav) "清空 ${lib.favorites.size} 部收藏" else "清空 ${lib.history.size} 条记录",
        destructive = true,
        onConfirm = {
            if (fav) {
                lib.clearFavorites()
                editing = false
                selected.clear()
                GlassToast.show("已清空我的收藏")
            } else {
                lib.clearHistory()
            }
            confirmClear = false
        },
    )

    SubPage(
        title = if (fav) "我的收藏" else "观看历史",
        onBack = onBack,
        pinned = { grid.firstVisibleItemIndex > 0 || grid.firstVisibleItemScrollOffset > 4 },
        trailing = {
            if (fav && favItems.isNotEmpty()) {
                GlassTextButton(if (editing) "完成" else "管理", color = if (editing) c.accent else c.text) {
                    editing = !editing
                    if (!editing) selected.clear()
                }
            } else if (!fav && lib.history.isNotEmpty()) {
                GlassTextButton("清空") { confirmClear = true }
            }
        },
    ) { top ->
        if (fav) {
            if (favItems.isEmpty()) {
                EmptyState("还没有收藏", Modifier.padding(top = top + 80.dp), icon = Icons.Outlined.FavoriteBorder)
            } else {
                Box(Modifier.fillMaxSize()) {
                    LazyVerticalGrid(
                        GridCells.Fixed(LocalLayoutMetrics.current.posterCols),
                        Modifier.fillMaxSize(),
                        grid,
                        PaddingValues(start = 16.dp, end = 16.dp, top = top + 8.dp, bottom = bottom),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        items(favItems, key = { it.first }, contentType = { "poster" }) { (sid, title, cover) ->
                            val isSel = sid in selected
                            FavoriteManageCell(
                                title = title,
                                cover = cover,
                                editing = editing,
                                selected = isSel,
                                modifier = Modifier.animateItem(),
                                onOpenDetail = {
                                    if (editing) {
                                        haptics.tick()
                                        if (isSel) selected.remove(sid) else selected.add(sid)
                                    } else onOpenDetail(sid)
                                },
                                onPlay = {
                                    val ep = lib.progress(sid)?.episodeNumber ?: 1
                                    onPlay(sid, ep)
                                },
                                onRemove = {
                                    haptics.tick()
                                    selected.remove(sid)
                                    lib.removeFavorite(sid)
                                    GlassToast.show("已移出收藏")
                                },
                            )
                        }
                    }

                    // Floating glass management dock
                    AnimatedVisibility(
                        visible = editing && favItems.isNotEmpty(),
                        modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(horizontal = 16.dp, vertical = 10.dp),
                        enter = slideInVertically(DS.panel()) { it } + fadeIn(),
                        exit = slideOutVertically(DS.panel()) { it } + fadeOut(),
                    ) {
                        val allSelected = selected.size == favItems.size && favItems.isNotEmpty()
                        Row(
                            Modifier.fillMaxWidth()
                                .glassSurface(RoundedCornerShape(28.dp), shadowRadius = 18.dp, fallbackAlpha = if (c.dark) 0.90f else 0.94f)
                                .padding(horizontal = 14.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            GlassTextButton(if (allSelected) "取消全选" else "全选", color = c.text) {
                                haptics.tick()
                                if (allSelected) selected.clear()
                                else {
                                    selected.clear()
                                    selected.addAll(favItems.map { it.first })
                                }
                            }
                            Spacer(Modifier.weight(1f))
                            GlassTextButton("清空", color = c.secondary) { confirmClear = true }
                            GlassButton(
                                text = if (selected.isEmpty()) "删除所选" else "删除 (${selected.size})",
                                tone = ButtonTone.Danger,
                                size = ButtonSize.Small,
                                enabled = selected.isNotEmpty(),
                            ) {
                                val count = selected.size
                                lib.removeFavorites(selected.toList())
                                selected.clear()
                                haptics.confirm()
                                GlassToast.show("已移出 $count 部收藏")
                            }
                        }
                    }
                }
            }
        } else {
            val items by remember { derivedStateOf { lib.continueWatching } }
            if (items.isEmpty()) EmptyState("还没有观看记录", Modifier.padding(top = top + 80.dp), icon = Icons.Outlined.Schedule)
            else LazyVerticalGrid(
                GridCells.Fixed(LocalLayoutMetrics.current.listCols),
                Modifier.fillMaxSize(),
                grid,
                PaddingValues(start = 16.dp, end = 8.dp, top = top + 8.dp, bottom = bottom),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(items, key = { it.seriesId }, contentType = { "history" }) { p ->
                    HistoryRow(p, onOpenDetail, { lib.removeProgress(it) }, Modifier.animateItem())
                }
            }
        }
    }
}

/** Shared favorite poster cell with long-press context menu (立即播放 / 查看详情 / 移出收藏) + optional batch management chrome. */
@Composable
internal fun FavoriteManageCell(
    title: String,
    cover: String,
    editing: Boolean = false,
    selected: Boolean = false,
    modifier: Modifier = Modifier,
    onOpenDetail: () -> Unit,
    onPlay: () -> Unit,
    onRemove: () -> Unit,
) {
    val c = IdjThemeColors
    var menu by remember { mutableStateOf(false) }
    Box(modifier) {
        Column(
            Modifier.pressLongClick(
                scale = 0.97f,
                label = title,
                longLabel = "收藏操作",
                onLongClick = { if (!editing) menu = true },
                onClick = onOpenDetail,
            ),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Box(
                Modifier.fillMaxWidth().aspectRatio(0.75f).clip(PosterShape).background(c.glass)
                    .then(if (editing && selected) Modifier.border(2.dp, c.accent, PosterShape) else Modifier),
            ) {
                AsyncImage(cover, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                if (editing) {
                    // Selection indicator (top-left)
                    Box(
                        Modifier.align(Alignment.TopStart).padding(6.dp).size(22.dp)
                            .clip(CircleShape)
                            .background(if (selected) c.accent else Color.Black.copy(0.45f))
                            .border(1.2.dp, if (selected) c.accent else Color.White.copy(0.78f), CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (selected) Icon(Icons.Filled.Check, null, tint = c.onAccent, modifier = Modifier.size(14.dp))
                    }
                    // Quick one-tap remove button (top-right)
                    Box(
                        Modifier.align(Alignment.TopEnd).padding(6.dp).size(22.dp)
                            .clip(CircleShape)
                            .background(Color.Black.copy(0.62f))
                            .pressClick(0.90f, label = "移出收藏", onClick = onRemove),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Rounded.Close, null, tint = Color.White, modifier = Modifier.size(13.dp))
                    }
                }
            }
            Text(title, color = c.text, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        GlassMenu(menu, { menu = false }) {
            GlassMenuItem("立即播放", icon = Icons.Outlined.PlayArrow) { menu = false; onPlay() }
            GlassMenuItem("查看详情", icon = Icons.Outlined.Info) { menu = false; onOpenDetail() }
            GlassMenuItem("移出收藏", icon = Icons.Outlined.Delete, destructive = true) { menu = false; onRemove() }
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
