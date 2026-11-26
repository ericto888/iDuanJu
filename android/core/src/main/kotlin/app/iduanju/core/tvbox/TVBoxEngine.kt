package app.iduanju.core.tvbox

import app.iduanju.core.hongguo.HGEpisode
import app.iduanju.core.hongguo.HGResolvedVideo
import app.iduanju.core.hongguo.HGSeriesDetail
import app.iduanju.core.hongguo.HGStream
import app.iduanju.core.hongguo.HGStreamKind
import app.iduanju.core.hongguo.HGSubtitle
import app.iduanju.core.util.Bytes
import app.iduanju.core.util.ContentFilter
import app.iduanju.core.util.J
import app.iduanju.core.util.NetGuard
import app.iduanju.core.util.ProviderException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.TimeZone
import java.util.concurrent.ConcurrentHashMap

/** One imported config as the engine sees it. */
class RepoRuntime(
    val id: String, val name: String, val config: TVBoxConfig, val trusted: Boolean, val allowPrivate: Boolean,
    val doh: TVBoxDoh? = null, val parse: String = "", /** The config is a file or text the user imported. */ val local: Boolean = false,
) {
    /** Anything that changes how spiders of this config run. */
    internal fun sameAs(o: RepoRuntime) = config == o.config && trusted == o.trusted && allowPrivate == o.allowPrivate && doh == o.doh && local == o.local
}

/** Loads `csp_*` classes (Android only). */
interface JarHost : JarRuntimeParsers {
    /** Downloads / verifies / loads the jar if needed and returns an initialised spider. Blocking, spider thread. */
    fun spider(http: TVBoxHttp, ref: SpiderRef, site: TVBoxSite): Spider
    /** Static `com.github.catvod.spider.Proxy.proxy` of the loaded jars. */
    fun proxy(params: Map<String, String>): ProxyReply?
    /** Files outside [keep] are deleted, classes outside [run] (the trusted ones) forgotten. */
    fun release(keep: Set<String>, run: Set<String>)
}

interface JarRuntimeParsers {
    fun json(http: TVBoxHttp, ref: SpiderRef, key: String, jxs: LinkedHashMap<String, String>, url: String): JSONObject?
    fun mix(http: TVBoxHttp, ref: SpiderRef, key: String, name: String, flag: String, jxs: LinkedHashMap<String, HashMap<String, String>>, url: String): JSONObject?
}

/** What only the app can provide. Nullable runtimes are simply not part of this build. */
class TVBoxPlatform(
    val js: (() -> JsEngine)?, val python: PyEngine?, val jar: JarHost?, val sniffer: Sniffer,
    /** Bundled script assets (`bootstrap.js`, `lib/<name>`); null when missing. */
    val jsAsset: (String) -> String?, val storage: ScriptStorage, val log: (String) -> Unit = {},
)

/** A value shown now plus whether it is already up to date. */
data class Snapshot<T>(val value: T, val fresh: Boolean, val error: String? = null)

data class SiteRef(val repo: RepoRuntime, val site: TVBoxSite, val uid: String)
data class LiveRef(val repo: RepoRuntime, val live: TVBoxLive, val uid: String)
data class LiveData(val ref: LiveRef, val list: LiveList) {
    /** Every name a programme guide may know these channels by. */
    val guideKeys: Set<String> by lazy { list.channels.flatMap { (_, c) -> listOf(c.tvgId, c.tvgName, c.name) }.map(EpgParser::key).filter { it.isNotEmpty() }.toSet() }
}
data class SearchHit(val ref: SiteRef, val items: List<VodItem>, val error: String?)

/**
 * Everything TVBox behind one object: spider sessions, vod calls with stale-while-revalidate caching, parsing, live lists,
 * guides and the loopback proxy. No UI and no Android types; blocking work never runs on the caller's thread.
 */
class TVBoxEngine(private val net: TVBoxNet, private val platform: TVBoxPlatform, private val cache: TVBoxCache, scripts: File, epgDir: File) : BridgeTarget {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val scriptCache = ScriptCache(scripts)
    private val epg = EpgService(epgDir)
    private val sessions = ConcurrentHashMap<String, SpiderSession>()
    private val scopes = ConcurrentHashMap<String, Pair<RepoRuntime, TVBoxNet.Scope>>()
    @Volatile private var repos: Map<String, RepoRuntime> = emptyMap()
    @Volatile private var sites: Map<String, SiteRef> = emptyMap()
    @Volatile private var lives: Map<String, LiveRef> = emptyMap()
    @Volatile private var activeRepo = ""
    /** Ids of sites that changed identity when an old store was migrated. */
    @Volatile private var aliases: Map<String, String> = emptyMap()

    // 9979 is the bridge's port
    private val server = LocalServer("tvbox-proxy", true, listOf(9978) + (9980..9998)) { route(it) }
    /** Port of the loopback proxy; starts it on first use. */
    override val proxyPort: Int get() = if (server.running) server.port else server.start()
    val runningPort: Int get() = if (server.running) server.port else 0

    // ------------------------------------------------------------------------------------------------------ registry

