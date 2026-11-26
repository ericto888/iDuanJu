package app.iduanju.ui.player

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBackIos
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.IdjApp
import app.iduanju.ui.components.ButtonSize
import app.iduanju.ui.components.ButtonTone
import app.iduanju.ui.components.DS
import app.iduanju.ui.components.EpisodeNames
import app.iduanju.ui.components.GlassButton
import app.iduanju.ui.components.GlassIconButton
import app.iduanju.ui.components.GlassSpinner
import app.iduanju.ui.components.Motion
import app.iduanju.ui.components.glassSurface
import app.iduanju.ui.components.pressClick
import app.iduanju.ui.theme.IdjDarkColors
import com.kyant.backdrop.Backdrop

private val titleShadow = TextStyle(shadow = Shadow(Color.Black.copy(0.65f), blurRadius = 6f))

/** "第 3 集 / 共 80 集", "第 2 章 · 标题", or the source's own episode title. */
@Composable
internal fun rememberEpisodeLabel(session: PlayerSession, startEp: Int): String {
    val d = session.detail
    val ep = session.episode
    val n = session.episodes.size
    return remember(d, ep, n, session.epIndex) {
        when {
            d == null -> ""
            session.queued -> "第 ${session.epIndex + 1} 章 · ${ep?.title.orEmpty()}"
            ep == null -> "第 $startEp 集"
            n <= 1 -> ep.title.ifBlank { "第 ${ep.ep} 集" }
            else -> "${EpisodeNames.full(ep)} / 共 ${maxOf(if (d.lines.size > 1) 0 else d.totalEps, n)} 集"
        }
    }
}

/** Dark gradients behind the top bar and the console; alpha is read in the layer block. */
@Composable
internal fun BoxScope.ChromeScrims(alpha: () -> Float, bottom: () -> Float, dims: PlayerDimens) {
    Box(Modifier.fillMaxWidth().height(if (dims.wide) 120.dp else 110.dp).graphicsLayer { this.alpha = alpha() }
        .background(Brush.verticalGradient(listOf(Color.Black.copy(0.55f), Color.Black.copy(0.18f), Color.Transparent))))
    Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(if (dims.wide) 170.dp else 210.dp).graphicsLayer { this.alpha = bottom() }
        .background(Brush.verticalGradient(0f to Color.Transparent, 0.45f to Color.Black.copy(0.18f), 1f to Color.Black.copy(0.6f))))
}

