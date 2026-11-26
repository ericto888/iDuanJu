package app.iduanju.ui.profile

import android.net.Uri
import android.os.SystemClock
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Stars
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.MilitaryTech
import androidx.compose.material.icons.rounded.PersonOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.IdjApp
import app.iduanju.core.hongguo.*
import app.iduanju.ui.LocalNavigate
import app.iduanju.ui.components.*
import app.iduanju.ui.theme.IdjThemeColors
import coil.compose.AsyncImage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private object ActorRanking {
    val actors = mutableStateListOf<HGRankedActor>()
    var date by mutableStateOf("")
    var busy by mutableStateOf(false)
    var more by mutableStateOf(true)
    var error by mutableStateOf<String?>(null)
    private var offset = 0
    private var session = ""
    private var loadedAt = 0L
    val stale get() = actors.isEmpty() || SystemClock.elapsedRealtime() - loadedAt > 900_000

    suspend fun load(refresh: Boolean = false) {
        if (busy || (!refresh && !more)) return
        busy = true
        error = null
        try {
            val page = withContext(Dispatchers.IO) {
                if (refresh) HGActorRank.fetch(IdjApp.instance.hongguo)
                else HGActorRank.fetch(IdjApp.instance.hongguo, offset, session, actors.size)
            }
            if (refresh) actors.clear()
            val seen = actors.mapTo(hashSetOf()) { it.id }
            val fresh = page.actors.filter { seen.add(it.id) }
            actors.addAll(fresh.take(300 - actors.size))
            if (refresh || page.date.isNotEmpty()) date = page.date
            more = page.hasMore && fresh.isNotEmpty() && actors.size < 300
            offset = page.nextOffset
            session = page.sessionId
            loadedAt = SystemClock.elapsedRealtime()
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { error = e.message ?: "榜单加载失败" }
        finally { busy = false }
    }
}

internal fun actorRoute(actor: HGCelebrity) = "actor/${Uri.encode(actor.id)}?name=${Uri.encode(actor.name)}&avatar=${Uri.encode(actor.avatar)}&role=${Uri.encode(actor.role)}&intro=${Uri.encode(actor.intro)}"

@Composable
fun ActorRankScreen(onBack: () -> Unit) {
    val list = rememberLazyListState()
    SubPage("剧星榜", onBack, { list.firstVisibleItemIndex > 0 || list.firstVisibleItemScrollOffset > 4 }, under = false) {
        ActorRankList(WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + 24.dp, list)
    }
}

@Composable
fun ActorRankList(bottomPadding: Dp = 24.dp, state: LazyListState = rememberLazyListState(), header: (@Composable () -> Unit)? = null) {
    val store = ActorRanking
    var gender by rememberSaveable { mutableStateOf(ActorGender.All) }
    val scope = rememberCoroutineScope()
    val navigate = LocalNavigate.current
    val open = { a: HGRankedActor ->
        val role = listOf("剧星榜 No.${a.rank}", a.score).filter(String::isNotEmpty).joinToString(" · ")
        navigate(actorRoute(HGCelebrity(a.id, a.name, a.avatar, role, a.intro)))
    }
    LaunchedEffect(Unit) { if (store.stale) store.load(refresh = true) }
    val list by remember { derivedStateOf { if (gender == ActorGender.All) store.actors.toList() else store.actors.filter { it.gender == gender } } }
    LaunchedEffect(gender, list.size, store.busy, store.more, store.error) {
        if (list.size < 20 && store.more && !store.busy && store.error == null) scope.launch { store.load() }
    }
    var refreshing by remember { mutableStateOf(false) }
    GlassPullToRefresh(refreshing, {
        if (!store.busy) scope.launch {
            refreshing = true
            try { store.load(refresh = true) } finally { refreshing = false }
        }
    }) {
        val shown = list
        LazyColumn(Modifier.fillMaxSize(), state, contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = bottomPadding),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (header != null) item("header", "header") { header() }
            item("title", "title") {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Stars, null, tint = IdjThemeColors.text)
                    Text("剧星榜", Modifier.weight(1f).padding(start = 6.dp).semantics { heading() }, color = IdjThemeColors.text, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                    if (store.date.isNotBlank()) Text("统计截至 ${store.date}", color = IdjThemeColors.secondary, fontSize = 12.sp)
                }
            }
            item("gender", "gender") { SegmentedTabs(ActorGender.entries, gender, { it.label }, { gender = it }) }
            val podiumSize = if (shown.size >= 3) 3 else 0
            if (podiumSize == 3) item("podium", "podium") {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Bottom) {
                    for (i in listOf(1, 0, 2)) PodiumCell(shown[i], i + 1, Modifier.weight(1f), open)
                }
            }
            items(shown.size - podiumSize, key = { shown[it + podiumSize].id }, contentType = { "actor" }) { index ->
                val actor = shown[index + podiumSize]
                RankRow(actor, if (gender == ActorGender.All) actor.rank else index + podiumSize + 1, open)
            }
            if (shown.isEmpty() && store.error == null && (store.busy || store.more)) items(6, key = { "skeleton$it" }, contentType = { "skeleton" }) {
                SkeletonBlock(Modifier.fillMaxWidth().height(72.dp), 14.dp)
            }
            item("footer", "footer") {
                val error = store.error
                val retry: () -> Unit = { scope.launch { store.load(refresh = store.actors.isEmpty() || !store.more) } }
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    when {
                        error != null && store.actors.isEmpty() -> ErrorState("加载失败", note = error, onRetry = retry)
                        error != null -> GlassTextButton("$error · 重试", onClick = retry)
                        store.busy -> if (shown.isNotEmpty()) GlassSpinner(Modifier.padding(8.dp), 24.dp)
                        store.more -> LaunchedEffect(store.actors.size) { scope.launch { store.load() } }
                        shown.isEmpty() -> EmptyState("暂无榜单数据", icon = Icons.Rounded.PersonOff)
                        else -> Text("已经到底了", color = IdjThemeColors.secondary, fontSize = 12.sp, modifier = Modifier.padding(8.dp))
                    }
                }
            }
        }
    }
}

