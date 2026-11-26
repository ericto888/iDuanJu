package app.iduanju.tvbox

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.iduanju.core.cms.CMSSite
import app.iduanju.core.hongguo.HGEpisode
import app.iduanju.core.hongguo.HGResolvedVideo
import app.iduanju.core.hongguo.HGSeriesDetail
import app.iduanju.core.tvbox.BridgeAuth
import app.iduanju.core.tvbox.BridgeHandler
import app.iduanju.core.tvbox.ConfigLoader
import app.iduanju.core.tvbox.DepotRecord
import app.iduanju.core.tvbox.LenientJson
import app.iduanju.core.tvbox.LiveParser
import app.iduanju.core.tvbox.LocalServer
import app.iduanju.core.tvbox.ParsedConfig
import app.iduanju.core.tvbox.Programme
import app.iduanju.core.tvbox.RepoRecord
import app.iduanju.core.tvbox.RepoRuntime
import app.iduanju.core.tvbox.ScriptHost
import app.iduanju.core.tvbox.ScriptStorage
import app.iduanju.core.tvbox.SpiderErrors
import app.iduanju.core.tvbox.TVBoxCache
import app.iduanju.core.tvbox.TVBoxConfig
import app.iduanju.core.tvbox.TVBoxDecoder
import app.iduanju.core.tvbox.TVBoxDepotEntry
import app.iduanju.core.tvbox.TVBoxDoh
import app.iduanju.core.tvbox.TVBoxEngine
import app.iduanju.core.tvbox.TVBoxId
import app.iduanju.core.tvbox.TVBoxLive
import app.iduanju.core.tvbox.TVBoxNet
import app.iduanju.core.tvbox.TVBoxPlatform
import app.iduanju.core.tvbox.TVBoxSite
import app.iduanju.core.tvbox.TVBoxState
import app.iduanju.core.tvbox.TVBoxUrl
import app.iduanju.core.tvbox.Trust
import app.iduanju.core.tvbox.LegacyWatch
import app.iduanju.core.util.ProviderException
import app.iduanju.tvbox.runtime.JarRuntime
import app.iduanju.tvbox.runtime.PyRuntime
import app.iduanju.tvbox.runtime.QuickJsTvEngine
import app.iduanju.tvbox.runtime.WebSniffer
import com.github.catvod.net.OkHttp
import com.github.catvod.utils.Util as CatUtil
import com.github.catvod.Init as CatInit
import com.github.catvod.Proxy as CatProxy
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** One imported config for the UI: what is persisted about it plus its parsed content. */
class TVBoxRepo private constructor(val record: RepoRecord, val config: TVBoxConfig, val error: String?, val sites: List<TVBoxSiteRef>, val lives: List<TVBoxLiveRef>) {
    constructor(record: RepoRecord, config: TVBoxConfig, error: String? = null) : this(
        record, config, error, config.sites.map { TVBoxSiteRef(TVBoxConfig.siteUid(record.id, it.key), it) }, config.lives.map { TVBoxLiveRef(TVBoxConfig.liveUid(record.id, it.identity), it) },
    )

    /** Same content, changed choices. */
    fun with(record: RepoRecord) = TVBoxRepo(record, config, error, sites, lives)

    val id get() = record.id
    val name get() = record.name
    val trusted get() = record.trust == Trust.Trusted
    val needsTrust get() = config.hasCode && record.trust == Trust.Ask
    /** Runs the imported file [name]. */
    fun refersTo(name: String) = (listOf(config.spider) + config.sites.flatMap { listOf(it.api, it.jar, it.ext) } + config.lives.flatMap { listOf(it.api, it.jar, it.ext) }).any { it.contains("://localhost/$name") || TVBoxUrl.isLocal(it) && it.contains("/$name") }
    fun enabled(uid: String) = uid !in record.disabled
}

data class TVBoxSiteRef(val uid: String, val site: TVBoxSite)
data class TVBoxLiveRef(val uid: String, val live: TVBoxLive)