/** Back · title / episode · badges · actions. */
@Composable
internal fun TopBar(
    session: PlayerSession, ui: PlayerUi, enhance: EnhanceState, dims: PlayerDimens, label: String, enabled: Boolean, padSplit: Boolean,
    alpha: () -> Float, onBack: () -> Unit, onPip: () -> Unit, modifier: Modifier = Modifier,
) {
    val d = session.detail
    val lib = IdjApp.instance.library
    val pc = IdjDarkColors
    val nativeRange = if (session.nativeHdr) session.tags.range else null
    Column(modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = dims.pad).padding(top = if (dims.landscape) 12.dp else 6.dp).graphicsLayer { this.alpha = alpha() }) {
        Row(Modifier.fillMaxWidth().heightIn(min = dims.button), verticalAlignment = Alignment.CenterVertically) {
            CircleBtn(Icons.AutoMirrored.Filled.ArrowBackIos, "返回", enabled, dims.button, dims.buttonIcon, onClick = onBack)
            if (session.channelList) {
                Spacer(Modifier.width(12.dp))
                LiveHeading(session, dims, Modifier.weight(1f))
                Spacer(Modifier.width(12.dp))
            } else if (dims.wide) {
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(d?.title.orEmpty(), color = Color.White, fontSize = if (dims.tablet) 17.sp else 16.sp, fontWeight = FontWeight.Bold,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, style = titleShadow)
                    Row(Modifier.padding(top = 3.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (label.isNotEmpty()) {
                            Text(label, color = Color.White.copy(0.72f), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                            Spacer(Modifier.width(8.dp))
                        }
                        if (session.multiLine) { LinePill(session, enabled) { ui.toggle(PlayerPanel.Quality) }; Spacer(Modifier.width(8.dp)) }
                        StatusBadges(session.tags, enhance.enhanceOn, enhance.hdrOn, nativeRange, enabled) { ui.toggle(PlayerPanel.More) }
                    }
                }
                Spacer(Modifier.width(12.dp))
            } else Spacer(Modifier.weight(1f))
            Row(horizontalArrangement = Arrangement.spacedBy(if (dims.tablet) 10.dp else 8.dp), verticalAlignment = Alignment.CenterVertically) {
                CircleBtn(Icons.Filled.PictureInPictureAlt, "画中画", enabled, dims.button, dims.buttonIcon, onClick = onPip)
                if (!session.queued) {
                    if (session.channelList) {
                        val tv = IdjApp.instance.tvbox
                        val name = session.episode?.title.orEmpty()
                        val fav = tv.isFavorite(name)
                        CircleBtn(if (fav) Icons.Filled.Star else Icons.Filled.StarBorder, if (fav) "取消收藏频道" else "收藏频道", enabled && name.isNotEmpty(), dims.button, dims.buttonIcon,
                            tint = if (fav) pc.accent else Color.White) {
                            tv.toggleFavorite(name)
                            session.hint = if (fav) "已取消收藏" else "已收藏频道"
                        }
                    } else {
                        val fav = lib.isFavorite(session.seriesId)
                        CircleBtn(if (fav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, if (fav) "取消收藏" else "收藏", enabled, dims.button, dims.buttonIcon,
                            tint = if (fav) pc.accent else Color.White) { d?.let { lib.toggleFavorite(session.seriesId, it.title, it.cover) } }
                    }
                }
                if (padSplit) CircleBtn(Icons.Filled.GridView, if (ui.padDrawerOpen) "收起选集" else "展开选集", enabled, dims.button, dims.buttonIcon,
                    tint = if (ui.padDrawerOpen) pc.accent else Color.White) { ui.padDrawerOpen = !ui.padDrawerOpen }
                CircleBtn(Icons.Filled.MoreHoriz, "更多", enabled, dims.button, dims.buttonIcon) { ui.toggle(PlayerPanel.More) }
            }
        }
        if (!dims.wide && !session.channelList) Box(Modifier.fillMaxWidth().padding(top = 8.dp), contentAlignment = Alignment.Center) {
            StatusBadges(session.tags, enhance.enhanceOn, enhance.hdrOn, nativeRange, enabled) { ui.toggle(PlayerPanel.More) }
        }
        if (ui.showTech) TechStrip(session.tags, Modifier.align(Alignment.CenterHorizontally).padding(top = 6.dp))
    }
}

/** −10 s · play / pause · +10 s (live: previous channel · play / pause · next channel). */
@Composable
internal fun CenterTransport(session: PlayerSession, dims: PlayerDimens, visible: Boolean, backdrop: Backdrop?, modifier: Modifier) {
    AnimatedVisibility(visible, modifier, enter = Motion.modalEnter, exit = Motion.modalExit) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(if (dims.tablet) 84.dp else 52.dp)) {
            if (session.live) CircleBtn(Icons.Filled.SkipPrevious, "上一个频道", session.hasPrev, dims.side, dims.side * 0.52f) { session.prev() }
            else CircleBtn(Icons.Filled.Replay10, "后退10秒", true, dims.side, dims.side * 0.52f) { session.seekBy(-10_000L) }
            Box(
                Modifier.size(dims.main)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.46f))
                    .border(0.6.dp, Color.White.copy(alpha = 0.10f), CircleShape)
                    .pressClick(0.92f, label = if (session.playing) "暂停" else "播放") { session.togglePlay() },
                contentAlignment = Alignment.Center,
            ) {
                Crossfade(session.playing, label = "pp") { p -> Icon(if (p) Icons.Filled.Pause else Icons.Filled.PlayArrow, null, tint = Color.White, modifier = Modifier.size(dims.main * 0.46f)) }
            }
            if (session.live) CircleBtn(Icons.Filled.SkipNext, "下一个频道", session.hasNext, dims.side, dims.side * 0.52f) { session.next() }
            else CircleBtn(Icons.Filled.Forward10, "前进10秒", true, dims.side, dims.side * 0.52f) { session.seekBy(10_000L) }
        }
    }
}

