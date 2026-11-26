package app.iduanju.ui.detail

import androidx.compose.foundation.background
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Star
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import app.iduanju.ui.components.*
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.ArrowBackIos
import com.kyant.backdrop.backdrops.layerBackdrop
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.rounded.SwapVert
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.IdjApp
import app.iduanju.core.hongguo.HGEpisode
import app.iduanju.core.hongguo.HGSeries
import app.iduanju.core.hongguo.HGSeriesDetail
import app.iduanju.ui.home.HomeFmt
import app.iduanju.ui.theme.IdjThemeColors
import coil.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Same as iOS/spec: groups of 30 (≤300), 50 (≤600), 60; tablet portrait uses 50 per tab so 10-col grids fill naturally. */
object EpisodeGroups {
    fun size(total: Int, groupLimit: Int = 30) = when {
        total <= groupLimit -> maxOf(total, 1)
        total <= 300 -> groupLimit
        total <= 600 -> maxOf(groupLimit, 50)
        else -> 60
    }
    fun ranges(total: Int, groupLimit: Int = 30): List<IntRange> {
        if (total <= 0) return emptyList()
        val g = size(total, groupLimit)
        if (total <= g) return listOf(0 until total)
        return (0 until total step g).map { it..minOf(it + g - 1, total - 1) }
    }
    fun label(r: IntRange, eps: List<HGEpisode>): String {
        val a = eps.getOrNull(r.first)?.ep ?: (r.first + 1); val b = eps.getOrNull(r.last)?.ep ?: (r.last + 1)
        return if (a == b) "$a" else "$a-$b"
    }
}

/** ui-redesign 12 / 13: blurred poster hero + poster card, stats card, actions, tags, folding intro, 选集 → 系列 → 演员;
 *  a pinned nav once the hero scrolls away and a floating play bar once the main button leaves the screen. */
