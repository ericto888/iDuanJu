@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package app.iduanju.ui.player

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.core.hongguo.HGStream
import app.iduanju.core.hongguo.HGStreamKind
import app.iduanju.ui.components.DS
import app.iduanju.ui.components.EpisodeCell
import app.iduanju.ui.components.EpisodeNames
import app.iduanju.ui.components.GlassStyle
import app.iduanju.ui.components.GlassStylePref
import app.iduanju.ui.components.Motion
import app.iduanju.ui.components.OptionChip
import app.iduanju.ui.components.glassSurface
import app.iduanju.ui.components.pressClick
import app.iduanju.ui.detail.EpisodeGroups
import app.iduanju.ui.theme.IdjDarkColors
import com.kyant.backdrop.Backdrop

/**
 * The one settings sheet: 选集 / 倍速 / 画质 / 音轨字幕 / 更多 / 弹幕设置 / 频道. Tablets get a centred floating glass
 * modal over a light scrim, phones a sheet just above the console; 弹幕设置 stays compact and unscrimmed so the live
 * comments remain visible behind it.
 */
@Composable
internal fun BoxScope.PanelHost(
    session: PlayerSession, ui: PlayerUi, enhance: EnhanceState, nextDrama: NextDramaController, dims: PlayerDimens, inPip: Boolean, backdrop: Backdrop?,
    onSwitchSeries: (String) -> Unit, onCopyTitle: () -> Unit,
) {
    val open = ui.panel
    val last = remember { arrayOfNulls<PlayerPanel>(1) }
    if (open != null) last[0] = open
    val shown = last[0]
    val metrics = dims.metrics
    val danmaku = shown == PlayerPanel.Danmaku
    val centered = dims.tablet && !danmaku
    val side = danmaku && dims.landscape
    if (!inPip && open != null) Box(Modifier.fillMaxSize()
        .background(if (dims.tablet && open != PlayerPanel.Danmaku) Color.Black.copy(0.30f) else Color.Transparent)
        .pointerInput(Unit) { detectTapGestures { ui.panel = null } })
    AnimatedVisibility(
        !inPip && open != null,
        when {
            centered -> Modifier.align(Alignment.Center).navigationBarsPadding().padding(24.dp)
            side -> Modifier.align(Alignment.CenterEnd).navigationBarsPadding().padding(horizontal = 16.dp, vertical = 14.dp)
            else -> Modifier.align(Alignment.BottomCenter).navigationBarsPadding().imePadding().padding(horizontal = 12.dp)
                .padding(bottom = if (dims.landscape || danmaku) 16.dp else 78.dp)
        },
        enter = when { centered -> Motion.modalEnter; side -> Motion.sideEnter; else -> Motion.riseEnter },
        exit = when { centered -> Motion.modalExit; side -> Motion.sideExit; else -> Motion.riseExit },
    ) {
        val liquid = GlassStylePref.style == GlassStyle.LIQUID
        val maxW = when { centered -> 540.dp; side -> if (dims.tablet) 380.dp else 340.dp; else -> 520.dp }
        val maxH = when { centered -> metrics.heightDp * 0.80f; side -> metrics.heightDp * 0.86f; danmaku -> metrics.heightDp * 0.48f; else -> metrics.heightDp * 0.74f }
        // Grids and channel lists scroll themselves; everything else scrolls as one column.
        val lazy = shown == PlayerPanel.Episodes || shown == PlayerPanel.Channels || shown == PlayerPanel.Guide
        Column(
            Modifier.widthIn(max = maxW).fillMaxWidth().heightIn(max = maxH.dp)
                // One glass layer over the video. LIQUID: lens glass plus a smoke layer so the text stays legible over
                // bright video; FROSTED: dense high-readability fill. Controls inside are plain wells.
                .glassSurface(RoundedCornerShape(if (centered || danmaku) 28.dp else 24.dp), backdrop = backdrop, dark = true, base = Color(0xFF1C1E24), shadowRadius = 20.dp,
                    fallbackAlpha = if (danmaku) (if (liquid) 0.44f else 0.72f) else (if (liquid) 0.52f else 0.92f),
                    activeOverlay = if (liquid) Color.Black.copy(alpha = if (danmaku) 0.28f else 0.40f) else Color.Black.copy(alpha = 0.10f))
                .pointerInput(Unit) { detectTapGestures { } }
                .semantics { paneTitle = panelName(shown) }
                .then(if (lazy) Modifier else Modifier.verticalScroll(rememberScrollState()))
                .padding(start = if (centered) 20.dp else 16.dp, end = if (centered) 20.dp else 16.dp, top = if (centered) 20.dp else 16.dp, bottom = if (centered) 18.dp else 14.dp),
        ) {
            when (shown) {
                PlayerPanel.Episodes -> EpisodesPanel(session, onPick = { session.select(it); ui.panel = null }, onSeason = { ui.panel = null; onSwitchSeries(it) })
                PlayerPanel.Speed -> SpeedPanel(session) { ui.panel = null }
                PlayerPanel.Quality -> QualityPanel(session) { ui.panel = null }
                PlayerPanel.Tracks -> TracksPanel(session)
                PlayerPanel.More -> MorePanel(session, ui, enhance, nextDrama, onCopyTitle)
                PlayerPanel.Danmaku -> DanmakuSettingsSheet(pc = IdjDarkColors, onDismiss = { ui.panel = null }, onReset = { session.hint = "弹幕设置已重置" })
                PlayerPanel.Channels -> ChannelList(session, Modifier.fillMaxWidth().weight(1f, fill = false)) { session.select(it) }
                PlayerPanel.Guide -> GuidePanel(session, Modifier.fillMaxWidth().weight(1f, fill = false)) { ui.panel = null }
                null -> Unit
            }
        }
    }
}