    /** Replaces the known configs; spiders of removed or changed ones are destroyed. */
    fun setRepos(list: List<RepoRuntime>, active: String, aliases: Map<String, String> = emptyMap()) {
        val old = repos
        val now = list.associateBy { it.id }
        val gone = old.filter { (id, r) -> now[id]?.sameAs(r) != true }.keys
        activeRepo = active
        this.aliases = aliases
        repos = now
        sites = list.flatMap { r -> r.config.sites.map { s -> SiteRef(r, s, TVBoxConfig.siteUid(r.id, s.key)) } }.associateBy { it.uid }
        lives = list.flatMap { r -> r.config.lives.map { l -> LiveRef(r, l, TVBoxConfig.liveUid(r.id, l.identity)) } }.associateBy { it.uid }
        if (gone.isEmpty()) return
        gone.forEach { scopes.remove(it) }
        synchronized(liveMemory) { liveMemory.values.removeAll { it.data.ref.repo.id in gone } }
        val closing = sessions.keys.filter { k -> k.substringBefore('/') in gone }.mapNotNull { sessions.remove(it) }
        // closing may run a spider's own code
        scope.launch {
            closing.forEach { it.close() }
            platform.jar?.release(jarIds(list), jarIds(list.filter { it.trusted }))
        }
    }

    private fun jarIds(list: List<RepoRuntime>): Set<String> = list.flatMap { r -> r.config.sites.map { r.config.jarOf(it) } + r.config.lives.map { r.config.jarOf(it) } + r.config.spider }.filter { it.isNotEmpty() }.map { SpiderRef.parse(it).id }.toSet()

    fun site(uid: String): SiteRef? = sites[uid] ?: aliases[uid]?.let { sites[it] }
    fun live(uid: String): LiveRef? = lives[uid] ?: aliases[uid]?.let { lives[it] }
    fun repo(id: String): RepoRuntime? = repos[id]

    fun http(repo: RepoRuntime): TVBoxNet.Scope {
        scopes[repo.id]?.let { (r, s) -> if (r.sameAs(repo)) return s }
        return net.Scope(NetRules(repo.config.hosts, repo.config.headers, repo.doh, repo.allowPrivate)).also { scopes[repo.id] = repo to it }
    }

    private fun need(uid: String): SiteRef = site(uid) ?: throw ProviderException.invalid("这个站点所在的 TVBox 配置已删除")

    // ------------------------------------------------------------------------------------------------------ spiders

    /** CMS and T4 calls share nothing: while one is busy the next gets a session of its own. Scripts and jars stay on their one thread. */
    private fun session(ref: SiteRef): SpiderSession {
        val key = ref.repo.id + "/" + ref.uid
        if (ref.site.kind == SiteKind.CmsXml || ref.site.kind == SiteKind.CmsJson || ref.site.kind == SiteKind.Remote)
            for (i in 0 until PARALLEL) { val s = session(ref, if (i == 0) key else "$key~$i"); if (!s.busy) return s }
        return session(ref, key)
    }

    private fun session(ref: SiteRef, key: String): SpiderSession {
        while (true) {
            val s = sessions[key]
            if (s != null && !s.dead) return s
            val fresh = SpiderSession(ref.site.name, kind = ref.site.kind) { create(ref.repo, ref.site, ref.uid, ref.repo.config.jarOf(ref.site), it) }
            if (s == null) { val other = sessions.putIfAbsent(key, fresh); if (other == null) return fresh.also { evict(it) } } else if (sessions.replace(key, s, fresh)) return fresh
            fresh.close()
        }
    }

    /** Script contexts are heavy and an aggregated search touches every site: idle ones beyond the budget are closed, oldest first. */
    private fun evict(keep: SpiderSession) {
        fun over(list: List<Map.Entry<String, SpiderSession>>, max: Int) {
            val idle = list.filter { it.value !== keep && !it.value.busy }.sortedBy { it.value.lastUsed }
            for (e in idle.take((list.size - max).coerceAtLeast(0))) if (sessions.remove(e.key, e.value)) e.value.close()
        }
        val all = sessions.entries.toList()
        over(all.filter { it.value.kind == SiteKind.Js || it.value.kind == SiteKind.Py }, 8)
        over(all.filter { it.value.kind != SiteKind.Js && it.value.kind != SiteKind.Py }, 48)
    }

    private fun create(repo: RepoRuntime, site: TVBoxSite, uid: String, jar: String, onAbort: (() -> Unit) -> Unit): Spider {
        val kind = site.kind
        if (kind.isCode && !repo.trusted) throw ProviderException.unsupported("配置「${repo.name}」尚未信任，${kind.badge} 站点不会运行")
        val http = http(repo)
        return when (kind) {
            SiteKind.CmsXml, SiteKind.CmsJson -> CmsSpider(site, http)
            SiteKind.Remote -> {
                // what is read here is sent to the site's server: this device only for an imported config whose server is on it
                val inside = repo.local && TVBoxNet.isLoopback(TVBoxUrl.host(site.api))
                RemoteSpider(site, http, inside).also { onAbort { it.interrupt() }; it.init(if (inside) served(site.ext) else site.ext) }
            }
            SiteKind.Jar -> {
                val host = platform.jar ?: throw ProviderException.unsupported("此版本未包含 JAR 运行时")
                val ref = SpiderRef.parse(jar)
                if (ref.isEmpty) throw ProviderException.invalid("配置没有给出 spider 地址")
                // CatVod spiders probe the loopback proxy (9978+) on their own during init/playerContent and
                // return a broken address when nothing listens; the lazy start must happen before they run.
                server.start()
                val tag = Any()
                onAbort { http.cancel(tag) }
                val ext = served(site.ext)
                host.spider(http.tagged(tag), ref, if (ext == site.ext) site else site.copy(ext = ext))
            }
            SiteKind.Js -> {
                val factory = platform.js ?: throw ProviderException.unsupported("此版本未包含 JavaScript 运行时")
                val script = ScriptHost(site.key, http, platform.storage, { proxyPort }) { platform.log("[${site.name}] $it") }
                onAbort { http.cancel(script.tag) }
                val bootstrap = platform.jsAsset("bootstrap.js") ?: throw ProviderException.unsupported("内置脚本库缺失")
                JsSpider(site, factory, script, JsModules({ platform.jsAsset("lib/$it") }, http, scriptCache, site.api, script.tag), bootstrap).also { it.onInterrupt = { http.cancel(script.tag) }; it.init(served(site.ext)) }
            }
            SiteKind.Py -> {
                val engine = platform.python ?: throw ProviderException.unsupported("此版本未包含 Python 运行时")
                val (url, param) = PySpider.script(site.api, site.ext)
                val script = ScriptHost(site.key, http, platform.storage, { proxyPort }) { platform.log("[${site.name}] $it") }
                onAbort { http.cancel(script.tag) }
                PySpider(uid, site, engine, script, { scriptCache.load(url, http, tag = script.tag) }, url).also { it.onInterrupt = { http.cancel(script.tag) }; it.init(served(param)) }
            }
            SiteKind.Unsupported -> throw ProviderException.unsupported("不支持的站点类型（type=${site.type}，api=${site.api.take(40)}）")
        }
    }