@Composable
fun DetailScreen(seriesId: String, onBack: () -> Unit, onPlay: (String, Int) -> Unit, onOpenSeries: (String) -> Unit = {}) {
    val c = IdjThemeColors
    val lib = IdjApp.instance.library
    var d by remember { mutableStateOf<HGSeriesDetail?>(null) }
    var err by remember { mutableStateOf<String?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    LaunchedEffect(seriesId, reload) {
        err = null
        try {
            if (app.iduanju.BuildConfig.DEBUG && seriesId in listOf("ui-color-bars", "ui-detail-sparse", "ui-detail-full")) {
                d = HGSeriesDetail(
                    seriesId=seriesId,title="本地界面测试 · 非真实片源",desc="此页面使用明确标注的本地样例数据，用于检查详情页的排版、折叠、选集和滚动吸顶，不代表真实片源服务。".repeat(4),
                    author="界面验证",totalEps=48,episodes=(1..48).map{app.iduanju.core.hongguo.HGEpisode(it,"fixture-$it",60,"测试第 $it 集")},
                    tags=listOf("本地样例","排版验证"),favoriteCount=403000,
                    rating=if(seriesId=="ui-detail-sparse")0.0 else 8.6,ratingCount=if(seriesId=="ui-detail-sparse")"" else "1.2万",
                    hotText=if(seriesId=="ui-detail-sparse")"" else "512万",source="本地样例",
                    relatedSeries=(1..3).map { HGSeries(seriesId=if(it==1)seriesId else "sample-$it",title="本地系列样例 $it",episodeCount=48) },
                    cast=(1..5).map { app.iduanju.core.hongguo.HGCelebrity(id="sample-$it",name="样例演员 $it",role="饰 样例") })
            } else {
                val base = app.iduanju.data.Catalog.load(seriesId)
                d = base
                if (app.iduanju.data.Catalog.isHongguo(seriesId) && base.cast.isEmpty() && base.tags.isEmpty()) {
                    val enriched = withContext(Dispatchers.IO) { app.iduanju.data.Catalog.enrich(seriesId, base) }
                    if (enriched != null && d?.seriesId == enriched.seriesId) d = enriched
                }
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            err = e.message ?: "加载失败"
        }
    }
    val metrics = LocalLayoutMetrics.current
    val isExpanded = metrics.tier == SizeTier.Expanded
    val isTabletLandscape = isExpanded && metrics.isLandscape
    val isTabletPortrait = !metrics.isLandscape && metrics.tier != SizeTier.Compact
    val epGroupSize = if (isTabletPortrait) 50 else 30

    val resume = lib.progress(seriesId)
    // 线路: the one chosen by hand for this title, else the default.
    var lineIndex by remember(seriesId) { mutableIntStateOf(0) }
    LaunchedEffect(d) { d?.lines?.let { ls -> lineIndex = lib.preferredLine(seriesId)?.let { id -> ls.indexOfFirst { it.id == id && it.episodes.isNotEmpty() } }?.takeIf { it >= 0 } ?: 0 } }
    val eps = remember(d, lineIndex) { d?.let { dd -> dd.lines.getOrNull(lineIndex)?.episodes?.takeIf { it.isNotEmpty() } ?: dd.episodes }.orEmpty() }
    val picker = remember(seriesId) { EpisodePickerState() }
    LaunchedEffect(eps, epGroupSize) { picker.group = EpisodeGroups.ranges(eps.size, epGroupSize).indexOfFirst { resume != null && resume.episodeIndex in it }.coerceAtLeast(0) }
    val selectLine: (Int) -> Unit = { i ->
        lineIndex = i
        d?.lines?.getOrNull(i)?.let { lib.setPreferredLine(seriesId, it.id) }
    }
    // The episode 播放 will open is resolved while the page is read, so playback starts without a round trip. Only the
    // catalogue source: TVBox resolving may run scripts or a hidden page.
    LaunchedEffect(eps, resume?.episodeNumber) {
        if (eps.isEmpty() || !seriesId.all { it.isDigit() } || !IdjApp.instance.settings.prefetchEnabled) return@LaunchedEffect
        kotlinx.coroutines.delay(1_200)
        val ep = eps.firstOrNull { it.ep == resume?.episodeNumber } ?: eps.first()
        app.iduanju.ui.player.EpisodeCache.warm(ep, lib.preferredQuality(seriesId))
    }
    val scroll = rememberScrollState()
    LaunchedEffect(d) { if(d!=null && app.iduanju.BuildConfig.DEBUG && app.iduanju.ui.UiEvidence.scroll) { kotlinx.coroutines.delay(1200); scroll.scrollTo((scroll.maxValue*0.75).toInt()) } }
    val density = LocalDensity.current
    val pinThresholdPx = with(density) { 236.dp.toPx() }
    val pinned by remember(pinThresholdPx) { derivedStateOf { scroll.value > pinThresholdPx } }
    var actionsBottom by remember { mutableFloatStateOf(Float.MAX_VALUE) }
    val actionsThresholdPx = with(density) { 100.dp.toPx() }
    val actionsOut by remember(actionsThresholdPx) { derivedStateOf { actionsBottom < actionsThresholdPx } }
    val live = d?.isLive == true
    val startEp = (if (live && resume != null) eps.getOrNull(app.iduanju.core.tvbox.LiveKey(resume.episodeNumber, resume.episodeGroup, resume.episodeTitle).find(eps))?.ep else resume?.episodeNumber) ?: eps.firstOrNull()?.ep ?: 1
    // The player loads the list again: a channel goes there by name.
    val play: (String, Int) -> Unit = { s, ep ->
        if (live) eps.firstOrNull { it.ep == ep }?.let { app.iduanju.data.Catalog.rememberChannel(s, app.iduanju.core.tvbox.LiveKey(ep, it.page.orEmpty(), it.title)) }
        onPlay(s, ep)
    }
    val playTitle = when {
        live -> "观看直播"
        resume == null -> "开始播放"
        eps.size <= 1 -> "继续播放 " + clockText(resume.seconds)
        else -> "继续第 ${resume.episodeNumber} 集"
    }

    val useTwoPane = isTabletLandscape && d != null
    val usePortraitEditorial = !useTwoPane && isTabletPortrait && d != null
    val isTabletLayout = useTwoPane || usePortraitEditorial
    // Local backdrop of the page content: the floating back button and play bar are siblings drawn on top of it,
    // so they can sample real content (the root backdrop can't be used here: this page lives inside it).
    val bgColor = c.bg
    val pageBackdrop = com.kyant.backdrop.backdrops.rememberLayerBackdrop {
        drawRect(bgColor)
        drawContent()
    }
    Box(Modifier.fillMaxSize().background(c.bg), contentAlignment = Alignment.TopCenter) {
      Box(Modifier.fillMaxSize().then(Modifier.layerBackdrop(pageBackdrop)), contentAlignment = Alignment.TopCenter) {
        when {
            useTwoPane -> {
                val dd = d!!
                Row(
                    Modifier
                        .widthIn(max = 1160.dp)
                        .fillMaxSize()
                        .statusBarsPadding()
                        .navigationBarsPadding()
                        .padding(top = 56.dp, start = 28.dp, end = 28.dp, bottom = 24.dp),
                    horizontalArrangement = Arrangement.spacedBy(28.dp),
                ) {
                    Column(
                        Modifier
                            .width(340.dp)
                            .fillMaxHeight()
                            .verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        val total = episodeCountText(dd)
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .aspectRatio(3f / 4f)
                                .heightIn(max = 420.dp)
                                .shadow(18.dp, RoundedCornerShape(20.dp), ambientColor = Color.Black.copy(0.45f), spotColor = Color.Black.copy(0.45f)),
                        ) {
                            PosterArt(dd.cover, Modifier.fillMaxSize(), corner = 20.dp)
                        }
                        DSStatus(dd.source.ifEmpty { "红果短剧" }, StatusTone.Accent)
                        Text(dd.title, color = c.text, fontSize = 24.sp, fontWeight = FontWeight.ExtraBold, lineHeight = 30.sp)
                        val meta = listOfNotNull(if (dd.episodeLabel.isEmpty()) total else DS.spaced(dd.episodeLabel), dd.author.ifEmpty { null }).joinToString(" · ")
                        if (meta.isNotEmpty()) Text(meta, color = c.secondary, fontSize = 13.sp)
                        // Single primary Play + Favorite CTA for tablet landscape (not duplicated in right column).
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            PillButton(playTitle, Modifier.weight(1f), icon = Icons.Filled.PlayArrow, tone = PillTone.Play, enabled = eps.isNotEmpty()) { play(seriesId, startEp) }
                            Heart(seriesId, dd, 48.dp)
                        }
                    }
                    Column(
                        Modifier
                            .weight(1f)
                            .fillMaxHeight()
                            .verticalScroll(scroll)
                            .padding(bottom = 48.dp),
                    ) {
                        DetailBody(
                            d = dd,
                            sid = seriesId,
                            resume = resume,
                            eps = eps,
                            lineIndex = lineIndex,
                            onLine = selectLine,
                            picker = picker,
                            onPlay = play,
                            onOpenSeries = onOpenSeries,
                            playTitle = playTitle,
                            startEp = startEp,
                            onActions = { actionsBottom = it },
                            showActions = false,
                        )
                    }
                }
            }
            usePortraitEditorial -> {
                val dd = d!!
                Column(
                    Modifier
                        .fillMaxSize()
                        .verticalScroll(scroll)
                        .statusBarsPadding()
                        .navigationBarsPadding()
                        .padding(top = 56.dp, bottom = 48.dp),
                ) {
                    TabletPortraitHero(
                        d = dd,
                        sid = seriesId,
                        playTitle = playTitle,
                        startEp = startEp,
                        onPlay = play,
                    )
                    if (dd.desc.isNotEmpty()) {
                        Intro(dd.desc, horizontalPadding = 24.dp, topPadding = 22.dp, collapsedLines = 4)
                    }
                    EpisodeSection(
                        d = dd,
                        sid = seriesId,
                        resume = resume,
                        eps = eps,
                        lineIndex = lineIndex,
                        onLine = selectLine,
                        picker = picker,
                        onPlay = play,
                        inset = 24.dp,
                        epCols = 10,
                        groupSize = epGroupSize,
                    )
                    if (dd.relatedSeries.size > 1) {
                        RelatedShelf(dd.relatedSeries, dd.seriesId, onOpenSeries, inset = 24.dp, cardWidth = 128.dp)
                    }
                    if (dd.cast.isNotEmpty()) {
                        CastShelf(dd.cast, inset = 24.dp)
                    }
                }
            }
            else -> {
                Column(
                    Modifier
                        .then(if (metrics.detailMaxWidth != androidx.compose.ui.unit.Dp.Unspecified) Modifier.widthIn(max = metrics.detailMaxWidth) else Modifier)
                        .fillMaxSize()
                        .verticalScroll(scroll)
                        .navigationBarsPadding()
                        .padding(bottom = 110.dp),
                ) {
                    DetailHero(
                        d = d,
                        sid = seriesId,
                        coverHint = remember(seriesId) { app.iduanju.data.Catalog.peekCover(seriesId) },
                        titleHint = remember(seriesId) { app.iduanju.data.Catalog.peekTitle(seriesId) },
                    )
                    val dd = d
                    when {
                        dd != null -> DetailBody(dd, seriesId, resume, eps, lineIndex, selectLine, picker, play, onOpenSeries, playTitle, startEp) { actionsBottom = it }
                        err != null -> ErrorState(err!!, Modifier.padding(top = 12.dp)) { reload++ }
                        else -> Column(Modifier.padding(horizontal = 20.dp).padding(top = 18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            SkeletonBlock(Modifier.fillMaxWidth().height(66.dp), 16.dp)
                            repeat(3) { i -> SkeletonBlock(Modifier.fillMaxWidth(if (i == 2) 0.6f else 1f).height(16.dp), 4.dp) }
                        }
                    }
                }
            }
        }
      }
        // pinned nav (`.pin` + `.nav`)
        Box(Modifier.fillMaxWidth().dsPinned(pinned || useTwoPane)) {
            DSNavBar(d?.title ?: "", Modifier.statusBarsPadding().padding(bottom = 6.dp), titleAlpha = animateFloatAsState(if (pinned || useTwoPane) 1f else 0f, label = "t").value,
                leading = {
                    val onHero = !(pinned || isTabletLayout)
                    // over the hero: dark glass + white glyph; pinned / tablet: theme glass
                    GlassIconButton(
                        Icons.AutoMirrored.Rounded.ArrowBackIos, "返回",
                        backdrop = pageBackdrop, size = 36.dp, iconSize = 18.dp,
                        dark = if (onHero) true else c.dark, fallbackAlpha = if (onHero) 0.30f else 0.70f,
                        onClick = onBack,
                    )
                })
        }
        // floating play bar (`.playbar`) — phone layout only; tablets keep a single primary Play + Favorite CTA
        AnimatedVisibility(!isTabletLayout && eps.isNotEmpty() && actionsOut, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(horizontal = 16.dp).padding(bottom = 4.dp),
            enter = slideInVertically(DS.panel()) { it } + fadeIn(), exit = slideOutVertically(DS.panel()) { it } + fadeOut()) {
            Row(Modifier.fillMaxWidth().glassSurface(RoundedCornerShape(32.dp), backdrop = pageBackdrop, shadowRadius = 20.dp).padding(8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PillButton(playTitle, Modifier.weight(1f), icon = Icons.Filled.PlayArrow, tone = PillTone.Play) { play(seriesId, startEp) }
                d?.let { Heart(seriesId, it, 48.dp) }
            }
        }
    }
}

@Composable
private fun DetailHero(d: HGSeriesDetail?, sid: String, coverHint: String = "", titleHint: String = "") {
    val c = IdjThemeColors
    val coverUrl = d?.cover?.takeIf { it.isNotEmpty() } ?: coverHint
    val displayTitle = d?.title?.takeIf { it.isNotEmpty() } ?: titleHint
    Box(Modifier.fillMaxWidth().height(300.dp)) {
        // `.bd`: the poster itself, blurred once at decode; the card's cached cover stands in on frame 0.
        if (coverUrl.isNotEmpty()) {
            Box(Modifier.fillMaxSize().clipToBounds()) { BlurredCover(coverUrl, Modifier.fillMaxSize().scale(1.12f)) }
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to Color.Black.copy(0.30f), 0.34f to Color.Black.copy(0.08f), 0.76f to c.bg.copy(0.74f), 1f to c.bg)))
        }
        Row(Modifier.align(Alignment.BottomStart).padding(horizontal = 20.dp).padding(bottom = 2.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            val eps = d?.let(::episodeCountText)
            Box(Modifier.size(116.dp, 155.dp).shadow(15.dp, RoundedCornerShape(12.dp), ambientColor = Color.Black.copy(0.4f), spotColor = Color.Black.copy(0.4f))) {
                PosterArt(coverUrl, Modifier.fillMaxSize(), corner = 12.dp)
                if (eps != null) Text(eps, Modifier.align(Alignment.BottomCenter).padding(bottom = 8.dp), color = Color.White.copy(0.8f), fontSize = 10.sp)
            }
            Column(Modifier.weight(1f).padding(bottom = 2.dp)) {
                DSStatus(d?.source ?: "红果短剧", StatusTone.Accent)
                Text(displayTitle, color = c.text, fontSize = 23.sp, fontWeight = FontWeight.ExtraBold, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    lineHeight = 29.sp, modifier = Modifier.padding(top = 8.dp).copyOnLongPress(displayTitle))
                val meta = listOfNotNull(d?.let { if (it.episodeLabel.isEmpty()) eps else DS.spaced(it.episodeLabel) }, d?.author?.ifEmpty { null }).joinToString(" · ")
                Text(meta, color = c.secondary, fontSize = 13.sp, maxLines = 1, modifier = Modifier.padding(top = 6.dp))
            }
        }
    }
}