private fun panelName(p: PlayerPanel?): String = when (p) {
    PlayerPanel.Episodes -> "选集"; PlayerPanel.Speed -> "倍速"; PlayerPanel.Quality -> "画质"; PlayerPanel.Tracks -> "音轨字幕"
    PlayerPanel.More -> "更多设置"; PlayerPanel.Danmaku -> "弹幕设置"; PlayerPanel.Channels -> "频道"; PlayerPanel.Guide -> "节目单"; null -> ""
}

@Composable
internal fun PanelTitle(title: String, trailing: String?) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
        Text(title, color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f).semantics { heading() })
        trailing?.let { Text(it, color = Color.White.copy(0.6f), fontSize = 12.sp) }
    }
}

@Composable
private fun PanelLabel(text: String) =
    Text(text, color = Color.White.copy(0.55f), fontSize = 12.sp, modifier = Modifier.padding(start = 2.dp, top = 14.dp, bottom = 8.dp))

/** spec `.prow`: 46 dp, value right-aligned; current row accent-soft with accent text and ✓. */
@Composable
internal fun PanelRow(title: String, detail: String, on: Boolean, enabled: Boolean = true, onClick: () -> Unit) {
    val pc = IdjDarkColors
    Row(Modifier.fillMaxWidth().heightIn(min = 46.dp).clip(RoundedCornerShape(12.dp)).background(if (on) pc.accentSoft else Color.Transparent)
        .pressClick(0.98f, enabled = enabled, onClick = onClick).semantics { selected = on }.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = if (on) pc.accent else Color.White, fontSize = 15.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
            maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        if (detail.isNotEmpty()) Text(detail, color = if (on) pc.accent.copy(0.8f) else Color.White.copy(0.55f), fontSize = 12.sp, maxLines = 1, modifier = Modifier.padding(start = 10.dp))
        if (on) { Spacer(Modifier.width(10.dp)); Icon(Icons.Filled.Check, null, tint = pc.accent, modifier = Modifier.size(18.dp)) }
    }
}

// ── 选集 ────────────────────────────────────────────────────────────────────────────────────────────────