    /** Scripts and jars fetch their parameters themselves: imported files reach them through the loopback server. */
    private fun served(ext: String): String = if (ext.contains("clan://localhost/")) ext.replace("clan://localhost/", "http://127.0.0.1:$proxyPort/file/") else ext

    private suspend fun <T> call(ref: SiteRef, what: String, timeoutMs: Long = ref.site.timeoutMs, block: (Spider) -> T): T =
        // a session evicted between lookup and use is simply started again
        try { session(ref).call(timeoutMs, what, block) } catch (_: SpiderStopped) { session(ref).call(timeoutMs, what, block) }

    /** Loads a site's spider ahead of use (last-used site at app start). */
    fun preload(uid: String) { val ref = site(uid) ?: return; if (!ref.site.kind.isCode || ref.repo.trusted) scope.launch { runCatching { session(ref).warm() } } }

    fun status(uid: String): SpiderStatus = sites[uid]?.let { r -> sessions[r.repo.id + "/" + uid]?.let { if (it.dead) SpiderStatus.Idle else if (it.ready) SpiderStatus.Ready else SpiderStatus.Loading } } ?: SpiderStatus.Idle
    enum class SpiderStatus { Idle, Loading, Ready }

    private fun fixer(ref: SiteRef): (String) -> String = { u -> if (u.startsWith("proxy://") || u.contains("127.0.0.1:9978") || u.contains("localhost:9978")) VodMapper.localProxy(u, proxyPort, ref.site.key) else if (u.startsWith("//")) "https:$u" else u }

    // ------------------------------------------------------------------------------------------------------ vod

    /** [load] may hand over a first part before it is done. */
    private suspend fun <T> swr(owner: String, key: String, force: Boolean, map: (String) -> T, load: suspend (early: suspend (T) -> Unit) -> String, emit: suspend (Snapshot<T>) -> Unit, usable: (T) -> Boolean) {
        val hit = cache.get(owner, key)
        val old = hit?.let { runCatching { map(it.text) }.getOrNull() }?.takeIf(usable)
        if (old != null) {
            val fresh = !force && hit.age < FRESH_MS
            emit(Snapshot(old, fresh))
            if (fresh) return
        }
        try {
            val text = load { if (old == null && usable(it)) emit(Snapshot(it, false)) }
            val value = map(text)
            if (usable(value)) cache.put(owner, key, text)
            // many spiders answer their own failures with nothing: what is on screen stays
            emit(if (old != null && !usable(value)) Snapshot(old, true, "站点没有返回内容") else Snapshot(value, true))
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            if (old == null) throw e
            emit(Snapshot(old, true, SpiderErrors.text(e)))
        }
    }

    /** Cached home first, then the refreshed one. */
    fun home(uid: String, force: Boolean = false): Flow<Snapshot<VodHome>> = flow {
        val ref = need(uid)
        val fix = fixer(ref)
        swr(uid, "home", force, { VodMapper.home(VodMapper.root(it, "首页"), uid, ref.site.categories, fix) }, { early ->
            val text = call(ref, "首页") { it.homeContent(true) }
            val o = VodMapper.root(text, "首页")
            // the recommended rail is a second call for most spiders; its failure never hides the categories
            if ((o.optJSONArray("list")?.length() ?: 0) == 0 || ref.site.kind == SiteKind.CmsJson || ref.site.kind == SiteKind.CmsXml) {
                // the list of a CMS class call has no pictures
                if (ref.site.kind != SiteKind.Remote) early(VodMapper.home(o, uid, ref.site.categories, fix).copy(items = emptyList()))
                val more = try { call(ref, "推荐") { it.homeVideoContent() } } catch (e: CancellationException) { throw e } catch (e: Exception) { if (!o.has("class")) throw e; "" }
                runCatching { VodMapper.root(more, "推荐") }.getOrNull()?.optJSONArray("list")?.takeIf { it.length() > 0 }?.let { o.put("list", it) }
            }
            o.toString()
        }, { emit(it) }, { it.categories.isNotEmpty() || it.items.isNotEmpty() })
    }.flowOn(Dispatchers.Default)

    /** First pages come from the cache first; deeper pages are always fetched. */
    fun category(uid: String, tid: String, page: Int, extend: Map<String, String> = emptyMap(), force: Boolean = false): Flow<Snapshot<VodPage>> = flow {
        val ref = need(uid)
        val fix = fixer(ref)
        val load: suspend (suspend (VodPage) -> Unit) -> String = { call(ref, "分类") { it.categoryContent(tid, page.toString(), true, extend) } }
        if (page > 1) { emit(Snapshot(VodMapper.page(VodMapper.root(load { }, "分类"), uid, page, fix), true)); return@flow }
        val key = "cat|$tid|" + extend.toSortedMap().entries.joinToString("&")
        swr(uid, key, force, { VodMapper.page(VodMapper.root(it, "分类"), uid, 1, fix) }, load, { emit(it) }, { it.items.isNotEmpty() })
    }.flowOn(Dispatchers.Default)

