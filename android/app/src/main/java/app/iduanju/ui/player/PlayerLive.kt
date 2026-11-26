package app.iduanju.ui.player

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.FormatListBulleted
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.ClosedCaption
import androidx.compose.material.icons.filled.EventNote
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.IdjApp
import app.iduanju.core.hongguo.HGEpisode
import app.iduanju.core.tvbox.Programme
import app.iduanju.ui.components.GlassSearchField
import app.iduanju.ui.components.GlassSpinner
import app.iduanju.ui.components.Motion
import app.iduanju.ui.components.OptionChip
import app.iduanju.ui.components.PlainIconButton
import app.iduanju.ui.components.glassSurface
import app.iduanju.ui.components.pressClick
import app.iduanju.ui.theme.IdjDarkColors
import com.kyant.backdrop.Backdrop
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** What the player reads from a channel's `media` JSON. */
internal class ChannelMeta(val logo: String, val sources: Int, val guide: Boolean, val replayDays: Int) {
    companion object {
        private val none = ChannelMeta("", 0, false, 0)
        fun of(ep: HGEpisode): ChannelMeta = runCatching {
            val o = JSONObject(ep.media ?: "{}")
            val c = o.optJSONObject("catchup")
            ChannelMeta(o.optString("logo"), o.optJSONArray("urls")?.length() ?: 0, o.optString("epg").isNotBlank(), if (c == null) 0 else c.optInt("days").coerceIn(1, 7))
        }.getOrDefault(none)
    }
}

@Immutable
internal class NowNext(val now: Programme?, val next: Programme?)

@Composable
internal fun rememberNowNext(session: PlayerSession): State<NowNext> {
    val ep = session.episode
    return produceState(NowNext(null, null), ep?.vid, session.seriesId) {
        value = NowNext(null, null)
        if (ep == null || !session.channelList) return@produceState
        // Flipping through channels must not fire a request for each of them.
        delay(600)
        val list = try { session.programmes(System.currentTimeMillis()) } catch (e: CancellationException) { throw e } catch (e: Exception) { return@produceState }
        val sorted = withContext(Dispatchers.Default) { list.sortedBy { it.start } }
        while (true) {
            val t = System.currentTimeMillis()
            value = NowNext(sorted.lastOrNull { it.start <= t && t < it.end }, sorted.firstOrNull { it.start > t })
            delay(30_000)
        }
    }
}

private fun clockOf(ms: Long): String = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(ms))