@Composable
internal fun ActorAvatar(url: String, size: Dp, modifier: Modifier = Modifier) {
    val c = IdjThemeColors
    AsyncImage(url, null, modifier.size(size).clip(CircleShape).background(c.glass).border(0.8.dp, c.text.copy(alpha = 0.12f), CircleShape), contentScale = ContentScale.Crop)
}

@Composable
private fun ChangeBadge(a: HGRankedActor) {
    val (label, color) = when {
        a.change == 1 && a.changeNum > 0 -> "▲ ${a.changeNum}" to Color(0xFFFF5959)
        a.change == 2 && a.changeNum > 0 -> "▼ ${a.changeNum}" to Color(0xFF59CC80)
        else -> "—" to IdjThemeColors.secondary
    }
    Text(label, color = color, fontSize = 11.sp, fontWeight = FontWeight.Bold, maxLines = 1)
}

@Composable
private fun PodiumCell(a: HGRankedActor, place: Int, modifier: Modifier, open: (HGRankedActor) -> Unit) {
    val tint = when (place) { 1 -> Color(0xFFFFC740); 2 -> Color(0xFFC7D1E6); else -> Color(0xFFDB8C52) }
    val shape = RoundedCornerShape(16.dp)
    val glass = IdjThemeColors.glass
    val fill = remember(tint, glass) { Brush.verticalGradient(listOf(tint.copy(alpha = .22f), glass)) }
    val src = remember { MutableInteractionSource() }
    Column(modifier.pressScale(src).clip(shape).background(fill)
        .border(1.dp, tint.copy(alpha = .35f), shape).clickable(src, null, onClickLabel = "第${place}名，${a.name}", role = Role.Button) { open(a) }
        .padding(vertical = 12.dp, horizontal = 4.dp).padding(top = if (place == 1) 0.dp else 18.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(contentAlignment = Alignment.TopCenter) {
            ActorAvatar(a.avatar, if (place == 1) 84.dp else 66.dp, Modifier.padding(top = 14.dp).border(2.5.dp, tint, CircleShape))
            if (place == 1) Crown(tint) else Icon(Icons.Rounded.MilitaryTech, null, Modifier.size(22.dp), tint = tint)
        }
        Text(a.name, color = IdjThemeColors.text, fontSize = 15.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(a.score, color = tint, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        ChangeBadge(a)
    }
}

/** iOS `crown.fill` over the first place. */
@Composable
private fun Crown(tint: Color) = Canvas(Modifier.padding(top = 2.dp).size(22.dp, 17.dp)) {
    val w = size.width; val h = size.height
    drawPath(Path().apply {
        moveTo(0f, h * 0.22f); lineTo(w * 0.27f, h * 0.58f); lineTo(w * 0.5f, 0f); lineTo(w * 0.73f, h * 0.58f)
        lineTo(w, h * 0.22f); lineTo(w * 0.9f, h); lineTo(w * 0.1f, h); close()
    }, tint)
}

@Composable
private fun RankRow(a: HGRankedActor, rank: Int, open: (HGRankedActor) -> Unit) {
    val c = IdjThemeColors
    Row(Modifier.fillMaxWidth().pressClick(0.98f) { open(a) }.clip(RoundedCornerShape(14.dp)).background(c.glass).padding(10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.width(34.dp), contentAlignment = Alignment.Center) { RankNumeral(rank, 18) }
        ActorAvatar(a.avatar, 52.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(a.name, Modifier.weight(1f, fill = false), color = c.text, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (a.gender != ActorGender.All) {
                    val tint = if (a.gender == ActorGender.Female) Color(0xFFE75C94) else c.accent
                    Text(if (a.gender == ActorGender.Female) "女" else "男", Modifier.background(tint.copy(.2f), CircleShape).padding(horizontal = 5.dp), color = tint, fontSize = 11.sp)
                }
                ChangeBadge(a)
            }
            if (a.works.isNotEmpty()) Text(a.works.joinToString(" · "), color = c.secondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (a.intro.isNotEmpty()) Text(a.intro, color = c.secondary, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(a.score, color = c.accentWarm, fontSize = 14.sp, fontWeight = FontWeight.Bold)
            Icon(Icons.Rounded.ChevronRight, null, Modifier.size(16.dp), tint = c.secondary)
        }
    }
}