    suspend fun search(uid: String, key: String, page: Int = 1, quick: Boolean = false): VodPage = withContext(Dispatchers.Default) {
        val ref = need(uid)
        VodMapper.page(VodMapper.root(call(ref, "搜索") { it.searchContent(key, quick, page.toString()) }, "搜索"), uid, page, fixer(ref))
    }

    /** Results per site in the order they arrive: bounded parallelism, own deadline per site, no barrier. */
    fun searchAll(uids: List<String>, key: String, parallel: Int = 8): Flow<SearchHit> = channelFlow {
        val gate = Semaphore(parallel)
        for (uid in uids) {
            val ref = sites[uid] ?: continue
            launch {
                gate.withPermit {
                    val hit = try {
                        val text = call(ref, "搜索", minOf(ref.site.timeoutMs, SEARCH_TIMEOUT_MS)) { it.searchContent(key, true, "1") }
                        SearchHit(ref, VodMapper.items(VodMapper.root(text, "搜索"), uid, fixer(ref)), null)
                    } catch (e: CancellationException) { throw e } catch (e: Exception) { SearchHit(ref, emptyList(), SpiderErrors.text(e)) }
                    send(hit)
                }
            }
        }
    }.flowOn(Dispatchers.Default)

    suspend fun detail(uid: String, id: String): HGSeriesDetail = withContext(Dispatchers.Default) {
        val ref = need(uid)
        VodMapper.detail(VodMapper.root(call(ref, "详情") { it.detailContent(listOf(id)) }, "详情"), uid, id, ref.site, fixer(ref))
    }

    suspend fun action(uid: String, action: String): String { val ref = need(uid); return call(ref, "操作") { it.action(action) } }

    suspend fun resolve(ep: HGEpisode): HGResolvedVideo = withContext(Dispatchers.Default) {
        val e = TVBoxId.parseEpisode(ep.vid) ?: throw ProviderException.invalid("剧集编号无效")
        val ref = need(e.uid)
        var media = ep.media?.let { LenientJson.objectOrNull(it) }
        if (media == null || J.str(media.opt("id")).isEmpty()) {
            val d = detail(e.uid, e.id)
            media = d.lines.getOrNull(e.line)?.episodes?.getOrNull(e.index)?.media?.let { LenientJson.objectOrNull(it) }
        }
        val flag = J.str(media?.opt("f"))
        val id = J.str(media?.opt("id")).ifEmpty { throw ProviderException.unsupported("站点没有给出这一集的播放地址") }
        play(ref, ep.vid, flag, id)
    }

    private suspend fun play(ref: SiteRef, vid: String, flag: String, id: String): HGResolvedVideo {
        TVBoxUrl.p2p(id)?.let { throw ProviderException.unsupported("$it 链接需要 P2P 内核，暂不支持") }
        val config = ref.repo.config
        val text = call(ref, "播放") { it.playerContent(flag, id, config.flags) }
        val r = if (text.isBlank()) throw ProviderException.upstream("站点没有返回播放信息") else PlayerResult.parse(text)
        val manual = if (r.parse == 1 && ref.site.kind.isCode) runCatching { call(ref, "校验") { it.manualVideoCheck() } }.getOrDefault(false) else false
        val parsed = chain(ref.repo, config.jarOf(ref.site)).resolve(r, flag, ref.site.click, if (manual) { u -> runCatching { call(ref, "校验") { it.isVideoFormat(u) } }.getOrDefault(false) } else null)
        val fix = fixer(ref)
        val jar = ref.site.kind == SiteKind.Jar
        val subs = r.subs.map { it.copy(url = fix(it.url)) }.filter { refusal(ref.repo, it.url, jar) == null }
        var refused: ProviderException? = null
        val streams = parsed.urls.mapIndexedNotNull { i, (name, u) ->
            try { stream(ref.repo, "tvb$i", name.ifEmpty { if (parsed.urls.size > 1) "画质 ${i + 1}" else parsed.via.ifEmpty { flag } }, TVBoxUrl.vod(fix(u)), ref.site.headers + parsed.headers, subs, r.format, jar) } catch (e: ProviderException) { refused = e; null }
        }
        val first = streams.firstOrNull() ?: throw refused ?: ProviderException.upstream(r.message.ifEmpty { "没有可播放的地址" })
        return HGResolvedVideo(vid, url = first.url, streams = streams, danmaku = r.danmaku.ifEmpty { null }?.let(fix)?.takeIf { refusal(ref.repo, it, jar) == null })
    }

    private fun chain(repo: RepoRuntime, jar: String): ParseChain {
        val host = platform.jar
        val ref = SpiderRef.parse(jar)
        val http = http(repo)
        val parsers = if (host == null || !repo.trusted || ref.isEmpty) null else object : JarParsers {
            override suspend fun json(key: String, jxs: LinkedHashMap<String, String>, url: String) = parseSession(repo).call(20_000, "解析") { host.json(http, ref, key, jxs, url) }
            override suspend fun mix(key: String, name: String, flag: String, jxs: LinkedHashMap<String, HashMap<String, String>>, url: String) = parseSession(repo).call(20_000, "解析") { host.mix(http, ref, key, name, flag, jxs, url) }
        }
        return ParseChain(repo.config, http, platform.sniffer, parsers, repo.allowPrivate, repo.parse)
    }

    /** Jar parse extensions run on their own thread so a slow one never blocks the site's spider. */
    private fun parseSession(repo: RepoRuntime): SpiderSession {
        val key = repo.id + "/parse"
        return synchronized(sessions) { sessions[key]?.takeIf { !it.dead } ?: SpiderSession("解析") { object : Spider {} }.also { sessions[key] = it } }
    }