@Composable
internal fun LiveBadge(modifier: Modifier = Modifier) {
    Row(modifier.clip(RoundedCornerShape(6.dp)).background(IdjDarkColors.danger.copy(0.22f)).padding(horizontal = 7.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Box(Modifier.size(6.dp).clip(CircleShape).background(IdjDarkColors.danger))
        Text("LIVE", color = Color.White, fontSize = 10.5.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.4.sp)
    }
}

@Composable
private fun ReplayBadge() {
    Text("回看", color = IdjDarkColors.accent, fontSize = 10.5.sp, fontWeight = FontWeight.Bold,
        modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(IdjDarkColors.accent.copy(0.20f)).padding(horizontal = 7.dp, vertical = 2.dp))
}

/** Channel name + LIVE · 线路 · 分组, in the top bar. */
@Composable
internal fun LiveHeading(session: PlayerSession, dims: PlayerDimens, modifier: Modifier) {
    val ep = session.episode
    val n = session.streams.size
    val i = session.streams.indexOfFirst { it.streamId == session.stream?.streamId }
    Column(modifier) {
        Text(ep?.title?.ifBlank { null } ?: session.detail?.title.orEmpty(), color = Color.White, fontSize = if (dims.tablet) 18.sp else 16.sp, fontWeight = FontWeight.Bold,
            maxLines = 1, overflow = TextOverflow.Ellipsis, style = TextStyle(shadow = Shadow(Color.Black.copy(0.65f), blurRadius = 6f)))
        Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (session.replay != null) ReplayBadge() else LiveBadge()
            val sub = listOfNotNull(if (n > 1 && i >= 0) "线路 ${i + 1}/$n" else null, session.replay?.title ?: ep?.page?.takeIf { it.isNotBlank() }, session.tags.res).joinToString(" · ")
            if (sub.isNotEmpty()) Text(sub, color = Color.White.copy(0.72f), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** 正在播出 / 稍后播出, only when the source has an EPG. */
@Composable
internal fun LiveProgramLine(session: PlayerSession, modifier: Modifier = Modifier) {
    val nn by rememberNowNext(session)
    val now = nn.now
    val next = nn.next
    if (now == null && next == null) return
    Text(
        buildAnnotatedString {
            val dim = SpanStyle(color = Color.White.copy(0.6f))
            if (now != null) { withStyle(dim) { append("正在播 ") }; append(now.title) }
            if (next != null) withStyle(dim) { append((if (now != null) "  ·  " else "") + "接着 ${clockOf(next.start)} ${next.title}") }
        },
        modifier, color = Color.White.copy(0.92f), fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
        style = TextStyle(shadow = Shadow(Color.Black.copy(0.6f), blurRadius = 5f)),
    )
}

/** Live console: 频道 · 线路 · 画面 · 音轨字幕 (no time line, speed or auto-next). */
@Composable
internal fun LiveControls(session: PlayerSession, ui: PlayerUi, dims: PlayerDimens, enabled: Boolean, canToggleOrientation: Boolean, onOrientation: () -> Unit) {
    val n = session.streams.size
    val i = session.streams.indexOfFirst { it.streamId == session.stream?.streamId }
    val lineValue = if (n > 1 && i >= 0) "${i + 1}/$n" else null
    val meta = remember(session.episode?.media) { session.episode?.let { ChannelMeta.of(it) } }
    val guide = meta?.guide == true
    val openChannels = { if (dims.landscape) { ui.panel = null; ui.channelDrawer = !ui.channelDrawer } else ui.toggle(PlayerPanel.Channels) }
    if (dims.landscape) Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.weight(1f).padding(end = 8.dp)) { LiveProgramLine(session) }
        LandChip(Icons.AutoMirrored.Filled.FormatListBulleted, "频道", null, ui.channelDrawer, enabled) { openChannels() }
        if (guide) LandChip(Icons.Filled.EventNote, "节目单", null, ui.panel == PlayerPanel.Guide, enabled) { ui.toggle(PlayerPanel.Guide) }
        LandChip(Icons.Filled.SwapHoriz, "线路", lineValue, ui.panel == PlayerPanel.Quality, enabled && n > 0) { if (n > 1) ui.toggle(PlayerPanel.Quality) else session.retry() }
        LandChip(Icons.Filled.AspectRatio, "画面", if (ui.fill) "铺满" else "适应", ui.fill, enabled) { ui.applyFill(!ui.fill) }
        LandChip(Icons.Filled.ClosedCaption, "音轨字幕", null, ui.panel == PlayerPanel.Tracks, enabled) { ui.toggle(PlayerPanel.Tracks) }
        if (canToggleOrientation) HudIcon(Icons.Filled.FullscreenExit, "退出全屏", onOrientation)
    } else Row(Modifier.fillMaxWidth()) {
        ActionBtn(Icons.AutoMirrored.Filled.FormatListBulleted, "频道", null, ui.panel == PlayerPanel.Channels, false, enabled) { openChannels() }
        if (guide) ActionBtn(Icons.Filled.EventNote, "节目单", null, ui.panel == PlayerPanel.Guide, false, enabled) { ui.toggle(PlayerPanel.Guide) }
        ActionBtn(Icons.Filled.SwapHoriz, "线路", lineValue, ui.panel == PlayerPanel.Quality, false, enabled && n > 0) { if (n > 1) ui.toggle(PlayerPanel.Quality) else session.retry() }
        ActionBtn(Icons.Filled.AspectRatio, "画面", if (ui.fill) "铺满" else "适应", false, ui.fill, enabled) { ui.applyFill(!ui.fill) }
        ActionBtn(Icons.Filled.ClosedCaption, "音轨字幕", null, ui.panel == PlayerPanel.Tracks, false, enabled) { ui.toggle(PlayerPanel.Tracks) }
        if (canToggleOrientation) ActionBtn(Icons.Filled.Fullscreen, "全屏", null, false, false, enabled, onOrientation)
    }
}

/** 回看 console under the time line: back to live · 节目单 · 频道 · 倍速 · 线路. */
@Composable
internal fun ReplayControls(session: PlayerSession, ui: PlayerUi, dims: PlayerDimens, enabled: Boolean) {
    val openChannels = { if (dims.landscape) { ui.panel = null; ui.channelDrawer = !ui.channelDrawer } else ui.toggle(PlayerPanel.Channels) }
    if (dims.landscape) Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        LandChip(Icons.Filled.LiveTv, "返回直播", null, true, enabled) { session.backToLive() }
        Spacer(Modifier.weight(1f))
        LandChip(Icons.Filled.EventNote, "节目单", null, ui.panel == PlayerPanel.Guide, enabled) { ui.toggle(PlayerPanel.Guide) }
        LandChip(Icons.AutoMirrored.Filled.FormatListBulleted, "频道", null, ui.channelDrawer, enabled) { openChannels() }
        LandChip(Icons.Filled.Speed, "倍速", speedText(session.speed), session.speed != 1f, enabled) { ui.toggle(PlayerPanel.Speed) }
        LandChip(Icons.Filled.SwapHoriz, "线路", null, ui.panel == PlayerPanel.Quality, enabled && session.streams.size > 1) { ui.toggle(PlayerPanel.Quality) }
    } else Row(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        ActionBtn(Icons.Filled.LiveTv, "返回直播", null, false, true, enabled) { session.backToLive() }
        ActionBtn(Icons.Filled.EventNote, "节目单", null, ui.panel == PlayerPanel.Guide, false, enabled) { ui.toggle(PlayerPanel.Guide) }
        ActionBtn(Icons.AutoMirrored.Filled.FormatListBulleted, "频道", null, ui.panel == PlayerPanel.Channels, false, enabled) { openChannels() }
        ActionBtn(Icons.Filled.Speed, "倍速", speedText(session.speed), ui.panel == PlayerPanel.Speed, session.speed != 1f, enabled) { ui.toggle(PlayerPanel.Speed) }
        ActionBtn(Icons.Filled.SwapHoriz, "线路", null, ui.panel == PlayerPanel.Quality, false, enabled && session.streams.size > 1) { ui.toggle(PlayerPanel.Quality) }
    }
}

/** 节目单: one day at a time; finished programmes replay when the channel has catch-up. */
@Composable
internal fun GuidePanel(session: PlayerSession, modifier: Modifier, close: () -> Unit) {
    val pc = IdjDarkColors
    val ep = session.episode
    val meta = remember(ep?.media) { ep?.let { ChannelMeta.of(it) } }
    var day by remember(ep?.vid) { mutableIntStateOf(0) }
    var list by remember(ep?.vid) { mutableStateOf<List<Programme>?>(null) }
    val now = remember(ep?.vid, day) { System.currentTimeMillis() }
    LaunchedEffect(ep?.vid, day) {
        list = null
        list = try { session.programmes(now + day * 86_400_000L).sortedBy { it.start } } catch (e: CancellationException) { throw e } catch (e: Exception) { emptyList() }
    }
    val replayable = remember(ep?.vid, list) { list?.firstOrNull { it.end <= now }?.let { session.canReplay(it) } == true }
    val state = rememberLazyListState()
    LaunchedEffect(list) { list?.indexOfFirst { it.end > now }?.takeIf { it > 1 && day == 0 }?.let { state.scrollToItem(it - 1) } }
    Column(modifier) {
        PanelTitle("节目单", ep?.title)
        LazyRow(Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val past = (meta?.replayDays ?: 0).coerceAtLeast(1).coerceAtMost(3)
            items((-past..1).toList(), key = { it }) { d ->
                OptionChip(when (d) { 0 -> "今天"; -1 -> "昨天"; 1 -> "明天"; -2 -> "前天"; else -> SimpleDateFormat("M月d日", Locale.getDefault()).format(Date(now + d * 86_400_000L)) }, d == day, onMedia = true, minHeight = 30.dp) { day = d }
            }
        }
        val rows = list
        when {
            rows == null -> Box(Modifier.fillMaxWidth().height(120.dp), contentAlignment = Alignment.Center) { GlassSpinner(color = Color.White) }
            rows.isEmpty() -> Text("这一天没有节目单", color = Color.White.copy(0.6f), fontSize = 13.sp, modifier = Modifier.padding(vertical = 28.dp).align(Alignment.CenterHorizontally))
            else -> LazyColumn(Modifier.fillMaxWidth().weight(1f, fill = false), state = state, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                itemsIndexed(rows, key = { i, p -> "$i:${p.start}" }) { _, p ->
                    val onAir = p.start <= now && now < p.end
                    val past = p.end <= now
                    val current = session.replay?.let { it.start == p.start && it.title == p.title } ?: onAir
                    Row(Modifier.fillMaxWidth().heightIn(min = 46.dp).clip(RoundedCornerShape(12.dp)).background(if (current) pc.accentSoft else Color.Transparent)
                        .then(if (past && replayable) Modifier.pressClick(0.98f, label = "回看 ${p.title}") { session.playReplay(p); close() }
                            else if (onAir && session.replay != null) Modifier.pressClick(0.98f, label = "返回直播") { session.backToLive(); close() } else Modifier)
                        .semantics { selected = current }.padding(horizontal = 12.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(clockOf(p.start), color = if (current) pc.accent else Color.White.copy(if (past && !replayable) 0.35f else 0.6f), fontSize = 12.sp, modifier = Modifier.widthIn(min = 44.dp))
                        Text(p.title, color = if (current) pc.accent else Color.White.copy(if (past && !replayable) 0.45f else 0.92f), fontSize = 14.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
                            fontWeight = if (current) FontWeight.SemiBold else FontWeight.Normal, modifier = Modifier.weight(1f))
                        when {
                            onAir -> Text("直播中", color = pc.danger, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 8.dp))
                            past && replayable -> Text("回看", color = pc.accent, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 8.dp))
                        }
                    }
                }
            }
        }
    }
}

