package app.iduanju.tg

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.IdjApp
import app.iduanju.core.tg.*
import app.iduanju.ui.components.*
import app.iduanju.ui.home.ReportScrolled
import app.iduanju.ui.components.SoftBlur
import app.iduanju.ui.home.rootBottomInset
import app.iduanju.ui.theme.IdjThemeColors
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.*

/** The merged feed with its block verdicts. */
@Immutable
private class TGFeed(val entries: List<TGPost>, val verdicts: Map<String, TGVerdict>, val total: Int, val blocked: Int, val ready: Boolean)

/** Last result per filter: coming back from the player shows the same posts at the same scroll position at once. */
private object TGFeedCache {
    var key = ""
    var feed = TGFeed(emptyList(), emptyMap(), 0, 0, false)
}

private fun buildFeed(store: TGStore, only: String?, adult: Boolean): TGFeed {
    val all = store.feed(only, adult)
    val verdicts = all.associate { it.id to store.verdict(it) }
    val blocked = all.count { verdicts[it.id]?.blocked == true }
    val entries = if (store.mode == TGFilterMode.hide) all.filter { verdicts[it.id]?.blocked != true } else all
    return TGFeed(entries, verdicts, all.size, blocked, true)
}

/** Sorting and the block rules (regexes, unicode folding) run off the main thread on a consistent snapshot. */
@Composable
private fun rememberFeed(store: TGStore, only: String?, adult: Boolean): State<TGFeed> {
    val key = "$only|$adult"
    val initial = remember { if (TGFeedCache.key == key) TGFeedCache.feed else TGFeed(emptyList(), emptyMap(), 0, 0, false) }
    return produceState(initial, store, only, adult) {
        snapshotFlow { listOf(store.visible(adult).map { it.id to store.posts[it.id] }, store.rules.toList(), store.heuristics, store.mode) }.collectLatest {
            val next = withContext(Dispatchers.Default) {
                val snap = Snapshot.takeSnapshot()
                try { snap.enter { buildFeed(store, only, adult) } } finally { snap.dispose() }
            }
            TGFeedCache.key = key
            TGFeedCache.feed = next
            value = next
        }
    }
}