    /**
     * Address policy of everything the player opens (contract §4): files never, this device only through the app's own proxy
     * ([jar]: or a server the trusted jar itself runs in this process), the local network only when the config may. Names are
     * resolved by the player's own guard.
     */
    private fun refusal(repo: RepoRuntime, url: String, jar: Boolean = false): ProviderException? {
        val scheme = url.substringBefore(':', "").lowercase()
        if (scheme == "data") return null
        if (!url.contains("://") || scheme in FILES) return ProviderException.unsupported("不支持的播放地址：${url.take(60)}")
        val host = TVBoxUrl.host(url)
        if (TVBoxNet.isLoopback(host) || host == "0.0.0.0") return if (TVBoxUrl.isHttp(url) && (jar || url.substringAfter("://").substringBefore('/').substringAfterLast(':') == runningPort.toString())) null else ProviderException.unsupported("不允许访问本机地址")
        if (repo.allowPrivate) return null
        // RTSP, RTMP and UDP do not go through a guarded client
        val blocked = if (NetGuard.isIPLiteral(host)) NetGuard.isBlockedIP(host) else host.endsWith(".local") || !TVBoxUrl.isHttp(url) && NetGuard.resolvesToBlocked(host)
        return if (blocked) ProviderException.unsupported(LAN_REFUSED) else null
    }

    private fun stream(repo: RepoRuntime, id: String, name: String, s: TVBoxUrl.Stream, headers: Map<String, String>, subs: List<HGSubtitle>, format: String, jar: Boolean = false): HGStream? {
        if (s.url.isEmpty()) return null
        val host = TVBoxUrl.host(s.url)
        val ruled = repo.config.headers.filter { host == it.host || host.endsWith("." + it.host) }.fold(emptyMap<String, String>()) { m, r -> m + r.headers }
        TVBoxUrl.p2p(s.url)?.let { throw ProviderException.unsupported("$it 链接需要 P2P 内核，暂不支持") }
        refusal(repo, s.url, jar)?.let { throw it }
        val l = s.url.lowercase()
        val path = l.substringBefore('?').substringBefore('#')
        val hls = format.contains("mpegurl", true) || (format.isEmpty() && (path.endsWith(".m3u8") || l.contains(".m3u8")))
        return HGStream(id, name.ifEmpty { null } ?: s.label.ifEmpty { null }, s.url, kind = if (hls) HGStreamKind.hls else HGStreamKind.mp4Clear,
            headers = headers + s.headers + ruled, subtitles = subs, format = format.ifEmpty { if (hls) "application/x-mpegURL" else if (path.endsWith(".mpd")) "application/dash+xml" else if (path.endsWith(".flv")) "video/x-flv" else if (path.endsWith(".mkv")) "video/x-matroska" else null }, lan = repo.allowPrivate || jar && TVBoxNet.isLoopback(host))
    }

    /** Round trip of a site's cheapest call, in milliseconds. */
    suspend fun latency(uid: String): Long {
        val ref = need(uid)
        val t = System.nanoTime()
        if (ref.site.kind == SiteKind.Jar || ref.site.kind == SiteKind.Js || ref.site.kind == SiteKind.Py) call(ref, "测速") { it.homeContent(false) }
        else call(ref, "测速") { it.homeContent(true) }
        return ((System.nanoTime() - t) / 1_000_000).coerceAtLeast(1)
    }

    /** Streams measurements as they finish (-1 = failed). */
    fun latencies(uids: List<String>, parallel: Int = 6): Flow<Pair<String, Long>> = channelFlow {
        val gate = Semaphore(parallel)
        for (uid in uids) launch {
            gate.withPermit { send(uid to (try { latency(uid) } catch (e: CancellationException) { throw e } catch (_: Exception) { -1L })) }
        }
    }.flowOn(Dispatchers.IO)

    // ------------------------------------------------------------------------------------------------------ live

    private class LiveHit(val text: String, val data: LiveData) { @Volatile var at = System.currentTimeMillis() }
    /** Parsed lists are big: only the last few stay. */
    private val liveMemory = object : LinkedHashMap<String, LiveHit>(4, 0.75f, true) { override fun removeEldestEntry(e: MutableMap.MutableEntry<String, LiveHit>) = size > 3 }
    private val liveRefreshed = ConcurrentHashMap<String, Long>()

    private fun needLive(uid: String) = live(uid) ?: throw ProviderException.invalid("这个直播源所在的 TVBox 配置已删除")

    private fun parseLive(ref: LiveRef, text: String): LiveData {
        synchronized(liveMemory) { liveMemory[ref.uid] }?.let { if (it.text == text && it.data.ref.repo === ref.repo) { it.at = System.currentTimeMillis(); return it.data } }
        val list = LiveParser.parse(text, ref.live.pass).let { l -> l.copy(groups = l.groups.filterNot { ContentFilter.isBlocked(listOf(it.name)) }.map { g -> g.copy(channels = g.channels.filterNot { ContentFilter.isBlocked(listOf(it.name)) }) }.filter { it.channels.isNotEmpty() }) }
        return LiveData(ref, list).also { synchronized(liveMemory) { liveMemory[ref.uid] = LiveHit(text, it) } }
    }

