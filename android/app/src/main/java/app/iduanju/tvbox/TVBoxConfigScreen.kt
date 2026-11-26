package app.iduanju.tvbox

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.IdjApp
import app.iduanju.core.tvbox.DepotRecord
import app.iduanju.core.tvbox.SiteKind
import app.iduanju.core.tvbox.TVBoxDepotEntry
import app.iduanju.core.tvbox.TVBoxNet
import app.iduanju.core.tvbox.TVBoxUrl
import app.iduanju.core.tvbox.Trust
import app.iduanju.core.util.ProviderException
import app.iduanju.tvbox.runtime.PyRuntime
import app.iduanju.ui.components.BackButton
import app.iduanju.ui.components.CapsuleButton
import app.iduanju.ui.components.ChipRow
import app.iduanju.ui.components.DSNavBar
import app.iduanju.ui.components.DSPage
import app.iduanju.ui.components.DSStatus
import app.iduanju.ui.components.MiniButton
import app.iduanju.ui.components.PillButton
import app.iduanju.ui.components.PillTone
import app.iduanju.ui.components.StatusTone
import app.iduanju.ui.theme.IdjThemeColors
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Extra air above a section; rows inside a list stay close together. */
private val Section = Modifier.padding(top = 12.dp)

private class DepotPick(val depot: DepotRecord, /** The persisted depot entries belong to (nested lists are not kept). */ val owner: DepotRecord, val nested: Boolean)