@Composable
private fun Heart(sid: String, d: HGSeriesDetail, size: androidx.compose.ui.unit.Dp) {
    val c = IdjThemeColors
    val lib = IdjApp.instance.library
    val fav = lib.isFavorite(sid)
    val s by animateFloatAsState(if (fav) 1f else 0.9f, DS.press(), label = "heart")
    Box(Modifier.size(size).clip(CircleShape).background(c.glass).border(1.dp, c.hairline, CircleShape)
        .pressClick(label = if (fav) "取消收藏" else "收藏") { lib.toggleFavorite(sid, d.title, d.cover) }, contentAlignment = Alignment.Center) {
        Icon(if (fav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, null, Modifier.size(22.dp).scale(s / 0.95f), tint = if (fav) c.accent else c.text)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TabletPortraitHero(
    d: HGSeriesDetail,
    sid: String,
    playTitle: String,
    startEp: Int,
    onPlay: (String, Int) -> Unit,
) {
    val c = IdjThemeColors
    val go = app.iduanju.ui.LocalNavigate.current
    val epsLabel = episodeCountText(d)
    val cardShape = RoundedCornerShape(24.dp)

    Box(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp)
            .clip(cardShape)
            .background(c.card)
            .border(1.dp, c.hairline, cardShape),
    ) {
        // Subtle blurred poster backdrop with directional scrim so text & CTA remain crisp.
        Box(Modifier.matchParentSize().clipToBounds()) {
            BlurredCover(d.cover, Modifier.fillMaxSize().scale(1.12f), alpha = if (c.dark) 0.36f else 0.16f)
            Box(
                Modifier
                    .fillMaxSize()
                    .background(
                        Brush.horizontalGradient(
                            0f to c.card.copy(alpha = 0.20f),
                            0.42f to c.card.copy(alpha = 0.76f),
                            1f to c.card.copy(alpha = 0.92f),
                        ),
                    ),
            )
        }

        Row(
            Modifier
                .fillMaxWidth()
                .padding(22.dp),
            horizontalArrangement = Arrangement.spacedBy(22.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .width(176.dp)
                    .aspectRatio(3f / 4f)
                    .shadow(16.dp, RoundedCornerShape(16.dp), ambientColor = Color.Black.copy(0.42f), spotColor = Color.Black.copy(0.42f)),
            ) {
                PosterArt(d.cover, Modifier.fillMaxSize(), corner = 16.dp)
            }

            Column(
                Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                    itemVerticalAlignment = Alignment.CenterVertically,
                ) {
                    DSStatus(d.source.ifEmpty { "红果短剧" }, StatusTone.Accent)
                    HeroStatChip(if (d.episodeLabel.isEmpty()) epsLabel else DS.spaced(d.episodeLabel))
                    if (d.favoriteCount > 0) HeroStatChip("${DS.count(d.favoriteCount)} 收藏")
                    if (d.rating > 0) HeroStatChip("★ ${String.format("%.1f", d.rating)}")
                    if (d.hotText.isNotEmpty()) HeroStatChip("热度 ${DS.spaced(d.hotText)}")
                    if (d.author.isNotEmpty()) HeroStatChip(d.author)
                }

                Text(
                    d.title,
                    color = c.text,
                    fontSize = 26.sp,
                    fontWeight = FontWeight.ExtraBold,
                    lineHeight = 32.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )

                if (d.tags.isNotEmpty()) {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        d.tags.forEach { t ->
                            Box(
                                Modifier
                                    .height(26.dp)
                                    .clip(CircleShape)
                                    .background(c.glass)
                                    .padding(horizontal = 10.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(t, color = c.secondary, fontSize = 12.sp, maxLines = 1)
                            }
                        }
                    }
                }

                if (d.cast.isNotEmpty()) {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                        itemVerticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("主演", color = c.secondary, fontSize = 12.sp)
                        d.cast.take(6).forEach { p ->
                            Row(
                                Modifier
                                    .height(28.dp)
                                    .clip(CircleShape)
                                    .background(c.glass)
                                    .border(0.6.dp, c.hairline, CircleShape)
                                    .clickable(enabled = p.id.isNotBlank() || p.name.isNotBlank()) {
                                        if (p.id.isNotBlank()) {
                                            go(
                                                "actor/${android.net.Uri.encode(p.id)}" +
                                                    "?name=${android.net.Uri.encode(p.name)}" +
                                                    "&avatar=${android.net.Uri.encode(p.avatar)}" +
                                                    "&role=${android.net.Uri.encode(p.role)}" +
                                                    "&intro=${android.net.Uri.encode(p.intro)}",
                                            )
                                        } else if (p.name.isNotBlank()) {
                                            go("actorSearch/${android.net.Uri.encode(p.name)}")
                                        }
                                    }
                                    .padding(start = 5.dp, end = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                Box(
                                    Modifier
                                        .size(18.dp)
                                        .clip(CircleShape)
                                        .background(Brush.linearGradient(listOf(c.accent.copy(0.6f), c.accentWarm.copy(0.6f)))),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Text(p.name.take(1), color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
                                    if (p.avatar.isNotEmpty()) AsyncImage(p.avatar, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                                }
                                Text(p.name, color = c.text, fontSize = 12.sp, maxLines = 1)
                            }
                        }
                    }
                } else {
                    val actors = d.actors.filter { it.isNotBlank() }
                    if (actors.isNotEmpty()) {
                        FlowRow(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                            itemVerticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("主演", color = c.secondary, fontSize = 12.sp)
                            actors.forEach { actorName ->
                                Box(
                                    Modifier
                                        .height(26.dp)
                                        .clip(CircleShape)
                                        .background(c.glass)
                                        .border(0.6.dp, c.hairline, CircleShape)
                                        .clickable { go("actorSearch/${android.net.Uri.encode(actorName)}") }
                                        .padding(horizontal = 10.dp),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Text(actorName, color = c.text, fontSize = 12.sp, maxLines = 1)
                                }
                            }
                        }
                    }
                }

                // Single primary Play + Favorite CTA for tablet portrait.
                Row(
                    Modifier.fillMaxWidth().padding(top = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    PillButton(
                        playTitle,
                        Modifier.weight(1f),
                        icon = Icons.Filled.PlayArrow,
                        tone = PillTone.Play,
                        height = 50.dp,
                        enabled = d.episodes.isNotEmpty(),
                    ) { onPlay(sid, startEp) }
                    Heart(sid, d, 50.dp)
                }
            }
        }
    }
}

@Composable
private fun HeroStatChip(text: String) {
    val c = IdjThemeColors
    Box(
        Modifier
            .height(24.dp)
            .clip(CircleShape)
            .background(c.glass)
            .border(0.6.dp, c.hairline, CircleShape)
            .padding(horizontal = 9.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = c.secondary, fontSize = 11.5.sp, fontWeight = FontWeight.Medium, maxLines = 1)
    }
}

@Composable
private fun DetailBody(
    d: HGSeriesDetail, sid: String, resume: app.iduanju.data.WatchProgress?, eps: List<HGEpisode>, lineIndex: Int, onLine: (Int) -> Unit, picker: EpisodePickerState,
    onPlay: (String, Int) -> Unit, onOpenSeries: (String) -> Unit, playTitle: String, startEp: Int,
    showActions: Boolean = true,
    onActions: (Float) -> Unit,
) {
    val c = IdjThemeColors
    val go = app.iduanju.ui.LocalNavigate.current
    Stats(d, Modifier.padding(top = 18.dp))
    if (showActions) {
        Row(Modifier.padding(horizontal = 20.dp).padding(top = 16.dp).onGloballyPositioned { onActions(it.boundsInRoot().bottom) },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            PillButton(playTitle, Modifier.weight(1f), icon = Icons.Filled.PlayArrow, tone = PillTone.Play, height = 50.dp, enabled = eps.isNotEmpty()) { onPlay(sid, startEp) }
            Heart(sid, d, 50.dp)
        }
    }
    if (d.tags.isNotEmpty()) {
        LazyRow(Modifier.padding(top = 16.dp), contentPadding = PaddingValues(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items(d.tags.distinct(), key = { it }) { t ->
                Box(Modifier.height(26.dp).clip(CircleShape).background(c.glass).padding(horizontal = 10.dp), contentAlignment = Alignment.Center) {
                    Text(t, color = c.secondary, fontSize = 12.sp)
                }
            }
        }
    }
    if (d.cast.isEmpty() && d.actors.isNotEmpty()) {
        val actors = d.actors.filter { it.isNotBlank() }
        if (actors.isNotEmpty()) {
            LazyRow(
                Modifier.padding(top = 12.dp),
                contentPadding = PaddingValues(horizontal = 20.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                item { Text("主演", color = c.secondary, fontSize = 12.sp) }
                items(actors.distinct(), key = { it }) { actorName ->
                    Box(
                        Modifier
                            .height(26.dp)
                            .clip(CircleShape)
                            .background(c.glass)
                            .border(0.6.dp, c.hairline, CircleShape)
                            .clickable { go("actorSearch/${android.net.Uri.encode(actorName)}") }
                            .padding(horizontal = 10.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(actorName, color = c.text, fontSize = 12.sp, maxLines = 1)
                    }
                }
            }
        }
    }
    if (d.desc.isNotEmpty()) Intro(d.desc)

    // 6 per row on phones, 8 on medium, 10 in the tablet-landscape two-pane body.
    val epCols = when (LocalLayoutMetrics.current.tier) { SizeTier.Compact -> 6; SizeTier.Medium -> 8; SizeTier.Expanded -> 10 }
    EpisodeSection(d, sid, resume, eps, lineIndex, onLine, picker, onPlay, inset = 20.dp, epCols = epCols, groupSize = 30)
    if (d.relatedSeries.size > 1) RelatedShelf(d.relatedSeries, d.seriesId, onOpenSeries)
    if (d.cast.isNotEmpty()) CastShelf(d.cast, inset = 20.dp)
}

/** Episode group and order of the page, kept while the line or the window changes. */
@Stable
private class EpisodePickerState {
    var group by mutableIntStateOf(0)
    var reversed by mutableStateOf(false)
    /** Live lists: the selected channel group. */
    var channelGroup by mutableStateOf<String?>(null)
}

/** 线路 chips (multi-line titles) → 选集 header with 正序 / 倒序 → 30-episode groups → grid. */
@Composable
private fun EpisodeSection(
    d: HGSeriesDetail,
    sid: String,
    resume: app.iduanju.data.WatchProgress?,
    eps: List<HGEpisode>,
    lineIndex: Int,
    onLine: (Int) -> Unit,
    picker: EpisodePickerState,
    onPlay: (String, Int) -> Unit,
    inset: Dp = 20.dp,
    epCols: Int = 6,
    groupSize: Int = 30,
) {
    if (d.isLive) { ChannelSection(eps, sid, resume, picker, onPlay, inset, epCols); return }
    if (d.lines.size > 1) {
        SectionHeader2("线路", "共 ${d.lines.size} 条", inset = inset, modifier = Modifier.padding(top = 22.dp))
        LazyRow(Modifier.padding(top = 12.dp), contentPadding = PaddingValues(horizontal = inset), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            itemsIndexed(d.lines, key = { i, l -> "$i:${l.id}" }) { i, l ->
                ToneChip(l.name.ifBlank { "线路 ${i + 1}" }, i == lineIndex, count = l.episodes.size, enabled = l.episodes.isNotEmpty()) { onLine(i) }
            }
        }
    }
    if (eps.isEmpty()) { EmptyState("暂无剧集", note = if (d.lines.size > 1) "可以换一条线路试试" else null); return }
    val textual = remember(eps) { !sid.all { it.isDigit() } && EpisodeNames.textual(eps) }
    val ranges = remember(eps.size, groupSize) { EpisodeGroups.ranges(eps.size, groupSize) }
    val g = picker.group.coerceIn(0, (ranges.size - 1).coerceAtLeast(0))
    SectionHeader2("选集", if (textual) "共 ${eps.size} 集" else "共 ${maxOf(if (d.lines.size > 1) 0 else d.totalEps, eps.size)} 集", inset = inset, modifier = Modifier.padding(top = 22.dp)) {
        if (eps.size > 1) MoreLink(if (picker.reversed) "倒序" else "正序", Icons.Rounded.SwapVert) { picker.reversed = !picker.reversed }
    }
    if (ranges.size > 1) {
        LazyRow(Modifier.padding(top = 12.dp), contentPadding = PaddingValues(horizontal = inset), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(ranges.size, key = { it }) { k ->
                val i = if (picker.reversed) ranges.size - 1 - k else k
                ToneChip(EpisodeGroups.label(ranges[i], eps), i == g, neutral = true, small = true) { picker.group = i }
            }
        }
    }
    val cells = remember(ranges, g, picker.reversed) { ranges.getOrNull(g)?.toList().orEmpty().let { if (picker.reversed) it.reversed() else it } }
    androidx.compose.animation.AnimatedContent(cells, label = "eps", transitionSpec = { fadeIn(DS.select()) togetherWith fadeOut(DS.select()) }) { list ->
        // The grid of the previous line may animate out with indices the new line does not have.
        EpisodeRows(eps, list.filter { it in eps.indices }, if (textual) textColumns(epCols) else epCols, resume?.episodeIndex, textual,
            Modifier.padding(horizontal = inset).padding(top = 12.dp)) { i -> onPlay(sid, eps[i].ep) }
    }
}

/** Live lists opened from 收藏 / 历史: groups and channels, straight into the player. */
@Composable
private fun ChannelSection(channels: List<HGEpisode>, sid: String, resume: app.iduanju.data.WatchProgress?, picker: EpisodePickerState, onPlay: (String, Int) -> Unit, inset: Dp, epCols: Int) {
    val groups = remember(channels) { channels.mapNotNull { it.page?.takeIf { p -> p.isNotBlank() } }.distinct() }
    val group = picker.channelGroup?.takeIf { it in groups } ?: resume?.let { channels.getOrNull(it.episodeIndex)?.page } ?: groups.firstOrNull()
    SectionHeader2("频道", "共 ${channels.size} 个", inset = inset, modifier = Modifier.padding(top = 22.dp))
    if (groups.size > 1) LazyRow(Modifier.padding(top = 12.dp), contentPadding = PaddingValues(horizontal = inset), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items(groups, key = { it }) { name -> ToneChip(name, name == group, neutral = true, small = true) { picker.channelGroup = name } }
    }
    // A group can hold hundreds of channels; the player has the full, searchable list.
    val shown = remember(channels, group) { channels.indices.filter { group == null || channels[it].page == group }.take(90) }
    EpisodeRows(channels, shown, textColumns(epCols), resume?.episodeIndex, textual = true, modifier = Modifier.padding(horizontal = inset).padding(top = 12.dp)) { i -> onPlay(sid, channels[i].ep) }
}

private fun episodeCountText(d: HGSeriesDetail): String = when {
    d.isLive -> "${d.episodes.size} 个频道"
    d.lines.size > 1 && d.episodes.size <= 1 -> "${d.lines.size} 条线路"
    else -> "全 ${maxOf(if (d.lines.size > 1) 0 else d.totalEps, d.episodes.size)} 集"
}

private fun clockText(seconds: Double): String {
    val s = seconds.toInt()
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

/** 复制剧名 (iOS context menu). */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun Modifier.copyOnLongPress(text: String): Modifier {
    if (text.isEmpty()) return this
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val haptics = rememberHaptics()
    return combinedClickable(remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, null, onLongClickLabel = "复制剧名", onLongClick = {
        ctx.getSystemService(android.content.ClipboardManager::class.java)?.setPrimaryClip(android.content.ClipData.newPlainText("title", text))
        haptics.longPress()
        GlassToast.show("已复制剧名")
    }, onClick = {})
}

@Composable
private fun CastShelf(cast: List<app.iduanju.core.hongguo.HGCelebrity>, inset: Dp = 20.dp) {
    val c = IdjThemeColors
    val go = app.iduanju.ui.LocalNavigate.current
    SectionHeader2("演员", inset = inset, modifier = Modifier.padding(top = 24.dp))
    LazyRow(Modifier.padding(top = 12.dp), contentPadding = PaddingValues(horizontal = inset), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        itemsIndexed(cast, key = { i, p -> "$i:${p.id}" }) { _, p ->
            Column(
                Modifier
                    .width(64.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .clickable(enabled = p.id.isNotBlank() || p.name.isNotBlank()) {
                        if (p.id.isNotBlank()) {
                            go(
                                "actor/${android.net.Uri.encode(p.id)}" +
                                    "?name=${android.net.Uri.encode(p.name)}" +
                                    "&avatar=${android.net.Uri.encode(p.avatar)}" +
                                    "&role=${android.net.Uri.encode(p.role)}" +
                                    "&intro=${android.net.Uri.encode(p.intro)}",
                            )
                        } else if (p.name.isNotBlank()) {
                            go("actorSearch/${android.net.Uri.encode(p.name)}")
                        }
                    },
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(Modifier.size(56.dp).clip(CircleShape).background(Brush.linearGradient(listOf(c.accent.copy(0.5f), c.accentWarm.copy(0.5f)))), contentAlignment = Alignment.Center) {
                    Text(p.name.take(1), color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                    if (p.avatar.isNotEmpty()) AsyncImage(p.avatar, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                }
                Text(p.name, color = c.text, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 6.dp))
                if (p.role.isNotEmpty()) Text(p.role, color = c.secondary, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun Stats(d: HGSeriesDetail, modifier: Modifier = Modifier) {
    val c = IdjThemeColors
    data class Cell(val icon: androidx.compose.ui.graphics.vector.ImageVector?, val value: String, val label: String)
    val cells = buildList {
        if (d.rating > 0) add(Cell(Icons.Filled.Star, String.format("%.1f", d.rating), "观众评分" + if (d.ratingCount.isEmpty()) "" else " · " + DS.spaced(d.ratingCount) + "人"))
        if (d.favoriteCount > 0) add(Cell(null, DS.count(d.favoriteCount), "收藏"))
        if (d.hotText.isNotEmpty()) add(Cell(Icons.Filled.LocalFireDepartment, DS.spaced(d.hotText), "全网热度"))
    }
    if (cells.isEmpty()) return
    // A sparse response occupies only its real columns; keep the spec's three-column metric density.
    BoxWithConstraints(modifier.padding(horizontal = 20.dp).fillMaxWidth()) {
      Row(Modifier.width(maxWidth * (cells.size.coerceAtMost(3) / 3f)).height(63.dp).dsCard(16.dp).padding(vertical = 11.dp)) {
        cells.forEachIndexed { i, cell ->
            if (i > 0) Box(Modifier.width(1.dp).fillMaxHeight().background(c.hairline))
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                Row(Modifier.height(22.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (cell.icon != null) Icon(cell.icon, null, Modifier.size(14.dp), tint = c.accentWarm)
                    Text(cell.value, color = c.text, fontSize = 17.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                }
                Text(cell.label, color = c.secondary, fontSize = 11.sp, maxLines = 1)
            }
        }
      }
    }
}

/** `.intro`: three lines, 展开 over a fade; tap toggles. */
@Composable
private fun Intro(
    text: String,
    horizontalPadding: Dp = 20.dp,
    topPadding: Dp = 14.dp,
    collapsedLines: Int = 3,
) {
    val c = IdjThemeColors
    var open by remember { mutableStateOf(false) }
    var clamped by remember { mutableStateOf(false) }
    Box(Modifier.padding(horizontal = horizontalPadding).padding(top = topPadding).fillMaxWidth().animateContentSize(DS.panel())
        .clickable(remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, null, enabled = clamped || open) { open = !open }) {
        Text(text, color = c.secondary, fontSize = 14.sp, lineHeight = 22.sp, maxLines = if (open) Int.MAX_VALUE else collapsedLines, overflow = TextOverflow.Clip,
            onTextLayout = { if (!open) clamped = it.hasVisualOverflow })
        if (clamped && !open) Text("展开", Modifier.align(Alignment.BottomEnd).background(Brush.horizontalGradient(0f to c.bg.copy(0f), 0.42f to c.bg)).padding(start = 36.dp),
            color = c.accent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, lineHeight = 22.sp)
    }
}

@Composable
fun SectionHeader(title: String, modifier: Modifier = Modifier, trailing: (@Composable () -> Unit)? = null) {
    val c = IdjThemeColors
    Row(modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = c.text, fontSize = 20.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.weight(1f))
        trailing?.invoke()
    }
}

@Composable
private fun RelatedShelf(
    items: List<HGSeries>,
    currentId: String,
    onOpen: (String) -> Unit,
    inset: Dp = 20.dp,
    cardWidth: Dp = 104.dp,
) {
    val c = IdjThemeColors
    val go = app.iduanju.ui.LocalNavigate.current
    val cardHeight = cardWidth * (4f / 3f)
    SectionHeader2("系列", "共 ${items.size} 季", inset = inset, modifier = Modifier.padding(top = 26.dp)) {
        MoreLink("搜全系列", Icons.Filled.Search) { go("actorSearch/" + android.net.Uri.encode(items.firstOrNull { it.seriesId == currentId }?.title ?: "")) }
    }
    LazyRow(Modifier.padding(top = 12.dp), contentPadding = PaddingValues(start = inset, end = inset, top = 4.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        items(items.distinctBy { it.seriesId }, key = { it.seriesId }) { s ->
            val on = s.seriesId == currentId
            Column(Modifier.width(cardWidth).pressClick(0.97f, enabled = !on, label = s.title) { onOpen(s.seriesId) }) {
                Box(Modifier.size(cardWidth, cardHeight).then(if (on) Modifier.border(2.dp, c.accent, RoundedCornerShape(16.dp)).padding(4.dp) else Modifier)) {
                    PosterArt(s.cover, Modifier.fillMaxSize(), corner = 12.dp)
                    if (on) Box(Modifier.padding(6.dp).height(18.dp).clip(RoundedCornerShape(5.dp)).background(c.accent).padding(horizontal = 6.dp), contentAlignment = Alignment.Center) {
                        Text("当前", color = c.onAccent, fontSize = 10.5.sp, fontWeight = FontWeight.Bold)
                    }
                }
                Text(s.title, color = c.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 8.dp))
                if (s.episodeCount > 0) Text("${s.episodeCount} 集", color = c.secondary, fontSize = 11.sp, maxLines = 1, modifier = Modifier.padding(top = 2.dp))
            }
        }
    }
}