    private suspend fun fetchLive(ref: LiveRef): String {
        val live = ref.live
        val kind = live.kind
        if (kind != null) {
            val site = TVBoxSite(key = "live_" + live.name, name = live.name, type = 3, api = live.api, ext = live.ext, jar = live.jar, timeoutMs = live.timeoutMs)
            val key = ref.repo.id + "/live-" + ref.uid
            val s = synchronized(sessions) { sessions[key]?.takeIf { !it.dead } ?: SpiderSession(live.name) { create(ref.repo, site, "live-" + ref.uid, ref.repo.config.jarOf(live), it) }.also { sessions[key] = it } }
            return s.call(maxOf(live.timeoutMs, 20_000), "直播列表") { it.liveContent(live.url) }
        }
        val r = http(ref.repo).fetch(NetRequest(live.url, headers = live.requestHeaders, timeoutMs = maxOf(live.timeoutMs, 12_000)))
        if (!r.ok) throw ProviderException.upstream("直播列表 HTTP ${r.code}")
        return TVBoxDecoder.decode(r.body)
    }

    fun liveChannels(uid: String, force: Boolean = false): Flow<Snapshot<LiveData>> = flow {
        val ref = needLive(uid)
        inline(ref)?.let { emit(Snapshot(it, true)); return@flow }
        swr("live-$uid", "list", force, { parseLive(ref, it) }, { fetchLive(ref) }, { emit(it) }, { it.list.groups.isNotEmpty() })
    }.flowOn(Dispatchers.Default)

    /** Channels written into the config itself. */
    private fun inline(ref: LiveRef) = if (ref.live.groups.isNotEmpty() && ref.live.url.isEmpty() && ref.live.api.isEmpty()) LiveData(ref, LiveList(ref.live.groups)) else null

    /** Current list (cached when there is one). Asked for by every visible row: an old list is refreshed at most once a minute. */
    suspend fun liveList(uid: String): LiveData = withContext(Dispatchers.Default) {
        val ref = needLive(uid)
        inline(ref)?.let { return@withContext it }
        synchronized(liveMemory) { liveMemory[ref.uid] }?.let { if (it.data.ref.repo === ref.repo && System.currentTimeMillis() - it.at < LIVE_MEMORY_MS) return@withContext it.data }
        val hit = cache.get("live-$uid", "list")
        val old = hit?.let { runCatching { parseLive(ref, it.text) }.getOrNull() }?.takeIf { it.list.groups.isNotEmpty() }
        if (old == null) return@withContext liveChannels(uid).firstOrNull { it.value.list.groups.isNotEmpty() }?.value ?: throw ProviderException.upstream("直播列表为空")
        if (hit.age >= FRESH_MS && due(ref.uid)) scope.launch { runCatching { liveChannels(uid, force = true).collect { } } }
        old
    }

    private fun due(uid: String): Boolean {
        val now = System.currentTimeMillis()
        var mine = false
        liveRefreshed.compute(uid) { _, at -> if (at == null || now - at >= LIVE_MEMORY_MS) { mine = true; now } else at }
        return mine
    }

    /** Contract §1: channels as episodes. Locked groups stay out unless [unlocked] holds their name. */
    suspend fun liveDetail(uid: String, unlocked: Set<String>): HGSeriesDetail = withContext(Dispatchers.Default) {
        val d = liveList(uid)
        val live = d.ref.live
        var n = 0
        val eps = d.list.groups.filter { it.pass.isEmpty() || it.name in unlocked }.flatMap { g -> g.channels.map { g to it } }.map { (g, c) ->
            n++
            HGEpisode(n, "${TVBoxId.live(uid)}#${n - 1}", 0, c.name, page = g.name, media = media(d, c))
        }
        if (eps.isEmpty()) throw ProviderException.unsupported("没有可以播放的频道")
        HGSeriesDetail(seriesId = TVBoxId.live(uid), title = live.name, cover = live.logo.takeIf { !it.contains("{") }.orEmpty(), totalEps = eps.size, episodes = eps, episodeLabel = "共${eps.size}个频道", source = d.ref.repo.name, isLive = true)
    }

    private fun epgOf(d: LiveData) = d.ref.live.epg.ifEmpty { d.list.epg }
    private fun catchupOf(d: LiveData, c: LiveChannel): Catchup? = c.catchup ?: d.list.catchup ?: d.ref.live.catchup ?: c.urls.firstOrNull()?.let { Catchup.implied(it) }
    private fun media(d: LiveData, c: LiveChannel): String {
        val logo = c.logo.ifEmpty { d.ref.live.logo.takeIf { it.contains("{name}") }?.let { EpgParser.url(it, c.guideName, "", c.tvgId) }.orEmpty() }
        return c.copy(logo = logo).mediaJSON(d.ref.live.requestHeaders, epgOf(d), catchupOf(d, c))
    }

    suspend fun resolveLive(ep: HGEpisode, unlocked: Set<String>): HGResolvedVideo = withContext(Dispatchers.Default) {
        val uid = TVBoxId.liveUid(ep.vid)
        val ref = needLive(uid)
        val o = ep.media?.let { LenientJson.objectOrNull(it) } ?: liveDetail(uid, unlocked).episodes.getOrNull(TVBoxId.liveIndex(ep.vid))?.media?.let { LenientJson.objectOrNull(it) } ?: throw ProviderException.unsupported("频道不存在")
        val headers = TVBoxConfig.headerMap(o.opt("headers"))
        val format = J.str(o.opt("format"))
        val urls = J.arr(o.opt("urls")).map { J.str(it) }.filter { it.isNotEmpty() }
        val sniff = J.int(o.opt("parse")) == 1
        var refused: ProviderException? = null
        val streams = urls.mapIndexedNotNull { i, raw ->
            val u = VodMapper.localProxy(raw, if (raw.startsWith("proxy://") || raw.contains(":9978/proxy")) proxyPort else 9978, "")
            val s = TVBoxUrl.stream(u)
            try { stream(ref.repo, "tvl$i", s.label.ifEmpty { "线路 ${i + 1}" }, s, headers, emptyList(), format, ref.live.kind == SiteKind.Jar) } catch (e: ProviderException) { refused = e; null }
        }
        if (streams.isEmpty()) throw refused ?: ProviderException.unsupported("频道没有播放地址")
        if (!sniff) return@withContext HGResolvedVideo(ep.vid, url = streams.first().url, streams = streams)
        val first = streams.first()
        val found = platform.sniffer.sniff(SniffRequest(first.url, first.headers, listOf(J.str(o.opt("click"))).filter { it.isNotEmpty() }, ref.repo.config.rules, ref.repo.config.ads, ref.repo.allowPrivate))
        val real = stream(ref.repo, "tvl0", first.quality.orEmpty(), TVBoxUrl.vod(found.url), found.headers, emptyList(), format) ?: throw ProviderException.upstream("没有嗅探到播放地址")
        HGResolvedVideo(ep.vid, url = real.url, streams = listOf(real) + streams.drop(1))
    }