sealed class ImportResult {
    data class Imported(val repo: TVBoxRepo) : ImportResult()
    /** The address is a list of configs: the user picks one. */
    data class Depot(val depot: DepotRecord, val nested: Boolean) : ImportResult()
    /** A jar / script / list saved for local configs to reference. */
    data class Attachment(val name: String) : ImportResult()
}

/**
 * Everything the app knows about TVBox: persisted configs and choices as Compose state (main thread), the engine that runs
 * them, and the LAN bridge. Files are read and written in the background only; importing never contacts the sites.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class TVBoxStore(private val ctx: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    /** Single writer: state files never interleave. */
    private val disk = Dispatchers.IO.limitedParallelism(1)
    private val root = File(ctx.filesDir, "tvbox")
    private val stateFile = File(ctx.filesDir, "tvbox_store_v2.json")
    private val localDir = File(root, "local")
    private val ready = CompletableDeferred<Unit>()

    private lateinit var engineRef: TVBoxEngine
    private val net = TVBoxNet(localDir) { engineRef.runningPort }
    private val loader = ConfigLoader(net)
    private val jar = JarRuntime(ctx.applicationContext)
    val engine: TVBoxEngine get() = engineRef

    var state by mutableStateOf(TVBoxState())
        private set
    var repos by mutableStateOf<List<TVBoxRepo>>(emptyList())
        private set
    /** False until the persisted configs have been read. */
    var loaded by mutableStateOf(false)
        private set
    /** Milliseconds per site uid (-1 = failed), filled while a speed test runs. */
    val latency = mutableStateMapOf<String, Int>()
    var bridgeAddress by mutableStateOf<String?>(null)
        private set
    var bridgeError by mutableStateOf<String?>(null)
        private set

    val activeRepo: TVBoxRepo? get() = repos.firstOrNull { it.id == state.active } ?: repos.firstOrNull()

    init {
        val storage = PrefsStorage(ctx)
        val sniffer = WebSniffer(ctx.applicationContext) { engineRef.runningPort }
        val assets = ctx.applicationContext.assets
        val platform = TVBoxPlatform(
            js = { QuickJsTvEngine() }, python = PyRuntime.create(ctx), jar = jar, sniffer = sniffer,
            jsAsset = { name -> runCatching { assets.open("tvbox/js/$name").use { it.readBytes().toString(Charsets.UTF_8) } }.getOrNull() },
            storage = storage, log = { android.util.Log.d("TVBox", it.take(1500)) },
        )
        engineRef = TVBoxEngine(net, platform, TVBoxCache(File(ctx.cacheDir, "tvbox")), File(root, "scripts"), File(ctx.cacheDir, "tvbox-epg"))
        CatInit.set(ctx)
        CatProxy.set(CatProxy.PortSource { engineRef.proxyPort })
        OkHttp.setClient { net.base }
        JarRuntime.guardBackgroundThreads()
        ChineseText.install()
        scope.launch { boot() }
    }

    // ------------------------------------------------------------------------------------------------------ start

    private suspend fun boot() {
        val (s, list, watches) = withContext(disk) { read() }
        state = s
        repos = list
        latency.putAll(s.latency)
        pushEngine()
        ready.complete(Unit)
        loaded = true
        if (watches.isNotEmpty()) importWatches(watches)
        if (s.bridgeOn) startBridge()
        // the site the user will most likely look at is warmed up off the main thread
        activeRepo?.let { r -> engine.preload(state.lastSite[r.id] ?: return@let) }
        withContext(Dispatchers.IO) { runCatching { engine.trimCaches() } }
    }

    private fun repoFile(id: String) = File(root, "repos/" + id.filter { it.isLetterOrDigit() || it == '-' || it == '_' } + ".json")

    private fun read(): Triple<TVBoxState, List<TVBoxRepo>, List<LegacyWatch>> {
        var watches = emptyList<LegacyWatch>()
        val s = try {
            if (stateFile.isFile) TVBoxState.fromJSON(JSONObject(stateFile.readText()))
            else {
                val v1 = File(ctx.filesDir, "tvbox_store_v1.json")
                val migrated = TVBoxState.migrateV1(if (v1.isFile) JSONObject(v1.readText()) else legacyCms())
                migrated.configs.forEach { (id, text) -> writeText(repoFile(id), text) }
                watches = migrated.watches
                if (migrated.state.repos.isNotEmpty()) { writeText(stateFile, migrated.state.toJSON().toString()); v1.renameTo(File(v1.path + ".migrated")) }
                migrated.state
            }
        } catch (e: Exception) {
            android.util.Log.w("TVBox", "state unreadable", e)
            if (stateFile.isFile) stateFile.renameTo(File(stateFile.path + ".bad"))
            TVBoxState()
        }
        return Triple(s, s.repos.map { parseRepo(it) }, watches)
    }

    /** Sites of even older builds lived among the 采集站. */
    private fun legacyCms(): JSONObject {
        val all = runCatching { JSONArray(ctx.getSharedPreferences("idj", Context.MODE_PRIVATE).getString("stv.cms.sites", "[]")) }.getOrDefault(JSONArray())
        val mine = (0 until all.length()).mapNotNull { all.optJSONObject(it) }.map(CMSSite::fromJSON).filter { it.origin.startsWith("TVBox", true) }
        if (mine.isEmpty()) return JSONObject()
        val sites = JSONArray(mine.map { JSONObject().put("key", it.key).put("name", it.name).put("api", it.api).put("adult", it.adult).put("enabled", it.enabled) })
        return JSONObject().put("activeRepoId", "legacy-tvbox").put("repos", JSONArray().put(JSONObject().put("id", "legacy-tvbox").put("name", "已导入 TVBox").put("url", "").put("sites", sites)))
    }

    private fun parseRepo(record: RepoRecord): TVBoxRepo = try {
        when (val p = TVBoxConfig.parse(repoFile(record.id).readText(), record.base)) {
            is ParsedConfig.Config -> TVBoxRepo(record, p.config)
            else -> TVBoxRepo(record, TVBoxConfig(), "配置内容已损坏，请刷新")
        }
    } catch (e: Exception) { TVBoxRepo(record, TVBoxConfig(), SpiderErrors.text(e)) }

    private fun importWatches(list: List<LegacyWatch>) {
        val lib = app.iduanju.IdjApp.instance.library
        list.sortedBy { it.updatedAt }.forEach { w ->
            if (lib.progress(w.sid) == null) lib.record(app.iduanju.data.WatchProgress(w.sid, w.title, w.cover, w.episodeIndex, w.episodeIndex + 1, w.positionMs / 1000.0, w.durationMs / 1000.0, w.updatedAt))
        }
    }

    // ------------------------------------------------------------------------------------------------------ persistence

    private fun writeText(f: File, text: String) {
        f.parentFile?.mkdirs()
        val tmp = File(f.path + ".tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(f)) { f.delete(); tmp.renameTo(f) }
    }

    private var pending: Job? = null

    /** Swaps the state; the file is written shortly after the last change. */
    private fun update(push: Boolean = false, change: (TVBoxState) -> TVBoxState) {
        val next = change(state)
        if (next == state) return
        state = next
        if (push) pushEngine()
        pending?.cancel()
        pending = scope.launch { delay(400); flush() }
    }

    private suspend fun flush() { val snap = state; withContext(disk) { runCatching { writeText(stateFile, snap.toJSON().toString()) } } }

    private fun pushEngine() {
        val s = state
        val doh = dohOptions().firstOrNull { it.name == s.doh }
        engine.setRepos(repos.map { r -> RepoRuntime(r.id, r.name, r.config, r.trusted, s.allowLan || TVBoxNet.isPrivateAddress(r.record.base), doh, r.record.parse, TVBoxUrl.isLocal(r.record.base)) }, activeRepo?.id.orEmpty(), s.aliases)
    }

    private fun replaceRecord(id: String, push: Boolean, change: (RepoRecord) -> RepoRecord) {
        val i = repos.indexOfFirst { it.id == id }
        if (i < 0) return
        val old = repos[i]
        val rec = change(old.record)
        if (rec == old.record) return
        repos = repos.toMutableList().also { it[i] = old.with(rec) }
        update(push) { s -> s.copy(repos = s.repos.map { if (it.id == id) rec else it }) }
    }

    // ------------------------------------------------------------------------------------------------------ import

    /** Address of a config, a depot or a channel list. [depot] is the list it was picked from. */
    suspend fun importUrl(raw: String, depot: DepotRecord? = null, nested: Boolean = false, name: String = ""): ImportResult {
        ready.await()
        val l = loader.load(raw, state.allowLan, dohOptions().firstOrNull { it.name == state.doh })
        return accept(l.parsed, l.text, l.url, name, depot, nested)
    }

    /** Pasted text: a config, a channel list, or just an address. */
    suspend fun importText(text: String, name: String = ""): ImportResult {
        ready.await()
        val t = text.trim()
        if (!t.contains('\n') && (TVBoxUrl.isHttp(t) || TVBoxUrl.isLocal(t))) return importUrl(t)
        return importLocal(t.toByteArray(), "paste-" + RepoRecord.id(t) + ".json", name.ifEmpty { "粘贴的配置" })
    }

    /** A picked file: configs and lists are imported, anything else is kept for local configs to reference as `./name`. */
    suspend fun importLocal(bytes: ByteArray, fileName: String, name: String = fileName.substringBeforeLast('.')): ImportResult {
        ready.await()
        val safe = fileName.replace(Regex("[\\\\/:*?\"<>|\\s]+"), "_").takeLast(80).ifEmpty { "config.json" }
        if (bytes.size > 48 shl 20) throw ProviderException.invalid("文件过大")
        val url = "clan://localhost/$safe"
        val file = File(localDir, safe)
        if (safe.substringAfterLast('.').lowercase() in ATTACHMENTS) {
            val changed = withContext(disk) { (file.isFile && !file.readBytes().contentEquals(bytes)).also { localDir.mkdirs(); file.writeBytes(bytes) } }
            // other code under the name a trusted config refers to: that trust was given to something else
            if (changed) {
                repos.filter { it.trusted && it.refersTo(safe) }.forEach { setTrust(it.id, Trust.Ask) }
                jar.invalidate()
            }
            return ImportResult.Attachment(safe)
        }
        // an earlier file of that name is only replaced by something that can be read
        val (text, parsed) = withContext(Dispatchers.Default) { runCatching { TVBoxDecoder.decode(bytes) }.getOrDefault("").let { it to TVBoxConfig.parse(it, url) } }
        withContext(disk) { localDir.mkdirs(); file.writeBytes(bytes) }
        return accept(parsed, text, url, name, null, false)
    }

    private suspend fun accept(parsed: ParsedConfig, text: String, url: String, name: String, depot: DepotRecord?, nested: Boolean): ImportResult = when (parsed) {
        is ParsedConfig.Depot -> {
            if (nested) throw ProviderException.unsupported("多仓嵌套过深")
            val d = DepotRecord(RepoRecord.id(url), name.ifEmpty { TVBoxUrl.host(url).ifEmpty { "多仓" } }, url, parsed.entries)
            if (depot == null) update { s -> s.copy(depots = s.depots.filterNot { it.id == d.id } + d) }
            ImportResult.Depot(d, depot != null)
        }
        is ParsedConfig.Live -> {
            val groups = withContext(Dispatchers.Default) { LiveParser.parse(text).groups }
            if (groups.isEmpty()) throw ProviderException.invalid("没有识别到频道")
            val title = name.ifEmpty { TVBoxUrl.fileName(url).substringBeforeLast('.').ifEmpty { TVBoxUrl.host(url) } }.ifEmpty { "直播源" }
            store(JSONObject().put("lives", JSONArray().put(JSONObject().put("name", title).put("url", url))).toString(), url, title, depot)
        }
        is ParsedConfig.Config -> store(text, url, name.ifEmpty { parsed.config.name }.ifEmpty { TVBoxUrl.host(url) }.ifEmpty { "TVBox 配置" }, depot)
    }

    private suspend fun store(text: String, url: String, title: String, depot: DepotRecord?): ImportResult {
        val id = RepoRecord.id(url)
        val old = repos.firstOrNull { it.id == id }
        var record = (old?.record ?: RepoRecord(id, title.take(60), url)).copy(url = url, depot = depot?.id ?: old?.record?.depot.orEmpty(), updatedAt = System.currentTimeMillis())
        val changed = withContext(disk) { (runCatching { repoFile(id).readText() }.getOrNull() != text).also { writeText(repoFile(id), text) } }
        // a file of the same name is another config: what the user trusted was the old one
        if (changed && TVBoxUrl.isLocal(url) && record.trust == Trust.Trusted) record = record.copy(trust = Trust.Ask)
        var repo = withContext(Dispatchers.Default) { parseRepo(record) }
        val alias = if (record.legacy.isEmpty()) emptyMap() else TVBoxState.aliases(record, repo.config)
        if (record.legacy.isNotEmpty()) {
            // first refresh of a migrated config: keep what the user had switched off under the sites' real ids
            record = record.copy(legacy = emptyMap(), disabled = record.disabled.map { alias[it] ?: it }.toSet())
            repo = repo.with(record)
        }
        repos = listOf(repo) + repos.filterNot { it.id == id }
        update { s -> s.copy(repos = listOf(record) + s.repos.filterNot { it.id == id }, active = id, aliases = s.aliases + alias) }
        jar.invalidate()
        pushEngine()
        return ImportResult.Imported(repo)
    }

    /** Re-reads a config from where it came from. */
    suspend fun refresh(id: String): ImportResult {
        val r = repos.firstOrNull { it.id == id } ?: throw ProviderException.invalid("配置不存在")
        if (r.record.url.isEmpty()) throw ProviderException.invalid("这个配置没有来源地址")
        val keepActive = state.active
        val result = importUrl(r.record.url, state.depots.firstOrNull { it.id == r.record.depot }, name = r.name)
        if (keepActive.isNotEmpty()) select(keepActive)
        withContext(Dispatchers.IO) {
            engine.restart(id)
            r.sites.forEach { engine.clearCache(it.uid) }
            r.lives.forEach { engine.clearCache("live-" + it.uid) }
        }
        return result
    }

    suspend fun openDepot(d: DepotRecord, e: TVBoxDepotEntry, nested: Boolean): ImportResult = importUrl(e.url, d, nested, e.name)

    fun select(id: String) { if (repos.any { it.id == id }) update(push = true) { it.copy(active = id) } }

    fun rename(id: String, name: String) { val n = name.trim().take(60); if (n.isNotEmpty()) replaceRecord(id, push = true) { it.copy(name = n) } }

    fun remove(id: String) {
        val gone = repos.firstOrNull { it.id == id } ?: return
        repos = repos.filterNot { it.id == id }
        update { s ->
            val left = s.repos.filterNot { it.id == id }
            s.copy(repos = left, active = if (s.active == id) left.firstOrNull()?.id.orEmpty() else s.active, lastSite = s.lastSite - id, lastLive = s.lastLive - id, depots = s.depots.filter { d -> left.any { it.depot == d.id } || d.id != gone.record.depot })
        }
        pushEngine()
        scope.launch(disk) {
            repoFile(id).delete()
            if (gone.record.url.startsWith("clan://")) net.localFile(gone.record.url)?.delete()
            gone.sites.forEach { engine.clearCache(it.uid) }
            gone.lives.forEach { engine.clearCache("live-" + it.uid) }
        }
    }

    fun removeDepot(id: String) = update { s -> s.copy(depots = s.depots.filterNot { it.id == id }) }

    // ------------------------------------------------------------------------------------------------------ choices

    fun setTrust(id: String, t: Trust) = replaceRecord(id, push = true) { it.copy(trust = t) }
    fun setEnabled(repoId: String, uid: String, on: Boolean) = replaceRecord(repoId, push = false) { it.copy(disabled = if (on) it.disabled - uid else it.disabled + uid) }
    fun setAllEnabled(repoId: String, uids: Collection<String>, on: Boolean) = replaceRecord(repoId, push = false) { it.copy(disabled = if (on) it.disabled - uids.toSet() else it.disabled + uids) }
    fun setParse(repoId: String, name: String) = replaceRecord(repoId, push = true) { it.copy(parse = name) }
    fun setAllowLan(on: Boolean) = update(push = true) { it.copy(allowLan = on) }
    fun setDoh(name: String) = update(push = true) { it.copy(doh = name) }
    fun setLastSite(repoId: String, uid: String) = update { it.copy(lastSite = it.lastSite + (repoId to uid)) }
    fun setLastLive(repoId: String, uid: String) = update { it.copy(lastLive = it.lastLive + (repoId to uid)) }
    fun isFavorite(channel: String) = channel in state.favorites
    fun toggleFavorite(channel: String) = update { s -> s.copy(favorites = if (channel in s.favorites) s.favorites - channel else listOf(channel) + s.favorites) }
    fun unlocked(liveUid: String): Set<String> = state.unlocked[liveUid].orEmpty()
    fun unlock(liveUid: String, group: String) = update { it.copy(unlocked = it.unlocked + (liveUid to (it.unlocked[liveUid].orEmpty() + group))) }

    /** Built-in resolvers plus the ones the active config suggests. */
    fun dohOptions(): List<TVBoxDoh> = (BUILTIN_DOH + activeRepo?.config?.doh.orEmpty()).distinctBy { it.name }

    /** Sites the pickers show: enabled, not hidden by the config, adult ones only behind the gate. */
    fun visibleSites(repo: TVBoxRepo, adult: Boolean): List<TVBoxSiteRef> = repo.sites.filter { repo.enabled(it.uid) && !it.site.hide && (adult || !it.site.adult) }
    fun visibleLives(repo: TVBoxRepo): List<TVBoxLiveRef> = repo.lives.filter { repo.enabled(it.uid) }

    private var speed: Job? = null
    private var speedRun = 0
    var testing by mutableStateOf(false)
        private set

    fun testSpeed(uids: List<String>) {
        speed?.cancel()
        uids.forEach { latency.remove(it) }
        testing = true
        val run = ++speedRun
        speed = scope.launch {
            try { engine.latencies(uids).collect { (uid, ms) -> latency[uid] = ms.toInt() } } finally {
                // a cancelled test ends after the next one has begun
                if (run == speedRun) testing = false
                val snap = latency.toMap()
                update { it.copy(latency = snap) }
            }
        }
    }

    fun stopSpeedTest() { speed?.cancel() }

    // ------------------------------------------------------------------------------------------------------ catalog (blocking, IO threads)

    private fun awaitReady() { if (!ready.isCompleted) runBlocking { ready.await() } }

    private fun gate(sid: String) {
        val v = TVBoxId.parseVod(sid) ?: return
        val site = engine.site(v.uid)?.site ?: return
        if (site.adult && !app.iduanju.IdjApp.instance.cms.adultUnlocked) throw ProviderException.unsupported("成人站点已隐藏")
    }

    /** `tvb:` / `tvl:` detail for [app.iduanju.data.Catalog]. */
    fun detail(sid: String): HGSeriesDetail {
        awaitReady()
        gate(sid)
        if (TVBoxId.isLive(sid)) return runBlocking { val uid = TVBoxId.liveUid(sid); engine.liveDetail(uid, unlocked(uid)) }
        val v = TVBoxId.parseVod(sid) ?: throw ProviderException.invalid("TVBox 条目编号无效")
        return runBlocking { engine.detail(v.uid, v.id) }
    }

    fun resolve(ep: HGEpisode): HGResolvedVideo {
        awaitReady()
        gate(ep.vid)
        return runBlocking { if (TVBoxId.isLive(ep.vid)) engine.resolveLive(ep, unlocked(TVBoxId.liveUid(ep.vid))) else engine.resolve(ep) }
    }

    /** Programmes of the channel behind a live episode ([at]: any moment of the wanted day). */
    suspend fun guide(ep: HGEpisode, at: Long = System.currentTimeMillis()): List<Programme> {
        ready.await()
        val o = ep.media?.let { LenientJson.objectOrNull(it) }
        return try { engine.guide(TVBoxId.liveUid(ep.vid), ep.title, o?.optString("tvgId").orEmpty(), o?.optString("tvgName").orEmpty(), at) } catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }
    }

    /** 回看 streams of a past programme; null when the channel has no catch-up. */
    fun catchup(ep: HGEpisode, p: Programme): HGResolvedVideo? = engine.catchup(ep, p)

    // ------------------------------------------------------------------------------------------------------ bridge

    private var bridge: LocalServer? = null

    fun setBridge(on: Boolean) {
        update { it.copy(bridgeOn = on, bridgeCode = it.bridgeCode.ifEmpty { BridgeAuth.newCode() }) }
        if (on) startBridge() else stopBridge()
    }

    /** Old pairings stop working at once. */
    fun renewBridgeCode() = update { it.copy(bridgeCode = BridgeAuth.newCode()) }

    private fun startBridge() {
        stopBridge()
        val handler = BridgeHandler(BridgeAuth({ state.bridgeCode }), engine)
        val server = LocalServer("tvbox-bridge", false, listOf(BRIDGE_PORT)) { handler.handle(it) }
        bridge = server
        scope.launch {
            val port = withContext(Dispatchers.IO) { server.start() }
            if (bridge !== server) { server.stop(); return@launch }
            val ip = withContext(Dispatchers.IO) { CatUtil.getIp() }
            if (port == 0) { bridgeError = "端口 $BRIDGE_PORT 被占用"; bridgeAddress = null } else { bridgeError = if (ip == "127.0.0.1") "没有连接局域网" else null; bridgeAddress = "$ip:$port" }
        }
    }

    private fun stopBridge() {
        bridge?.let { b -> scope.launch(Dispatchers.IO) { b.stop() } }
        bridge = null
        bridgeAddress = null
        bridgeError = null
    }

    companion object {
        const val BRIDGE_PORT = 9979
        private val ATTACHMENTS = setOf("jar", "js", "py", "dex", "png", "jpg", "jpeg", "gif", "zip")
        private val BUILTIN_DOH = listOf(
            TVBoxDoh("阿里 DNS", "https://dns.alidns.com/dns-query", listOf("223.5.5.5", "223.6.6.6")),
            TVBoxDoh("腾讯 DNS", "https://doh.pub/dns-query", listOf("1.12.12.12", "120.53.53.53")),
        )
    }
}

/** `local.*` of script spiders. */
private class PrefsStorage(ctx: Context) : ScriptStorage {
    private val sp by lazy { ctx.applicationContext.getSharedPreferences("tvbox_script", Context.MODE_PRIVATE) }
    override fun get(ns: String, k: String): String? = sp.getString("$ns\u0001$k", null)
    override fun set(ns: String, k: String, v: String) { if (v.length <= 512 * 1024) sp.edit().putString("$ns\u0001$k", v).apply() }
    override fun delete(ns: String, k: String) { sp.edit().remove("$ns\u0001$k").apply() }
}

/** Simplified / traditional conversion from the system ICU (API 29+; older systems leave the text as it is). */
private object ChineseText {
    fun install() {
        if (android.os.Build.VERSION.SDK_INT < 29) return
        val s2t by lazy { android.icu.text.Transliterator.getInstance("Simplified-Traditional") }
        val t2s by lazy { android.icu.text.Transliterator.getInstance("Traditional-Simplified") }
        ScriptHost.s2t = { synchronized(this) { s2t.transliterate(it) } }
        ScriptHost.t2s = { synchronized(this) { t2s.transliterate(it) } }
    }
}