/** Landscape / tablet: the channel list as a drawer on the right edge. */
@Composable
internal fun ChannelDrawer(session: PlayerSession, ui: PlayerUi, dims: PlayerDimens, visible: Boolean, backdrop: Backdrop?, modifier: Modifier) {
    AnimatedVisibility(visible, modifier, enter = Motion.sideEnter, exit = Motion.sideExit) {
        Box(Modifier.fillMaxHeight().padding(vertical = 12.dp).padding(end = 12.dp).width(if (dims.tablet) 360.dp else 320.dp)
            .glassSurface(RoundedCornerShape(28.dp), backdrop = backdrop, dark = true, base = PlayerGlass, shadowRadius = 20.dp, fallbackAlpha = 0.7f, activeOverlay = Color.Black.copy(0.28f))
            .pointerInput(Unit) { detectTapGestures { } }) {
            ChannelList(session, Modifier.fillMaxSize().padding(horizontal = 14.dp, vertical = 14.dp)) { session.select(it) }
        }
    }
}

/** Groups · search · favourites · channels. Filtering runs only when the query, group or list changes. */
@Composable
internal fun ChannelList(session: PlayerSession, modifier: Modifier, onPick: (Int) -> Unit) {
    val pc = IdjDarkColors
    val tv = IdjApp.instance.tvbox
    val channels = session.episodes
    val groups = remember(channels) { listOf(ALL, FAV) + channels.mapNotNull { it.page?.takeIf { p -> p.isNotBlank() } }.distinct() }
    var group by remember(channels) { mutableStateOf(session.episode?.page?.takeIf { it.isNotBlank() } ?: ALL) }
    var query by remember { mutableStateOf("") }
    val favourites = tv.state.favorites
    val shown = remember(channels, group, query, if (group == FAV) favourites else null) {
        val q = query.trim()
        channels.indices.filter { i ->
            val c = channels[i]
            when {
                q.isNotEmpty() -> c.title.contains(q, ignoreCase = true) || c.page?.contains(q, ignoreCase = true) == true
                group == ALL -> true
                group == FAV -> c.title in favourites
                else -> c.page == group
            }
        }
    }
    val state = rememberLazyListState()
    LaunchedEffect(group, channels) { shown.indexOf(session.epIndex).takeIf { it >= 0 }?.let { state.scrollToItem((it - 3).coerceAtLeast(0)) } ?: state.scrollToItem(0) }
    Column(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("频道", color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            Text("${shown.size} / ${channels.size}", color = Color.White.copy(0.6f), fontSize = 12.sp)
        }
        GlassSearchField(query, { query = it }, Modifier.padding(top = 10.dp), placeholder = "搜索频道", colors = pc, minHeight = 40.dp)
        LazyRow(Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(groups, key = { it }) { g -> OptionChip(g.removePrefix("\u0000"), g == group && query.isBlank(), onMedia = true, minHeight = 30.dp) { query = ""; group = g } }
        }
        if (shown.isEmpty()) Text(if (group == FAV && query.isBlank()) "还没有收藏的频道" else "没有匹配的频道", color = Color.White.copy(0.6f), fontSize = 13.sp, modifier = Modifier.padding(vertical = 24.dp).align(Alignment.CenterHorizontally))
        LazyColumn(Modifier.fillMaxWidth().weight(1f, fill = false), state = state, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            items(shown, key = { it }, contentType = { 0 }) { i ->
                val ep = channels[i]
                ChannelRow(ep, i + 1, i == session.epIndex, ep.title in favourites, onStar = { tv.toggleFavorite(ep.title) }) { onPick(i) }
            }
        }
    }
}