    /** Programmes of a channel on the day of [at]; empty when no guide is configured. */
    suspend fun guide(uid: String, name: String, tvgId: String = "", tvgName: String = "", at: Long = System.currentTimeMillis()): List<Programme> = withContext(Dispatchers.Default) {
        val d = try { liveList(uid) } catch (e: CancellationException) { throw e } catch (_: Exception) { return@withContext emptyList() }
        val ch = d.list.channels.firstOrNull { (_, c) -> c.name == name && (tvgId.isEmpty() || c.tvgId == tvgId) }?.second ?: LiveChannel(name, emptyList(), tvgId = tvgId, tvgName = tvgName)
        val source = ch.epg.ifEmpty { epgOf(d) }
        if (source.isEmpty()) emptyList() else epg.programmes(http(d.ref.repo), source, ch, d.guideKeys, at, zone(d.ref.live))
    }

    private fun zone(live: TVBoxLive) = if (live.timeZone.isEmpty()) TimeZone.getDefault() else TimeZone.getTimeZone(live.timeZone)

    /** Replay streams of a finished programme, one per line whose template works. */
    fun catchup(ep: HGEpisode, p: Programme): HGResolvedVideo? {
        val ref = live(TVBoxId.liveUid(ep.vid)) ?: return null
        val o = ep.media?.let { LenientJson.objectOrNull(it) } ?: return null
        val c = (o.opt("catchup") as? JSONObject)?.let(Catchup::fromJSON)
        val headers = TVBoxConfig.headerMap(o.opt("headers"))
        val streams = J.arr(o.opt("urls")).map { J.str(it) }.mapIndexedNotNull { i, raw ->
            val s = TVBoxUrl.stream(raw)
            val u = (c ?: Catchup.implied(s.url))?.url(s.url, p.start, p.end, zone = zone(ref.live)) ?: return@mapIndexedNotNull null
            try { stream(ref.repo, "tvc$i", s.label.ifEmpty { "线路 ${i + 1}" }, TVBoxUrl.vod(u), headers + s.headers, emptyList(), J.str(o.opt("format"))) } catch (_: ProviderException) { null }
        }
        return if (streams.isEmpty()) null else HGResolvedVideo(ep.vid + "@" + p.start, url = streams.first().url, streams = streams)
    }

    // ------------------------------------------------------------------------------------------------------ proxy

    private fun route(r: HttpIn): ProxyReply {
        if (r.path.startsWith("/file/")) {
            val f = net.localFile("clan://localhost/" + r.path.substring(6).replace("%", "%25")) ?: return ProxyReply.text("not found", 404)
            return ProxyReply(200, "application/octet-stream", f.inputStream(), length = f.length())
        }
        if (r.path.trimEnd('/') != "/proxy") return ProxyReply.text("not found", 404)
        val params = LinkedHashMap(r.query)
        r.headers.forEach { (k, v) -> params.putIfAbsent(k, v) }
        return proxy(params)
    }

    override fun proxy(params: Map<String, String>): ProxyReply {
        val kind = params["do"].orEmpty()
        if (kind == "ck") return ProxyReply.text("ok")
        if (kind == "live") return liveProxy(params)
        val siteKey = params["siteKey"].orEmpty()
        val script = kind == "js" || kind == "py"
        val ref = if (script || siteKey.isNotEmpty()) proxyTarget(when (kind) { "js" -> SiteKind.Js; "py" -> SiteKind.Py; else -> SiteKind.Jar }, siteKey) else null
        if (script && ref == null) return ProxyReply.text("没有找到站点 $siteKey", 404)
        val reply = ref?.let { r -> runBlocking { call(r, "代理", 30_000) { it.proxyLocal(params) } } }
        return reply ?: (if (script) null else platform.jar?.proxy(params)) ?: ProxyReply.text("no handler", 404)
    }

    /** The live spider a proxied address belongs to: same key, loaded sessions and the active config first. */
    private fun proxyTarget(kind: SiteKind, key: String): SiteRef? {
        val all = sites.values.filter { it.site.kind == kind && it.repo.trusted }
        val named = if (key.isEmpty()) all.filter { status(it.uid) == SpiderStatus.Ready } else all.filter { it.site.key == key || it.uid == key }
        return named.sortedWith(compareByDescending<SiteRef> { status(it.uid) == SpiderStatus.Ready }.thenByDescending { it.repo.id == activeRepo }).firstOrNull()
    }

    private fun liveProxy(params: Map<String, String>): ProxyReply {
        val repo = repos[activeRepo] ?: return ProxyReply.text("no config", 404)
        val url = TVBoxConfig.proxyLive("proxy://do=live&ext=" + params["ext"].orEmpty())
        if (url.isEmpty()) return ProxyReply.text("bad ext", 400)
        val r = http(repo).execute(NetRequest(url, timeoutMs = 15_000))
        return ProxyReply(r.code, "text/plain; charset=utf-8", r.body.inputStream(), length = r.body.size.toLong())
    }