/** 「频道」 home page: merged newest-first feed of subscribed public channels (iOS ChannelFeedView, embedded). */
@Composable
fun ChannelFeedPage(onPlay: (String) -> Unit) {
    val c = IdjThemeColors
    val app = IdjApp.instance
    val store = app.tg
    val adult = app.cms.adultUnlocked
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var only by rememberSaveable { mutableStateOf<String?>(null) }
    val open: (String) -> Unit = remember(ctx) {
        { u -> runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(u)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } }
    }
    val feed by rememberFeed(store, only, adult)
    var manage by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    val expanded = remember { mutableStateListOf<String>() }
    var suggestFor by remember { mutableStateOf<TGPost?>(null) }
    val list = rememberLazyListState()
    ReportScrolled(list)
    LaunchedEffect(Unit) { if (store.visible(adult).all { store.posts[it.id].isNullOrEmpty() }) store.refresh(null, adult) }
    val onMedia: (TGPost, Int) -> Unit = { p, i ->
        val m = p.media[i]
        if (m.kind == TGMedia.Kind.photo) open(m.link.ifEmpty { p.permalink })
        else if (m.video != null) onPlay(TGVideo.sid(p, i))
        else { GlassToast.show("视频过大，网页预览不提供直链，请在 Telegram 中打开", long = true); open(m.link.ifEmpty { p.permalink }) }
    }

    GlassPullToRefresh(refreshing, { if (!refreshing) scope.launch { refreshing = true; try { store.refresh(only, adult) } finally { refreshing = false } } }, Modifier.fillMaxSize()) {
        LazyColumn(Modifier.fillMaxSize(), list, contentPadding = PaddingValues(bottom = rootBottomInset() + 16.dp)) {
            item("bar", "bar") {
                Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(if (store.loading.isEmpty()) "${feed.total} 条 · 已屏蔽 ${feed.blocked}" else "刷新中…", color = c.secondary, fontSize = 12.sp)
                    Spacer(Modifier.weight(1f))
                    PlainIconButton(Icons.Filled.Tune, "频道与屏蔽规则") { manage = true }
                    PlainIconButton(Icons.Filled.Refresh, "刷新") { scope.launch { store.refresh(only, adult) } }
                }
            }
            item("chips", "chips") {
                LazyRow(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    item("all", "chip") { OptionChip("全部", only == null, minHeight = 34.dp) { only = null } }
                    items(store.visible(adult), key = { it.id }, contentType = { "chip" }) { ch -> OptionChip(ch.displayName, only == ch.id, minHeight = 34.dp) { only = ch.id } }
                }
            }
            items(store.visible(adult).filter { (only == null || it.id == only) && store.errors[it.id] != null }, key = { "err" + it.id }, contentType = { "error" }) { ch ->
                Row(Modifier.padding(horizontal = 16.dp).padding(bottom = 8.dp).fillMaxWidth().dsCard(14.dp).padding(start = 12.dp, top = 12.dp, end = 12.dp, bottom = 2.dp)) {
                    Icon(Icons.Rounded.Warning, null, tint = c.accentWarm, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(8.dp))
                    Column {
                        Text(ch.displayName + if (ch.subscribers.isEmpty()) "" else " · " + ch.subscribers, color = c.text, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        Text(store.errors[ch.id].orEmpty(), color = c.secondary, fontSize = 12.sp, lineHeight = 16.sp, modifier = Modifier.padding(top = 4.dp))
                        GlassTextButton("在 Telegram 中打开", Modifier.offset(x = (-12).dp), fontSize = 12.sp, fontWeight = FontWeight.SemiBold) { open("https://t.me/${ch.username}") }
                    }
                }
            }
            if (store.visible(adult).isEmpty()) item("empty", "state") { EmptySubs(store) { scope.launch { store.refresh(null, adult) } } }
            else if (feed.entries.isEmpty()) {
                if (store.loading.isNotEmpty() || !feed.ready) items(3, key = { "skeleton$it" }, contentType = { "skeleton" }) { PostSkeleton() }
                else item("wait", "state") {
                    Text("下拉刷新，或点右上角 ↻", color = c.secondary, fontSize = 15.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(top = 60.dp))
                }
            }
            items(feed.entries, key = { it.id }, contentType = { if (feed.verdicts[it.id]?.blocked == true && it.id !in expanded) "folded" else "post" }) { p ->
                val v = feed.verdicts[p.id]
                if (v?.blocked == true && p.id !in expanded) {
                    FoldedRow(store.channel(p.channel)?.displayName ?: "@${p.channel}", v.reason) { expanded.add(p.id) }
                    return@items
                }
                Column {
                    PostCard(p, store.channel(p.channel), v?.blocked == true, open, onMedia) { suggestFor = p }
                    Hairline(Modifier.padding(start = 66.dp))
                }
            }
            if (feed.entries.isNotEmpty() && store.hasMore(only, adult)) item("more", "more") {
                LaunchedEffect(feed.entries.size) { store.loadMore(only, adult) }
                Box(Modifier.fillMaxWidth().padding(20.dp), contentAlignment = Alignment.Center) { GlassSpinner(size = 24.dp) }
            }
        }
    }
    if (manage) TGManageSheet(store, adult, onDismiss = { manage = false }) { scope.launch { store.refresh(null, adult) } }
    suggestFor?.let { p -> TGSuggestSheet(store, p, onDismiss = { suggestFor = null }) }
}

/** iOS folded row: 「已屏蔽 · 频道」 reason … 展开. */
@Composable
private fun FoldedRow(name: String, reason: String, onExpand: () -> Unit) {
    val c = IdjThemeColors
    Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp).fillMaxWidth().pressClick(0.98f, onClick = onExpand).dsCard(12.dp).heightIn(min = 40.dp).padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(Icons.Outlined.VisibilityOff, null, tint = c.secondary, modifier = Modifier.size(15.dp))
        Text("已屏蔽 · $name", color = c.secondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        Text(reason, color = c.secondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Text("展开", color = c.secondary, fontSize = 12.sp)
    }
}

@Composable
private fun PostSkeleton() = Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
    SkeletonBlock(Modifier.size(40.dp), 20.dp)
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SkeletonBlock(Modifier.fillMaxWidth(0.4f).height(14.dp), 4.dp)
        SkeletonBlock(Modifier.fillMaxWidth().height(12.dp), 4.dp)
        SkeletonBlock(Modifier.fillMaxWidth(0.8f).height(12.dp), 4.dp)
        SkeletonBlock(Modifier.fillMaxWidth().aspectRatio(16f / 9), 8.dp)
    }
}