/** 季 chips → 线路 → 30-episode groups → grid; 正序 / 倒序. Titles that are more than numbers get text cells. */
@Composable
internal fun ColumnScope.EpisodesPanel(session: PlayerSession, onPick: (Int) -> Unit, onSeason: (String) -> Unit) {
    val d = session.detail ?: return
    val eps = session.episodes
    val total = eps.size
    val current = session.epIndex
    var reversed by remember(session.seriesId) { mutableStateOf(false) }
    val textual = remember(eps) { !session.seriesId.all { it.isDigit() } && EpisodeNames.textual(eps) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(if (session.queued) "章节" else "选集", color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.Bold, modifier = Modifier.semantics { heading() })
        Text(
            if (textual || session.queued) "共 $total 集".let { if (session.queued) "共 $total 章" else it }
            else "共 ${maxOf(total, if (d.lines.size > 1) 0 else d.totalEps)} 集 · 更新至 ${eps.lastOrNull()?.ep ?: total} 集",
            color = Color.White.copy(0.6f), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).padding(start = 10.dp),
        )
        if (total > 1) Row(Modifier.clip(RoundedCornerShape(10.dp)).pressClick(label = if (reversed) "切换为正序" else "切换为倒序") { reversed = !reversed }.padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.SwapVert, null, Modifier.size(16.dp), tint = Color.White.copy(0.72f))
            Text(if (reversed) "倒序" else "正序", color = Color.White.copy(0.72f), fontSize = 12.sp, modifier = Modifier.padding(start = 3.dp))
        }
    }
    val seasons = remember(d.relatedSeries) {
        d.relatedSeries.map { it to app.iduanju.core.hongguo.SeasonParser.seasonNo(it.title) }.distinctBy { it.second }.sortedByDescending { it.second }
    }
    if (seasons.size > 1) ChipScroller(Modifier.padding(top = 12.dp)) {
        seasons.forEach { (s, n) -> OptionChip("第 $n 季", s.seriesId == d.seriesId, onMedia = true) { if (s.seriesId != d.seriesId) onSeason(s.seriesId) } }
    }
    if (session.multiLine) ChipScroller(Modifier.padding(top = 12.dp)) {
        session.lines.forEachIndexed { i, l -> if (l.episodes.isNotEmpty()) OptionChip(l.name.ifBlank { "线路 ${i + 1}" }, i == session.currentLineIndex, onMedia = true, minHeight = 30.dp) { session.selectLine(i) } }
    }
    val ranges = remember(total) { EpisodeGroups.ranges(total) }
    var group by remember(eps) { mutableIntStateOf(ranges.indexOfFirst { current in it }.coerceAtLeast(0)) }
    if (ranges.size > 1) ChipScroller(Modifier.padding(top = 10.dp)) {
        (if (reversed) ranges.indices.reversed() else ranges.indices).forEach { r -> OptionChip(EpisodeGroups.label(ranges[r], eps), r == group, onMedia = true, minHeight = 28.dp) { group = r } }
    }
    val cells = remember(eps, group, reversed) { ranges.getOrNull(group)?.toList().orEmpty().let { if (reversed) it.reversed() else it } }
    AnimatedContent(cells, Modifier.weight(1f, fill = false), label = "eps", transitionSpec = { fadeIn(DS.select()) togetherWith fadeOut(DS.select()) }) { list ->
        val grid = rememberLazyGridState(initialFirstVisibleItemIndex = list.indexOf(current).coerceAtLeast(0))
        LazyVerticalGrid(if (textual) GridCells.Adaptive(96.dp) else GridCells.Adaptive(52.dp), Modifier.fillMaxWidth().padding(top = 12.dp), state = grid,
            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(list, key = { it }) { i ->
                val ep = eps.getOrNull(i) ?: return@items
                EpisodeCell(EpisodeNames.cell(ep, textual), i == current, Modifier.fillMaxWidth(), textual, IdjDarkColors, label = EpisodeNames.full(ep)) { onPick(i) }
            }
        }
    }
}

@Composable
private fun ChipScroller(modifier: Modifier, content: @Composable RowScope.() -> Unit) =
    Row(modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp), content = content)

// ── 倍速 / 画质 / 音轨字幕 ────────────────────────────────────────────────────────────────────────────────

@Composable
private fun SpeedPanel(session: PlayerSession, close: () -> Unit) {
    PanelTitle("倍速", "长按画面临时 2×")
    Spacer(Modifier.height(8.dp))
    listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f, 3f).forEach { s ->
        PanelRow(if (s == 1f) "1× 正常速度" else "${s}×".replace(".0×", "×"), "", s == session.speed) { session.applySpeed(s); close() }
    }
}