    // ------------------------------------------------------------------------------------------------------ bridge

    override fun call(siteKey: String, api: String, ext: String, jar: String, method: String, args: JSONArray): String {
        val host = platform.jar ?: throw BridgeTarget.Denied("此版本未包含 JAR 运行时")
        val url = SpiderRef.parse(jar).url
        fun jarUrl(r: RepoRuntime, s: TVBoxSite) = SpiderRef.parse(r.config.jarOf(s)).url
        if (method == "jsonExt" || method == "jsonExtMix") {
            val repo = repos.values.firstOrNull { it.trusted && SpiderRef.parse(it.config.spider).url == url } ?: throw BridgeTarget.Denied("这台设备没有导入并信任使用该 JAR 的配置")
            val ref = SpiderRef.parse(repo.config.spider)
            val out = runBlocking {
                parseSession(repo).call(20_000, "解析") {
                    if (method == "jsonExt") host.json(http(repo), ref, args.optString(0), LinkedHashMap<String, String>().apply { J.dict(args.opt(1)).let { o -> o.keys().forEach { k -> put(k, J.str(o.opt(k))) } } }, args.optString(2))
                    else host.mix(http(repo), ref, args.optString(0), args.optString(1), args.optString(2), LinkedHashMap<String, HashMap<String, String>>().apply {
                        J.dict(args.opt(3)).let { o -> o.keys().forEach { k -> put(k, HashMap<String, String>().apply { J.dict(o.opt(k)).let { e -> e.keys().forEach { x -> put(x, J.str(e.opt(x))) } } }) } }
                    }, args.optString(4))
                }
            }
            return out?.toString().orEmpty()
        }
        if (method !in BRIDGE_METHODS) throw BridgeTarget.Denied("不支持的方法 $method")
        val imported = sites.values.filter { it.site.kind == SiteKind.Jar && it.site.api == api && jarUrl(it.repo, it.site) == url }
        if (imported.isEmpty()) throw BridgeTarget.Denied("这台设备没有导入使用该 JAR 的配置")
        val trusted = imported.filter { it.repo.trusted }.ifEmpty { throw BridgeTarget.Denied("这台设备还没有信任该配置") }
        val ref = trusted.firstOrNull { it.site.ext == ext && it.site.key == siteKey } ?: trusted.firstOrNull { it.site.ext == ext } ?: trusted.first().let { t ->
            // same trusted class, other parameters (the other device may have a newer config)
            SiteRef(t.repo, t.site.copy(key = siteKey.ifEmpty { t.site.key }, ext = ext), "b" + Bytes.hex(Bytes.md5("$api|$ext")).take(11))
        }
        sessions.entries.filter { it.value.kind == SiteKind.Jar && it.key.substringAfter('/').let { id -> id.startsWith("b") && !sites.containsKey(id) } }.let { extra ->
            if (extra.size > 16) extra.sortedBy { it.value.lastUsed }.take(8).forEach { e -> if (!e.value.busy && sessions.remove(e.key, e.value)) e.value.close() }
        }
        return runBlocking { call(ref, method) { invoke(it, method, args) } }
    }

    private fun invoke(s: Spider, method: String, a: JSONArray): String {
        fun str(i: Int) = J.str(a.opt(i))
        fun list(i: Int) = J.arr(a.opt(i)).map { J.str(it) }
        return when (method) {
            "homeContent" -> s.homeContent(J.bool(a.opt(0)))
            "homeVideoContent" -> s.homeVideoContent()
            "categoryContent" -> s.categoryContent(str(0), str(1), J.bool(a.opt(2)), J.dict(a.opt(3)).let { o -> o.keys().asSequence().associateWith { J.str(o.opt(it)) } })
            "detailContent" -> s.detailContent(list(0).ifEmpty { listOf(str(0)) })
            "searchContent" -> s.searchContent(str(0), J.bool(a.opt(1)), str(2).ifEmpty { "1" })
            "playerContent" -> s.playerContent(str(0), str(1), list(2))
            "liveContent" -> s.liveContent(str(0))
            "action" -> s.action(str(0))
            "isVideoFormat" -> s.isVideoFormat(str(0)).toString()
            else -> s.manualVideoCheck().toString()
        }
    }

    // ------------------------------------------------------------------------------------------------------ lifecycle

    fun clearCache(uid: String) { cache.clear(uid) }
    fun trimCaches() = cache.trim()

    /** Drops a config's running spiders and cached scripts, so an explicit refresh really runs the newest code. */
    fun restart(repoId: String) {
        scriptCache.clear()
        sessions.keys.filter { it.substringBefore('/') == repoId }.forEach { sessions.remove(it)?.close() }
    }

    fun shutdown() {
        server.stop()
        scope.coroutineContext.cancelChildren()
        sessions.values.forEach { it.close() }
        sessions.clear()
    }

    companion object {
        const val LAN_REFUSED = "该地址在局域网内，请在 TVBox 设置里打开「允许访问局域网」"
        private val FILES = setOf("file", "content", "asset", "android.resource", "rawresource", "idjcenc")
        private const val PARALLEL = 3
        private const val LIVE_MEMORY_MS = 60_000L
        private const val FRESH_MS = 3 * 60_000L
        private const val SEARCH_TIMEOUT_MS = 12_000L
        private val BRIDGE_METHODS = setOf("homeContent", "homeVideoContent", "categoryContent", "detailContent", "searchContent", "playerContent", "liveContent", "action", "isVideoFormat", "manualVideoCheck")
    }
}