/** Plain group on the sheet glass (caption, well, footer). */
@Composable
private fun SheetGroup(title: String, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    val c = IdjThemeColors
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, color = c.secondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 4.dp).semantics { heading() })
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(c.glass).padding(horizontal = 12.dp, vertical = 8.dp), content = content)
        if (footer != null) Text(footer, color = c.secondary, fontSize = 12.sp, lineHeight = 17.sp, modifier = Modifier.padding(horizontal = 4.dp))
    }
}

/** iOS TGSheets: subscribed channels (add/remove) + blocklist rules (kind, pattern, toggle, delete), ad heuristics, hide/fold, import/export. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun TGManageSheet(store: TGStore, adult: Boolean, onDismiss: () -> Unit, onChanged: () -> Unit) {
    val c = IdjThemeColors
    val clip = LocalClipboardManager.current
    var ch by remember { mutableStateOf("") }
    var pat by remember { mutableStateOf("") }
    var kind by remember { mutableStateOf(TGRule.Kind.keyword) }
    var note by remember { mutableStateOf<String?>(null) }
    val subscribe = { if (store.add(ch) != null) { ch = ""; note = null; onChanged() } else note = "无效的频道名" }
    val addRule = {
        if (kind == TGRule.Kind.regex && runCatching { Regex(pat) }.isFailure) note = "正则无效" else { store.addRule(TGRule(kind, pat.trim())); pat = ""; note = "已添加" }
    }
    GlassBottomSheet(onDismiss, title = "频道管理", doneText = "完成") {
        LazyColumn(Modifier.fillMaxWidth(), contentPadding = PaddingValues(top = 6.dp, bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            item("add", "group") {
                SheetGroup("添加公开频道", footer = "通过 t.me/s/<频道> 网页预览读取，无需登录。") {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        GlassTextField(ch, { ch = it }, Modifier.weight(1f), placeholder = "频道用户名 / t.me 链接",
                            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { subscribe() }))
                        GlassButton("订阅", tone = ButtonTone.Tinted, size = ButtonSize.Small, enabled = ch.isNotBlank()) { subscribe() }
                    }
                }
            }
            val visible = store.visible(adult)
            if (visible.isNotEmpty()) item("channels", "group") {
                SheetGroup("已订阅（${visible.size}）") {
                    visible.forEachIndexed { i, x ->
                        if (i > 0) Hairline()
                        Row(Modifier.heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f).padding(vertical = 4.dp)) {
                                Text(x.displayName, color = c.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text("@${x.username}" + if (x.subscribers.isNotEmpty()) " · ${x.subscribers}" else "", color = c.secondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            GlassTextButton("退订", color = c.danger, fontSize = 14.sp) { store.remove(x.id) }
                        }
                    }
                }
            }
            item("filter", "group") {
                SheetGroup("屏蔽规则", footer = "内置识别：#广告/#推广 等标记、博彩/引流类词、外链按钮、纯推广链接（短文 + 外链/邀请链接）、置顶推广。") {
                    Text("屏蔽方式", color = c.text, fontSize = 15.sp, modifier = Modifier.padding(start = 4.dp, top = 4.dp, bottom = 8.dp))
                    GlassSegments(TGFilterMode.entries.map { it.label to it }, store.mode, { store.chooseMode(it) })
                    ToggleRow("内置广告识别", store.heuristics, { store.enableHeuristics(it) }, note = "广告标记 / 推广词 / 外链按钮")
                }
            }
            item("addRule", "group") {
                SheetGroup("添加规则") {
                    Spacer(Modifier.height(4.dp))
                    GlassSegments(TGRule.Kind.entries.map { it.label to it }, kind, { kind = it })
                    Row(Modifier.padding(top = 8.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        GlassTextField(pat, { pat = it }, Modifier.weight(1f),
                            placeholder = when (kind) { TGRule.Kind.keyword -> "关键词"; TGRule.Kind.regex -> "正则表达式"; TGRule.Kind.domain -> "example.com" },
                            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { if (pat.isNotBlank()) addRule() }))
                        GlassButton("添加", tone = ButtonTone.Tinted, size = ButtonSize.Small, enabled = pat.isNotBlank()) { addRule() }
                    }
                }
            }
            if (store.rules.isNotEmpty()) item("rules", "group") {
                SheetGroup("规则（${store.rules.size}）") {
                    store.rules.forEachIndexed { i, r ->
                        if (i > 0) Hairline()
                        key(r.id) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                GlassCheckbox(r.enabled, { store.toggleRule(r.id) }, label = r.pattern)
                                Column(Modifier.weight(1f).padding(vertical = 6.dp)) {
                                    Text(r.pattern, color = if (r.enabled) c.text else c.secondary, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text("${r.kind.label} · ${r.channel?.let { "@$it" } ?: "全部频道"}", color = c.secondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                                PlainIconButton(Icons.Outlined.Delete, "删除", tint = c.danger, iconSize = 20.dp) { store.removeRule(r.id) }
                            }
                        }
                    }
                }
            }
            item("io", "group") {
                SheetGroup("导入 / 导出") {
                    Row {
                        GlassTextButton("导出到剪贴板", fontSize = 14.sp) { clip.setText(AnnotatedString(store.export())); note = "已复制 ${store.rules.size} 条规则" }
                        GlassTextButton("从剪贴板导入", fontSize = 14.sp) { val n = store.import(clip.getText()?.text ?: ""); note = if (n > 0) "已导入 $n 条" else "剪贴板里没有可导入的规则" }
                    }
                }
            }
            note?.let { n -> item("note", "note") { Text(n, color = c.accent, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 4.dp)) } }
        }
    }
}

/** iOS TGBlockSheet 「加入屏蔽」: pick suggested words / domains, add a custom one, optionally for this channel only. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun TGSuggestSheet(store: TGStore, p: TGPost, onDismiss: () -> Unit) {
    val c = IdjThemeColors
    val sug = remember(p.id) { TGFilter.suggestions(p) }
    val picked = remember(p.id) { mutableStateListOf<Int>() }
    var custom by remember(p.id) { mutableStateOf("") }
    var channelOnly by remember(p.id) { mutableStateOf(false) }
    val ready = picked.isNotEmpty() || custom.isNotBlank()
    GlassBottomSheet(onDismiss, title = "加入屏蔽", doneText = if (ready) "添加" else null, scroll = true, onDone = {
        val ch = p.channel.lowercase().takeIf { channelOnly }
        val rules = picked.map { sug[it] } + TGFilter.importRules(custom)?.rules.orEmpty()
        rules.forEach { store.addRule(it.copy(channel = ch)) }
        if (rules.isNotEmpty()) GlassToast.show("已屏蔽 " + rules.take(2).joinToString("、") { "${it.kind.label}：${it.pattern}" })
        onDismiss()
    }, leading = { GlassTextButton("取消", color = c.text, fontSize = 16.sp, onClick = onDismiss) }) {
        Column(Modifier.padding(top = 6.dp, bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            SheetGroup("从这条消息提取") {
                if (sug.isEmpty()) Text("没有可提取的词或链接", color = c.secondary, fontSize = 14.sp, modifier = Modifier.padding(vertical = 8.dp))
                sug.forEachIndexed { i, r ->
                    CheckRow(r.pattern, i in picked, { if (it) picked.add(i) else picked.remove(i) }, note = r.kind.label)
                }
            }
            SheetGroup("自定义关键词") {
                GlassTextField(custom, { custom = it }, placeholder = "关键词（以 re: 开头为正则，domain: 为域名）")
            }
            SheetGroup("范围") { ToggleRow("只对 @${p.channel} 生效", channelOnly, { channelOnly = it }) }
        }
    }
}

@Composable
private fun EmptySubs(store: TGStore, onAdded: () -> Unit) {
    val c = IdjThemeColors
    var text by remember { mutableStateOf("") }
    var bad by remember { mutableStateOf(false) }
    val add = { if (store.add(text) != null) { text = ""; onAdded() } else bad = true }
    Column(Modifier.fillMaxWidth().padding(top = 50.dp, start = 30.dp, end = 30.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        IconWell(Icons.AutoMirrored.Filled.Send, 56.dp)
        Text("还没有订阅频道", color = c.text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        Text("输入公开频道用户名或链接，例如 telegram、t.me/durov", color = c.secondary, fontSize = 12.sp, textAlign = TextAlign.Center)
        Row(Modifier.widthIn(max = 420.dp), verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            GlassTextField(text, { text = it; bad = false }, Modifier.weight(1f), placeholder = "频道用户名 / 链接", capsule = true, minHeight = 42.dp, error = if (bad) "无效的频道名" else null,
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { add() }))
            GlassButton("订阅", onClick = { add() })
        }
    }
}

// Formatting happens on the main thread only.
private val SameYear = SimpleDateFormat("M月d日 HH:mm", Locale.CHINA)
private val OtherYear = SimpleDateFormat("yyyy年M月d日", Locale.CHINA)
private fun fmtDate(sec: Long): String {
    if (sec <= 0) return ""
    val d = System.currentTimeMillis() / 1000 - sec
    return when {
        d < 60 -> "刚刚"; d < 3600 -> "${d / 60} 分钟前"; d < 86400 -> "${d / 3600} 小时前"
        else -> {
            val sameYear = Calendar.getInstance().get(Calendar.YEAR) == Calendar.getInstance().apply { timeInMillis = sec * 1000 }.get(Calendar.YEAR)
            (if (sameYear) SameYear else OtherYear).format(Date(sec * 1000))
        }
    }
}

private val URL_RE = Regex("https?://[^\\s]+")
/** iOS NSDataDetector links: tappable URLs in post text. */
private fun linkify(t: String, accent: Color) = androidx.compose.ui.text.buildAnnotatedString {
    var i = 0
    for (m in URL_RE.findAll(t)) {
        append(t.substring(i, m.range.first))
        pushLink(androidx.compose.ui.text.LinkAnnotation.Url(m.value, androidx.compose.ui.text.TextLinkStyles(androidx.compose.ui.text.SpanStyle(color = accent)))); append(m.value); pop()
        i = m.range.last + 1
    }
    append(t.substring(i))
}