/** Bottom console: overlays the video, never reserves space in its viewport. */
@Composable
internal fun BottomConsole(
    session: PlayerSession, ui: PlayerUi, dims: PlayerDimens, label: String, enabled: Boolean, seekPreview: SeekPreviewState, backdrop: Backdrop?,
    alpha: () -> Float, canToggleOrientation: Boolean, onOrientation: () -> Unit, modifier: Modifier = Modifier,
) {
    val d = session.detail
    Column(modifier.navigationBarsPadding().padding(horizontal = dims.pad).padding(bottom = if (dims.wide) 16.dp else 6.dp)
        .then(if (dims.wide) Modifier.widthIn(max = 860.dp) else Modifier).fillMaxWidth().graphicsLayer { this.alpha = alpha() }) {
        if (d != null && !dims.wide && !session.channelList) {
            MetaRow(session, ui, label, enabled)
            Spacer(Modifier.height(6.dp))
            Text(d.title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 21.sp, lineHeight = 27.sp, maxLines = 1,
                overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 6.dp), style = titleShadow)
            Spacer(Modifier.height(8.dp))
        }
        if (session.live && !dims.wide) LiveProgramLine(session, Modifier.padding(horizontal = 6.dp).padding(bottom = 10.dp))
        Column(Modifier.fillMaxWidth()
            .then(if (dims.wide) Modifier.glassSurface(RoundedCornerShape(26.dp), backdrop = backdrop, dark = true, base = PlayerGlass, shadowRadius = 16.dp, fallbackAlpha = 0.44f)
                .padding(horizontal = 16.dp, vertical = 10.dp) else Modifier.padding(horizontal = 6.dp))
            // swallow taps on the console background so they never toggle the HUD underneath
            .pointerInput(Unit) { detectTapGestures { } }) {
            if (session.live) {
                LiveControls(session, ui, dims, enabled, canToggleOrientation, onOrientation)
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier.size(36.dp).clip(CircleShape)
                            .pressClick(0.88f, enabled = enabled, label = if (session.playing) "暂停" else "播放") {
                                session.togglePlay()
                                ui.showChrome = true
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        Crossfade(session.playing, label = "barPP") { p ->
                            Icon(if (p) Icons.Filled.Pause else Icons.Filled.PlayArrow, null, tint = Color.White, modifier = Modifier.size(24.dp))
                        }
                    }
                    Spacer(Modifier.width(if (dims.tablet) 8.dp else 4.dp))
                    PlayerTimeBar(session.clock, dims.tablet, seekPreview, Modifier.weight(1f)) { if (!ui.locked) { session.seekTo(it); ui.showChrome = true } }
                    if (canToggleOrientation) {
                        Spacer(Modifier.width(if (dims.tablet) 12.dp else 8.dp))
                        HudIcon(if (dims.landscape) Icons.Filled.FullscreenExit else Icons.Filled.Fullscreen, if (dims.landscape) "退出全屏" else "横屏全屏", onOrientation)
                    }
                }
                if (session.channelList) ReplayControls(session, ui, dims, enabled) else VodControls(session, ui, dims, enabled)
            }
        }
    }
}