/** TVBox 配置: import, configs and depots, trust, sites and live sources of the active config, network policy, LAN bridge. */
@Composable
fun TVBoxConfigScreen(onBack: () -> Unit) {
    val c = IdjThemeColors
    val store = IdjApp.instance.tvbox
    val ctx = LocalContext.current
    val focus = LocalFocusManager.current
    val scope = rememberCoroutineScope()
    val repo = store.activeRepo
    var url by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<Pair<String, Boolean>?>(null) }
    var pasting by remember { mutableStateOf(false) }
    var depot by remember { mutableStateOf<DepotPick?>(null) }
    var asking by remember { mutableStateOf<TVBoxRepo?>(null) }
    var menu by remember { mutableStateOf<TVBoxRepo?>(null) }
    var renaming by remember { mutableStateOf<TVBoxRepo?>(null) }
    var removing by remember { mutableStateOf<TVBoxRepo?>(null) }
    var choosing by remember { mutableStateOf<String?>(null) } // parse | doh
    var tab by remember { mutableStateOf("点播站点") }
    var query by remember { mutableStateOf("") }
    val adult = IdjApp.instance.cms.adultUnlocked
    val shown = remember(repo?.sites, adult, query) {
        val q = query.trim()
        repo?.sites.orEmpty().filter { (adult || !it.site.adult) && !it.site.hide && (q.isEmpty() || it.site.name.contains(q, true) || it.site.api.contains(q, true)) }
    }

    fun run(what: String, work: suspend () -> ImportResult, owner: DepotRecord? = null) {
        if (busy != null) return
        busy = what
        notice = null
        scope.launch {
            try {
                when (val r = work()) {
                    is ImportResult.Imported -> {
                        url = ""; pasting = false; depot = null
                        notice = "已导入「${r.repo.name}」：${r.repo.sites.size} 个站点 · ${r.repo.lives.size} 个直播源" to false
                        if (r.repo.needsTrust) asking = r.repo
                    }
                    is ImportResult.Depot -> { url = ""; pasting = false; depot = DepotPick(r.depot, owner ?: r.depot, r.nested) }
                    is ImportResult.Attachment -> { pasting = false; notice = "已保存 ${r.name}，本地配置可以用 ./${r.name} 引用它" to false }
                }
            } catch (e: CancellationException) { throw e } catch (e: Exception) { notice = errorText(e) to true } finally { busy = null }
        }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) run("正在读取文件…", { val (name, bytes) = withContext(Dispatchers.IO) { readFile(ctx, uri) }; store.importLocal(bytes, name) })
    }

    DSPage {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            DSNavBar("TVBox 配置", leading = { BackButton(onClick = onBack) })
            LazyColumn(Modifier.fillMaxSize().imePadding(), contentPadding = PaddingValues(top = 8.dp, bottom = 48.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                item(key = "import") {
                    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        val submit = { if (url.isNotBlank()) { focus.clearFocus(); run("正在获取配置…", { store.importUrl(url) }) } }
                        TvField(url, { url = it }, "配置、多仓或直播列表地址", icon = Icons.Rounded.Link, ime = ImeAction.Go, keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri), onAction = submit) {
                            PillButton(if (busy != null) "…" else "导入", small = true, enabled = busy == null && url.isNotBlank(), onClick = submit)
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            CapsuleButton("粘贴内容", Icons.Rounded.ContentPaste) { pasting = true }
                            CapsuleButton("本地文件", Icons.Rounded.Description) { picker.launch(arrayOf("*/*")) }
                        }
                        busy?.let { Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) { TvSpinner(14); Text(it, color = c.secondary, fontSize = 13.sp) } }
                        notice?.let { (text, bad) -> Text(text, color = if (bad) c.accentWarm else c.secondary, fontSize = 13.sp, lineHeight = 19.sp) }
                    }
                }
                if (store.state.depots.isNotEmpty()) item(key = "depots") {
                    TvGroup("多仓", modifier = Section) {
                        store.state.depots.forEachIndexed { i, d ->
                            if (i > 0) TvDivider()
                            TvRow(d.name, "${d.entries.size} 个配置 · ${TVBoxUrl.host(d.url)}", onClick = { depot = DepotPick(d, d, false) }) {
                                MiniButton("更新") { run("正在更新多仓…", { store.importUrl(d.url, name = d.name) }) }
                                if (store.repos.none { it.record.depot == d.id }) MiniButton("移除") { store.removeDepot(d.id) }
                            }
                        }
                    }
                }
                if (store.repos.isNotEmpty()) item(key = "repos") {
                    TvGroup("配置", "点按切换，更多里可以刷新、改名、更改信任或删除。", Section) {
                        store.repos.forEachIndexed { i, r ->
                            if (i > 0) TvDivider()
                            TvRow(r.name, r.error ?: "${r.sites.size} 站点 · ${r.lives.size} 直播 · ${date(r.record.updatedAt)}", selected = r.id == repo?.id, warn = r.error != null, onClick = { store.select(r.id) }) {
                                if (r.config.hasCode) DSStatus(if (r.trusted) "已信任" else "未信任", if (r.trusted) StatusTone.Ok else StatusTone.Warn)
                                Icon(Icons.Rounded.MoreHoriz, "更多", Modifier.size(32.dp).clip(CircleShape).clickable { menu = r }.padding(6.dp), tint = c.secondary)
                            }
                        }
                    }
                } else if (store.loaded) item(key = "none") { TvEmpty("还没有配置", "支持明文、Base64 / AES 加密、多仓、HTTP 与 IP 地址；导入只下载配置本身，不会逐个验证站点。") }

                if (repo != null) {
                    if (repo.config.notice.isNotBlank()) item(key = "notice") { TvGroup("公告", modifier = Section) { Text(repo.config.notice, color = c.secondary, fontSize = 13.sp, lineHeight = 19.sp, modifier = Modifier.padding(14.dp)) } }
                    item(key = "active") {
                        TvGroup("当前配置 · ${repo.name}", modifier = Section) {
                            if (repo.config.hasCode) {
                                TvRow("信任这个配置", if (PyRuntime.INCLUDED || repo.sites.none { it.site.kind == SiteKind.Py }) "允许运行其中的 JAR / JS / Python 站点" else "允许运行其中的 JAR / JS 站点（此版本未包含 Python 运行时）") {
                                    TvSwitch(repo.trusted, "信任这个配置") { on -> if (on) asking = repo else store.setTrust(repo.id, Trust.Denied) }
                                }
                                TvDivider()
                            }
                            TvRow("默认解析", repo.record.parse.ifEmpty { if (repo.config.parses.isEmpty()) "配置没有解析，使用网页嗅探" else "自动（超级解析）" }, onClick = if (repo.config.parses.isEmpty()) null else ({ choosing = "parse" }))
                        }
                    }
                    item(key = "tabs") {
                        Column(Section.padding(bottom = 2.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            ChipRow(listOf("点播站点", "直播源"), tab, { if (it == "点播站点") "点播站点 ${repo.sites.size}" else "直播源 ${repo.lives.size}" }, { tab = it })
                            if (tab == "点播站点" && repo.sites.isNotEmpty()) Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                TvSearchField(query, { query = it }, "搜索站点", Modifier.weight(1f))
                                CapsuleButton(if (store.testing) "停止" else "测速", Icons.Rounded.Speed) {
                                    if (store.testing) store.stopSpeedTest() else store.testSpeed(store.visibleSites(repo, IdjApp.instance.cms.adultUnlocked).filter { !it.site.kind.isCode || repo.trusted }.map { it.uid })
                                }
                            }
                        }
                    }
                    if (tab == "点播站点") {
                        items(shown, key = { "s" + it.uid }, contentType = { "site" }) { s ->
                            Box(Modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(c.card)) {
                                TvRow(s.site.name, s.site.api, leading = { KindBadge(s.site.kind) }) {
                                    store.latency[s.uid]?.let { ms -> DSStatus(if (ms < 0) "失败" else "$ms ms", if (ms < 0) StatusTone.Muted else if (ms < 1500) StatusTone.Ok else StatusTone.Warn) }
                                    TvSwitch(repo.enabled(s.uid), s.site.name) { store.setEnabled(repo.id, s.uid, it) }
                                }
                            }
                        }
                    } else items(repo.lives, key = { "l" + it.uid }, contentType = { "live" }) { l ->
                        Box(Modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(c.card)) {
                            TvRow(l.live.name, l.live.url.ifEmpty { l.live.api.ifEmpty { "配置内置" } }, leading = { l.live.kind?.let { KindBadge(it) } }) { TvSwitch(repo.enabled(l.uid), l.live.name) { store.setEnabled(repo.id, l.uid, it) } }
                        }
                    }
                }
                item(key = "net") {
                    TvGroup("网络", "默认只允许访问公网地址；配置本身来自局域网时，它也可以访问局域网里的资源。本机端口始终只开放给应用自己的代理。", Section) {
                        TvRow("允许访问局域网", "家里的 NAS、局域网播放源需要打开") { TvSwitch(store.state.allowLan, "允许访问局域网") { store.setAllowLan(it) } }
                        TvDivider()
                        TvRow("安全 DNS", store.state.doh.ifEmpty { "系统默认" }, onClick = { choosing = "doh" })
                    }
                }
                item(key = "bridge") { BridgeGroup(store) }
            }
        }
    }

    if (pasting) {
        var text by remember { mutableStateOf("") }
        TvDialog("粘贴内容", if (busy != null) "正在解析…" else "导入", { run("正在解析…", { store.importText(text) }) }, { pasting = false }, enabled = busy == null && text.isNotBlank()) {
            TvField(text, { text = it }, "配置 JSON、M3U / TXT 频道列表或地址", singleLine = false, minHeight = 140, modifier = Modifier.heightIn(max = 280.dp))
            notice?.takeIf { it.second }?.let { Text(it.first, color = c.accentWarm, fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp)) }
        }
    }
    depot?.let { pick ->
        TvSheet(pick.depot.name, { depot = null }) {
            busy?.let { Row(Modifier.padding(horizontal = 20.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) { TvSpinner(14); Text(it, color = c.secondary, fontSize = 13.sp) } }
            notice?.takeIf { it.second }?.let { Text(it.first, color = c.accentWarm, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp)) }
            LazyColumn(Modifier.weight(1f, fill = false)) {
                items(pick.depot.entries, key = { it.url }) { e: TVBoxDepotEntry ->
                    TvRow(e.name, e.url, selected = repo?.record?.url == e.url, onClick = { run("正在获取「${e.name}」…", { store.openDepot(pick.owner, e, pick.nested) }, pick.owner) })
                }
            }
        }
    }
    asking?.let { r -> TrustDialog(r, { ok -> asking = null; store.setTrust(r.id, if (ok) Trust.Trusted else Trust.Denied) }, { asking = null; if (r.record.trust == Trust.Ask) store.setTrust(r.id, Trust.Denied) }) }
    menu?.let { r ->
        TvSheet(r.name, { menu = null }) {
            if (r.record.url.isNotEmpty()) TvRow("刷新", "重新获取配置，站点的缓存一并更新", leading = { Icon(Icons.Rounded.Refresh, null, Modifier.size(20.dp), tint = c.secondary) }, onClick = { menu = null; run("正在刷新…", { store.refresh(r.id) }) })
            TvRow("重命名", onClick = { menu = null; renaming = r })
            if (r.config.hasCode) TvRow(if (r.trusted) "取消信任" else "信任", if (r.trusted) "它的代码站点将停止运行" else null, onClick = { menu = null; if (r.trusted) store.setTrust(r.id, Trust.Denied) else asking = r })
            if (r.record.url.isNotEmpty()) TvRow("地址", r.record.url)
            TvRow("删除", warn = true, onClick = { menu = null; removing = r })
        }
    }
    renaming?.let { r ->
        var name by remember(r.id) { mutableStateOf(r.name) }
        TvDialog("重命名", "保存", { store.rename(r.id, name); renaming = null }, { renaming = null }, enabled = name.isNotBlank()) { TvField(name, { name = it }, "配置名称", onAction = { store.rename(r.id, name); renaming = null }) }
    }
    removing?.let { r -> TvDialog("删除「${r.name}」？", "删除", { store.remove(r.id); removing = null }, { removing = null }, tone = PillTone.Ink) { TvText("站点、直播源和它们的缓存会一起移除，观看记录保留。") } }
    when (choosing) {
        "parse" -> repo?.let { r ->
            TvSheet("默认解析", { choosing = null }) {
                LazyColumn(Modifier.weight(1f, fill = false)) {
                    item { TvRow("自动（超级解析）", "JSON 解析与网页嗅探同时进行，先到先用", selected = r.record.parse.isEmpty(), onClick = { store.setParse(r.id, ""); choosing = null }) }
                    items(r.config.parses, key = { it.name }) { p -> TvRow(p.name, when (p.type) { 0 -> "网页嗅探"; 1 -> "JSON"; 2, 3 -> "JAR 扩展"; else -> "超级解析" }, selected = r.record.parse == p.name, onClick = { store.setParse(r.id, p.name); choosing = null }) }
                }
            }
        }
        "doh" -> TvSheet("安全 DNS", { choosing = null }) {
            TvRow("系统默认", selected = store.state.doh.isEmpty(), onClick = { store.setDoh(""); choosing = null })
            store.dohOptions().forEach { d -> TvRow(d.name, d.url, selected = store.state.doh == d.name, onClick = { store.setDoh(d.name); choosing = null }) }
        }
    }
}