private fun clock(s: Int) = if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)

/** iOS TGPostCard: avatar · name, text (8 lines + 全文), 朋友圈 media grid, link preview, buttons, footer. */
@Composable
private fun PostCard(p: TGPost, ch: TGChannel?, blocked: Boolean, open: (String) -> Unit, onMedia: (TGPost, Int) -> Unit, onBlock: () -> Unit) {
    val c = IdjThemeColors
    var expanded by rememberSaveable(p.id) { mutableStateOf(false) }
    val name = ch?.displayName ?: "@${p.channel}"
    val date = remember(p.date) { fmtDate(p.date) }
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 4.dp)) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(c.glass), contentAlignment = Alignment.Center) {
            if (!ch?.avatar.isNullOrEmpty()) AsyncImage(ch!!.avatar, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            else Text(name.take(1), color = c.text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.heightIn(min = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(name, color = c.accent, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                if (ch?.isAdult == true) Text("18+", color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 6.dp).clip(CircleShape).background(c.danger).padding(horizontal = 4.dp))
                if (blocked) Text("已屏蔽", color = c.secondary, fontSize = 11.sp, modifier = Modifier.padding(start = 6.dp))
            }
            if (p.forwardedFrom.isNotEmpty()) Text("转发自 ${p.forwardedFrom}", color = c.secondary, fontSize = 12.sp)
            if (p.text.isNotEmpty()) {
                val body = remember(p.text, c.accent) { linkify(p.text, c.accent) }
                val long = remember(p.text) { p.text.length > 260 || p.text.count { it == '\n' } > 7 }
                Text(body, color = c.text, fontSize = 17.sp, lineHeight = 23.sp, maxLines = if (expanded) Int.MAX_VALUE else 8, overflow = TextOverflow.Ellipsis)
                if (!expanded && long) Text("全文", color = c.accent, fontSize = 15.sp, modifier = Modifier.pressClick { expanded = true })
            }
            if (p.media.isNotEmpty()) MediaGrid(p, onMedia)
            p.preview?.takeIf { it.title.isNotEmpty() || it.desc.isNotEmpty() }?.let { lp ->
                Row(Modifier.fillMaxWidth().pressClick(0.98f) { open(lp.url) }.clip(RoundedCornerShape(8.dp)).background(c.glass).padding(8.dp).height(IntrinsicSize.Min)) {
                    Box(Modifier.width(3.dp).fillMaxHeight().background(c.accent)); Spacer(Modifier.width(8.dp))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        if (lp.site.isNotEmpty()) Text(lp.site, color = c.accent, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        if (lp.title.isNotEmpty()) Text(lp.title, color = c.text, fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        if (lp.desc.isNotEmpty()) Text(lp.desc, color = c.secondary, fontSize = 12.sp, lineHeight = 16.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    }
                    if (lp.image.isNotEmpty()) AsyncImage(lp.image, null, Modifier.padding(start = 8.dp).size(54.dp).clip(RoundedCornerShape(6.dp)), contentScale = ContentScale.Crop)
                }
            }
            p.buttons.forEach { b ->
                Box(Modifier.fillMaxWidth().pressClick(0.98f) { open(b.url) }.clip(RoundedCornerShape(8.dp)).background(c.glass).heightIn(min = 40.dp).padding(horizontal = 10.dp, vertical = 8.dp),
                    contentAlignment = Alignment.Center) { Text(b.text, color = c.text, fontSize = 15.sp, textAlign = TextAlign.Center) }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(date, color = c.secondary, fontSize = 12.sp)
                if (p.views.isNotEmpty()) Row(Modifier.padding(start = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.Visibility, null, tint = c.secondary, modifier = Modifier.size(14.dp)); Spacer(Modifier.width(3.dp)); Text(p.views, color = c.secondary, fontSize = 12.sp)
                }
                Spacer(Modifier.weight(1f))
                PostMenu(p, open, onBlock)
                PlainIconButton(Icons.AutoMirrored.Filled.Send, "在 Telegram 中打开", tint = c.secondary, iconSize = 18.dp) { open(p.permalink) }
            }
        }
    }
}

/** iOS context menu of a post: 加入屏蔽… / 复制链接 / 复制文字 / 在 Telegram 中打开. */
@Composable
private fun PostMenu(p: TGPost, open: (String) -> Unit, onBlock: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        PlainIconButton(Icons.Filled.MoreHoriz, "更多", tint = IdjThemeColors.secondary, iconSize = 20.dp) { menu = true }
        if (menu) {
            val clip = LocalClipboardManager.current
            GlassMenu(true, { menu = false }) {
                GlassMenuItem("加入屏蔽…", icon = Icons.Outlined.PanTool) { menu = false; onBlock() }
                GlassMenuItem("复制链接", icon = Icons.Outlined.Link) { menu = false; clip.setText(AnnotatedString(p.permalink)) }
                if (p.text.isNotEmpty()) GlassMenuItem("复制文字", icon = Icons.Outlined.ContentCopy) { menu = false; clip.setText(AnnotatedString(p.text)) }
                GlassMenuItem("在 Telegram 中打开", icon = Icons.AutoMirrored.Filled.Send) { menu = false; open(p.permalink) }
            }
        }
    }
}

/** 1 item full width; 2–4 two columns; 5+ three columns. */
@Composable
private fun MediaGrid(p: TGPost, onMedia: (TGPost, Int) -> Unit) {
    val m = p.media
    if (m.size == 1) { Cell(m[0], Modifier.fillMaxWidth().aspectRatio(if (m[0].kind == TGMedia.Kind.photo) 4f / 3 else 16f / 9)) { onMedia(p, 0) }; return }
    val cols = if (m.size <= 4) 2 else 3
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        m.indices.chunked(cols).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                row.forEach { i -> Cell(m[i], Modifier.weight(1f).aspectRatio(1f)) { onMedia(p, i) } }
                repeat(cols - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

@Composable
private fun Cell(it: TGMedia, mod: Modifier, onClick: () -> Unit) {
    val ctx = LocalContext.current
    // Spoilers are decoded tiny and blurred once (works on every Android version, no RenderEffect per item).
    val model = remember(it.thumb, it.spoiler) {
        if (it.spoiler) ImageRequest.Builder(ctx).data(it.thumb).size(28, 28).transformations(SoftBlur(3)).memoryCacheKey("spoiler:${it.thumb}").build() else it.thumb
    }
    val isVideo = it.kind != TGMedia.Kind.photo
    Box(mod.pressClick(0.98f, label = if (!isVideo) "图片" else if (it.video == null) "在 Telegram 中打开视频" else "播放视频", onClick = onClick)
        .clip(RoundedCornerShape(8.dp)).background(IdjThemeColors.glass), contentAlignment = Alignment.Center) {
        AsyncImage(model, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        if (isVideo) {
            Icon(if (it.video == null) Icons.AutoMirrored.Filled.Send else Icons.Filled.PlayCircle, null, tint = Color.White.copy(0.9f), modifier = Modifier.size(44.dp))
            if (it.duration > 0) Text(clock(it.duration), color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.align(Alignment.BottomEnd).padding(6.dp).clip(CircleShape).background(Color.Black.copy(0.55f)).padding(horizontal = 5.dp, vertical = 2.dp))
        }
    }
}