/** 线路 (when the title has several) · 画质 · 播放源. Live: the channel's sources. */
@Composable
private fun QualityPanel(session: PlayerSession, close: () -> Unit) {
    LaunchedEffect(session.episode?.vid) { session.ensureStreams() }
    if (session.multiLine) {
        PanelTitle("线路", "切换后保持集数与进度")
        Spacer(Modifier.height(8.dp))
        session.lines.forEachIndexed { i, l ->
            val ok = session.epIndex in l.episodes.indices
            PanelRow(l.name.ifBlank { "线路 ${i + 1}" }, if (ok) "${l.episodes.size} 集" else if (l.episodes.isEmpty()) "无可用集" else "仅 ${l.episodes.size} 集", i == session.currentLineIndex, l.episodes.isNotEmpty()) { session.selectLine(i); close() }
        }
        PanelLabel("画质")
    } else PanelTitle(if (session.channelList) "线路" else "画质", null)
    if (!session.multiLine) Spacer(Modifier.height(8.dp))
    val streams = session.streams
    if (streams.isEmpty()) {
        val q = session.quality ?: session.tags.res ?: "自动"
        PanelRow(q, session.player.videoFormat?.takeIf { it.width > 0 }?.let { "${it.width}×${it.height}" } ?: "", true) { close() }
    } else streams.forEach { s ->
        val on = s.streamId == session.stream?.streamId
        PanelRow(if (session.channelList) session.liveLineName(s) else s.quality?.ifBlank { null } ?: "自动", streamDetail(s, if (on) session else null), on) { session.selectStream(s); close() }
    }
    session.detail?.source?.takeIf { it.isNotBlank() }?.let {
        PanelLabel("播放源")
        PanelRow(it, "当前", true) { close() }
    }
}

private fun streamDetail(s: HGStream, playing: PlayerSession?): String {
    val f = playing?.player?.videoFormat
    return listOfNotNull(
        when {
            s.width > 0 && s.height > 0 -> "${s.width}×${s.height}"
            f != null && f.width > 0 -> "${f.width}×${f.height}"
            s.codec.isNotEmpty() -> if (s.codec.equals("h264", true)) "H.264" else s.codec
            else -> null
        },
        if (s.bitrate > 0) "%.1fMbps".format(s.bitrate / 1_000_000.0) else null,
        if (s.width == 0 && s.codec.isEmpty() && f == null) (if (s.kind == HGStreamKind.hls) "HLS" else null) else null,
    ).joinToString(" · ")
}

@Composable
private fun TracksPanel(session: PlayerSession) {
    PanelTitle("音轨字幕", null)
    PanelLabel("音轨")
    val audio = session.audioTracks
    if (audio.isEmpty()) PanelRow(session.tags.audio ?: "默认音轨", "", true) { }
    else audio.forEach { t -> PanelRow(t.label, t.detail, t.selected) { session.selectAudio(t) } }
    PanelLabel("字幕")
    val text = session.textTracks
    if (text.isEmpty()) PanelRow("关闭", "当前视频没有可选字幕", true) { }
    else {
        PanelRow("关闭", "", text.none { it.selected }) { session.selectText(null) }
        text.forEach { t -> PanelRow(t.label, t.detail, t.selected) { session.selectText(t) } }
    }
}

// ── 更多 ────────────────────────────────────────────────────────────────────────────────────────────────