/** Playback actions only. 画面比例 / AI 超分 / SDR→HDR / 定时 / 连播 live solely in 更多设置 (top-right ⋯). */
@Composable
private fun VodControls(session: PlayerSession, ui: PlayerUi, dims: PlayerDimens, enabled: Boolean) {
    val speed = speedText(session.speed)
    val quality = session.quality?.takeIf { it.length <= 8 } ?: session.tags.res
    val dm = session.danmakuCapable
    val episodesWord = if (session.queued) "章节" else "选集"
    fun danmaku() { if (dm) { ui.applyDanmaku(!ui.danmaku); session.hint = if (ui.danmaku) "弹幕：开启" else "弹幕：关闭" } }
    if (dims.landscape) Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SkipIntro(session, enabled)
        Spacer(Modifier.weight(1f))
        LandChip(Icons.Filled.GridView, episodesWord, null, ui.panel == PlayerPanel.Episodes, enabled) { ui.toggle(PlayerPanel.Episodes) }
        LandChip(Icons.Filled.Speed, "倍速", speed, ui.panel == PlayerPanel.Speed || session.speed != 1f, enabled) { ui.toggle(PlayerPanel.Speed) }
        LandChip(Icons.Filled.HighQuality, "画质", quality, ui.panel == PlayerPanel.Quality, enabled) { ui.toggle(PlayerPanel.Quality) }
        LandChip(Icons.Filled.Subtitles, "弹幕", if (dm) (if (ui.danmaku) "开" else "关") else null, dm && ui.danmaku, enabled && dm) { danmaku() }
        LandChip(Icons.Filled.ClosedCaption, "音轨字幕", null, ui.panel == PlayerPanel.Tracks, enabled) { ui.toggle(PlayerPanel.Tracks) }
    } else Row(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        ActionBtn(Icons.Filled.GridView, episodesWord, null, ui.panel == PlayerPanel.Episodes, false, enabled) { ui.toggle(PlayerPanel.Episodes) }
        ActionBtn(Icons.Filled.Speed, "倍速", speed, ui.panel == PlayerPanel.Speed, session.speed != 1f, enabled) { ui.toggle(PlayerPanel.Speed) }
        ActionBtn(Icons.Filled.HighQuality, "画质", quality, ui.panel == PlayerPanel.Quality, false, enabled) { ui.toggle(PlayerPanel.Quality) }
        ActionBtn(Icons.Filled.Subtitles, "弹幕", if (dm) (if (ui.danmaku) "开" else "关") else null, false, dm && ui.danmaku, enabled && dm) { danmaku() }
        ActionBtn(Icons.Filled.ClosedCaption, "音轨字幕", null, ui.panel == PlayerPanel.Tracks, false, enabled) { ui.toggle(PlayerPanel.Tracks) }
    }
}

@Composable
private fun SkipIntro(session: PlayerSession, enabled: Boolean) {
    // derivedStateOf: recomposes only when the chip appears / disappears, not every tick.
    val show by remember(session) { derivedStateOf { session.clock.pos < 15_000 && session.clock.dur > 45_000 } }
    if (show) LandChip(Icons.Filled.SkipNext, "跳过片头", null, false, enabled) { session.seekTo(15_000) }
}

/** Source label · season · episode · current line. */
@Composable
private fun MetaRow(session: PlayerSession, ui: PlayerUi, label: String, enabled: Boolean) {
    val d = session.detail ?: return
    val season = remember(d.relatedSeries, d.seriesId) {
        val ss = d.relatedSeries
        val nums = ss.map { app.iduanju.core.hongguo.SeasonParser.seasonNo(it.title) }
        if (ss.size > 1 && nums.toSet().size == ss.size)
            "第 " + app.iduanju.core.hongguo.SeasonParser.seasonNo(ss.firstOrNull { it.seriesId == d.seriesId }?.title ?: d.title) + " 季" else null
    }
    Row(Modifier.heightIn(min = 28.dp).padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        if (d.source.isNotBlank()) {
            Text(d.source, color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
                modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(Color.White.copy(0.16f)).padding(horizontal = 7.dp, vertical = 2.dp))
            Spacer(Modifier.width(8.dp))
        }
        season?.let { Text("$it · ", color = Color.White.copy(0.72f), fontSize = 13.sp) }
        Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f, fill = false))
        if (session.multiLine) { Spacer(Modifier.width(8.dp)); LinePill(session, enabled) { ui.toggle(PlayerPanel.Quality) } }
    }
}