// not names a list could use for a group of its own
private const val ALL = "\u0000全部"
private const val FAV = "\u0000收藏"

@Composable
private fun ChannelRow(ep: HGEpisode, number: Int, current: Boolean, starred: Boolean, onStar: () -> Unit, onClick: () -> Unit) {
    val pc = IdjDarkColors
    val meta = remember(ep.media) { ChannelMeta.of(ep) }
    val ctx = LocalContext.current
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp)).background(if (current) pc.accentSoft else Color.Transparent)
        .pressClick(0.98f, label = ep.title.ifBlank { "频道 $number" }, onClick = onClick).semantics { selected = current }.padding(start = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text("%02d".format(number), color = if (current) pc.accent else Color.White.copy(0.45f), fontSize = 11.sp, modifier = Modifier.widthIn(min = 26.dp))
        Box(Modifier.size(34.dp, 24.dp), contentAlignment = Alignment.Center) {
            if (meta.logo.isNotBlank()) coil.compose.AsyncImage(
                remember(meta.logo) { coil.request.ImageRequest.Builder(ctx).data(meta.logo).size(120, 90).build() }, null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
            else Icon(Icons.Filled.LiveTv, null, Modifier.size(18.dp), tint = Color.White.copy(0.35f))
        }
        Spacer(Modifier.width(10.dp))
        Text(ep.title.ifBlank { "频道 $number" }, color = if (current) pc.accent else Color.White.copy(0.9f), fontSize = 14.sp, fontWeight = if (current) FontWeight.SemiBold else FontWeight.Normal,
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        if (meta.sources > 1) Text("${meta.sources} 条线路", color = Color.White.copy(0.45f), fontSize = 11.sp, modifier = Modifier.padding(start = 6.dp))
        PlainIconButton(if (starred) Icons.Filled.Star else Icons.Filled.StarBorder, if (starred) "取消收藏" else "收藏", tint = if (starred) pc.accentWarm else Color.White.copy(0.4f), iconSize = 18.dp, onClick = onStar)
    }
}