@Composable
private fun BridgeGroup(store: TVBoxStore) {
    val c = IdjThemeColors
    TvGroup("局域网桥接", "让同一局域网里的 iPhone / iPad 借用这台设备运行已信任配置里的 JAR 站点。默认关闭；每个请求都要用配对码签名，只执行这台设备上已导入并信任的 JAR。", Section) {
        TvRow("开启桥接", store.bridgeError ?: store.bridgeAddress?.let { "正在监听 $it" }, warn = store.bridgeError != null) { TvSwitch(store.state.bridgeOn, "开启桥接") { store.setBridge(it) } }
        if (store.state.bridgeOn) {
            TvDivider()
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("配对码", color = c.secondary, fontSize = 12.sp)
                    Text(store.state.bridgeCode, color = c.text, fontSize = 24.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                MiniButton("更换") { store.renewBridgeCode() }
            }
        }
    }
}

private fun date(at: Long) = if (at <= 0) "未更新" else SimpleDateFormat("MM-dd HH:mm", Locale.CHINA).format(Date(at))

private fun readFile(ctx: Context, uri: Uri): Pair<String, ByteArray> {
    val name = ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null } ?: "config.json"
    val bytes = ctx.contentResolver.openInputStream(uri)?.use { TVBoxNet.capped(it, 48 shl 20) } ?: throw ProviderException.invalid("无法读取文件")
    return name to bytes
}