/** Current 线路; opens the quality panel. */
@Composable
private fun LinePill(session: PlayerSession, enabled: Boolean, onClick: () -> Unit) {
    val name = session.line?.name?.ifBlank { null } ?: "线路 ${session.currentLineIndex + 1}"
    Row(Modifier.clip(RoundedCornerShape(6.dp)).background(IdjDarkColors.accent.copy(0.20f)).pressClick(0.96f, enabled = enabled, label = "线路 $name", onClick = onClick)
        .padding(start = 7.dp, end = 3.dp, top = 2.dp, bottom = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(name, color = IdjDarkColors.accent, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 108.dp))
        Icon(Icons.Filled.ExpandMore, null, Modifier.size(14.dp), tint = IdjDarkColors.accent)
    }
}

/** Loading caption, error card, 2× badge and the short hint. */
@Composable
internal fun BoxScope.PlayerStatus(session: PlayerSession, backdrop: Backdrop?) {
    val waiting = session.error == null && session.status.isEmpty() && session.handoff == null && (session.buffering || !session.firstFrame)
    var slow by remember { mutableStateOf(false) }
    // Short grace period so locally cached instant switches never flash a spinner.
    LaunchedEffect(waiting) { slow = false; if (waiting) { kotlinx.coroutines.delay(280); slow = true } }
    val text = when {
        session.error != null -> ""
        session.status.isNotEmpty() -> session.status
        waiting && slow -> if (!session.firstFrame) (if (session.live) "正在连接…" else "正在加载视频…") else "正在缓冲…"
        else -> ""
    }
    AnimatedVisibility(text.isNotEmpty(), Modifier.align(Alignment.Center), enter = Motion.modalEnter, exit = Motion.modalExit) {
        val shown = remember { arrayOf("") }
        if (text.isNotEmpty()) shown[0] = text
        Column(
            Modifier.clip(RoundedCornerShape(16.dp))
                .background(Color(0xFF181A20).copy(alpha = 0.88f))
                .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
                .semantics { liveRegion = LiveRegionMode.Polite }.padding(horizontal = 20.dp, vertical = 14.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            GlassSpinner(size = 28.dp, color = Color.White)
            Spacer(Modifier.height(10.dp))
            Text(shown[0], color = Color.White.copy(0.88f), fontSize = 13.sp)
        }
    }
    session.error?.let { ErrorCard(session, it, backdrop, Modifier.align(Alignment.Center)) }
    if (session.holding) {
        Row(
            Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 96.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(Color(0xFF181A20).copy(alpha = 0.86f))
                .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(14.dp))
                .padding(horizontal = 22.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.FastForward, null, tint = Color.White)
            Spacer(Modifier.width(8.dp))
            Text("2.0×", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        }
    }
    Hint(session, Modifier.align(Alignment.Center))
}

@Composable
private fun Hint(session: PlayerSession, modifier: Modifier) {
    val h = session.hint
    LaunchedEffect(h) { if (h != null) { kotlinx.coroutines.delay(if (h.length > 10) 2_200 else 800); if (session.hint == h) session.hint = null } }
    if (h != null) Text(
        h, color = Color.White, fontSize = if (h.length > 10) 14.sp else 17.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center,
        modifier = modifier.offset(y = (-96).dp).padding(horizontal = 32.dp).semantics { liveRegion = LiveRegionMode.Polite }
            .clip(RoundedCornerShape(12.dp))
            .background(Color(0xFF181A20).copy(alpha = 0.86f))
            .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp))
            .padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

@Composable
private fun ErrorCard(session: PlayerSession, message: String, backdrop: Backdrop?, modifier: Modifier) {
    val pc = IdjDarkColors
    Column(
        modifier.padding(28.dp).widthIn(max = 320.dp)
            .clip(RoundedCornerShape(20.dp))
            .background(Color(0xFF1A1C22).copy(alpha = 0.92f))
            .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(20.dp))
            .pointerInput(Unit) { detectTapGestures { } }
            .padding(horizontal = 22.dp, vertical = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Filled.ErrorOutline, null, Modifier.size(28.dp), tint = pc.accentWarm)
        Text(message, color = Color.White.copy(0.92f), fontSize = 15.sp, lineHeight = 21.sp, textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 10.dp).semantics { liveRegion = LiveRegionMode.Assertive })
        session.line?.name?.takeIf { session.multiLine && it.isNotBlank() }?.let { Text("当前线路：$it", color = Color.White.copy(0.55f), fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp)) }
        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (session.canSwitchSource) {
                Box(
                    Modifier.heightIn(min = 40.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f))
                        .pressClick(0.94f, label = "换线路") { session.switchSource() }
                        .padding(horizontal = 18.dp, vertical = 8.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("换线路", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                }
            }
            GlassButton("重试", tone = ButtonTone.Primary, size = ButtonSize.Regular, colors = pc) { session.retry() }
        }
    }
}