@Composable
private fun MorePanel(session: PlayerSession, ui: PlayerUi, enhance: EnhanceState, nextDrama: NextDramaController, onCopyTitle: () -> Unit) {
    val sleepNote = when {
        session.sleepMode == -1 -> "定时：播完本集"
        session.sleepMode > 0 && session.sleepEndMs > 0L -> "定时：约 ${((session.sleepEndMs - System.currentTimeMillis()).coerceAtLeast(0L) / 60_000L) + 1} 分钟后暂停"
        else -> null
    }
    PanelTitle("更多设置", sleepNote)
    Spacer(Modifier.height(10.dp))
    if (session.danmakuCapable) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 46.dp).clip(RoundedCornerShape(12.dp)).background(Color.White.copy(0.08f))
                .border(0.8.dp, Color.White.copy(0.10f), RoundedCornerShape(12.dp))
                .pressClick(0.98f, label = "弹幕设置") { ui.panel = PlayerPanel.Danmaku }.padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Subtitles, null, tint = Color.White.copy(0.86f), modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(10.dp))
            Text("弹幕设置", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
            Text(DanmakuPrefs.summary(), color = Color.White.copy(0.55f), fontSize = 12.sp)
            Spacer(Modifier.width(4.dp))
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Color.White.copy(0.55f), modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.height(12.dp))
    }
    OptionRow("画面比例", listOf("适应" to false, "铺满" to true), ui.fill) {
        ui.applyFill(it)
        session.hint = if (it) "画面：铺满裁剪" else "画面：完整适应"
    }
    OptionRow("AI 超分辨率 (EWA-Lanczos4)", listOf("关闭" to 0, "标准" to 1, "强效" to 2), enhance.level) { enhance.applyLevel(it) }
    if (session.nativeHdr) OptionRow("SDR 转 HDR (逆色调映射) · 当前片源已是原生 ${session.tags.range}", listOf("原生 ${session.tags.range}" to true), true, enabled = false) { }
    else OptionRow("SDR 转 HDR (逆色调映射)", listOf("关闭" to false, "开启" to true), enhance.sdrToHdr) { enhance.applyHdr(it) }
    OptionRow("定时关闭", listOf("关" to 0, "本集完" to -1, "15分" to 15, "30分" to 30, "60分" to 60).filter { !(session.channelList && it.second == -1) }, session.sleepMode) { session.setSleep(it) }
    if (!session.queued && !session.channelList) OptionRow("自动连播", listOf("开启" to true, "关闭" to false), session.autoNext) { session.applyAutoNext(it) }
    if (nextDrama.capable) OptionRow("播完连刷推荐 (最后一集播完自动续播下一部)", listOf("开启" to true, "关闭" to false), nextDrama.enabled) { nextDrama.applyEnabled(it) }
    Text("快捷操作", color = Color.White.copy(0.60f), fontSize = 12.sp, fontWeight = FontWeight.Medium)
    Spacer(Modifier.height(6.dp))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        QuickPill("技术信息", Icons.Filled.Info, ui.showTech, Modifier.weight(1f)) { ui.showTech = !ui.showTech; ui.showChrome = true }
        QuickPill(if (session.muted) "已静音" else "静音", if (session.muted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp, session.muted, Modifier.weight(1f)) { session.toggleMute() }
        QuickPill(if (session.channelList) "复制频道名" else "复制剧名", Icons.Filled.ContentCopy, false, Modifier.weight(1f), onCopyTitle)
    }
}

@Composable
private fun QuickPill(title: String, icon: ImageVector, active: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val pc = IdjDarkColors
    val shape = RoundedCornerShape(10.dp)
    Row(modifier.clip(shape).background(if (active) pc.accent.copy(0.18f) else Color.White.copy(0.08f))
        .border(0.8.dp, if (active) pc.accent.copy(0.55f) else Color.White.copy(0.12f), shape)
        .pressClick(0.97f, label = title, onClick = onClick).heightIn(min = 40.dp).padding(horizontal = 6.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterHorizontally)) {
        val ink = if (active) pc.accent else Color.White.copy(0.86f)
        Icon(icon, null, Modifier.size(15.dp), tint = ink)
        Text(title, color = ink, fontSize = 12.sp, fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun <T> OptionRow(label: String, options: List<Pair<String, T>>, selected: T, enabled: Boolean = true, onSelect: (T) -> Unit) {
    Text(label, color = Color.White.copy(if (enabled) 0.60f else 0.38f), fontSize = 12.sp, fontWeight = FontWeight.Medium)
    Spacer(Modifier.height(6.dp))
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).graphicsLayer { alpha = if (enabled) 1f else 0.45f }, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        options.forEach { (title, value) -> OptionChip(title, value == selected, onMedia = true, enabled = enabled || value == selected) { if (enabled && value != selected) onSelect(value) } }
    }
    Spacer(Modifier.height(11.dp))
}