// ── widgets ─────────────────────────────────────────────────────────────────────────────────────────────

/** Clean translucent player icon button over video scrim: no harsh glass rim or fake specular glare. */
@Composable
internal fun CircleBtn(icon: ImageVector, label: String, enabled: Boolean = true, size: Dp = 40.dp, iconSize: Dp = 21.dp, tint: Color = Color.White, onClick: () -> Unit) {
    Box(
        Modifier
            .size(size)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.28f))
            .graphicsLayer { alpha = if (enabled) 1f else 0.4f }
            .pressClick(0.90f, enabled = enabled, label = label, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(iconSize))
    }
}

/** Landscape console chip: icon + title + value; accent capsule when on. Plain wells: the console is the glass. */
@Composable
internal fun LandChip(icon: ImageVector, title: String, value: String?, on: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val pc = IdjDarkColors
    Row(Modifier.heightIn(min = 34.dp).graphicsLayer { alpha = if (enabled) 1f else 0.45f }
        .clip(CircleShape).background(if (on) pc.accentSoft else Color.White.copy(0.10f))
        .border(0.8.dp, if (on) pc.accentLine else Color.White.copy(0.12f), CircleShape)
        .pressClick(enabled = enabled, label = title + (value?.let { " $it" } ?: ""), onClick = onClick).padding(horizontal = 13.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(icon, null, tint = if (on) pc.accent else Color.White, modifier = Modifier.size(17.dp))
        Text(title + (value?.let { " $it" } ?: ""), color = if (on) pc.accent else Color.White.copy(0.86f), fontSize = 13.sp, maxLines = 1, softWrap = false)
    }
}

/** Portrait action row cell (spec `.pact`): 23 dp icon over an 11 sp caption that carries the current value. */
@Composable
internal fun RowScope.ActionBtn(icon: ImageVector, title: String, value: String?, active: Boolean, accent: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val pc = IdjDarkColors
    val bg by animateColorAsState(if (active) Color.White.copy(0.15f) else Color.Transparent, DS.select(), label = "pact")
    Column(Modifier.weight(1f).clip(RoundedCornerShape(14.dp)).background(bg)
        .graphicsLayer { alpha = if (enabled) 1f else 0.42f }
        .pressClick(enabled = enabled, label = title + (value?.let { " $it" } ?: ""), onClick = onClick)
        .padding(top = 7.dp, bottom = 6.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, null, tint = if (accent) pc.accent else Color.White, modifier = Modifier.size(23.dp))
        Spacer(Modifier.height(4.dp))
        Text(buildAnnotatedString {
            append(title)
            if (value != null) {
                append(" ")
                pushStyle(SpanStyle(fontWeight = FontWeight.SemiBold, color = if (accent) pc.accent else Color.White)); append(value); pop()
            }
        }, color = Color.White.copy(0.72f), fontSize = 11.sp, lineHeight = 14.sp, maxLines = 1, softWrap = false)
    }
}

@Composable
internal fun HudIcon(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(40.dp, 36.dp).clip(CircleShape).pressClick(0.9f, label = label, onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = Color.White, modifier = Modifier.size(22.dp))
    }
}
