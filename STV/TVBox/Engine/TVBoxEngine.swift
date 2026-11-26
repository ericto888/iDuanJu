import Foundation

struct TVBoxSiteRef: Hashable, Identifiable {
    let uid: String
    let site: TVBoxSite
    var id: String { uid }
}

struct TVBoxLiveRef: Hashable, Identifiable {
    let uid: String
    let live: TVBoxLive
    var id: String { uid }
}

/// One imported config as the engine sees it.
final class RepoRuntime {
    let id: String
    let name: String
    let config: TVBoxConfig
    let trusted: Bool
    let allowPrivate: Bool
    /// User-chosen default parse.
    let parse: String
    /// Imported from a file or pasted, not downloaded.
    let local: Bool
    let sites: [TVBoxSiteRef]
    let lives: [TVBoxLiveRef]

    /// `sites` / `lives`: refs computed earlier for the same config (uids are hashes).
    init(_ id: String, _ name: String, _ config: TVBoxConfig, trusted: Bool, allowPrivate: Bool, parse: String = "", local: Bool = false, sites: [TVBoxSiteRef]? = nil, lives: [TVBoxLiveRef]? = nil) {
        self.id = id
        self.name = name
        self.config = config
        self.trusted = trusted
        self.allowPrivate = allowPrivate
        self.parse = parse
        self.local = local
        self.sites = sites ?? RepoRuntime.siteRefs(id, config)
        self.lives = lives ?? RepoRuntime.liveRefs(id, config)
    }

    static func siteRefs(_ id: String, _ c: TVBoxConfig) -> [TVBoxSiteRef] { c.sites.map { TVBoxSiteRef(uid: TVBoxConfig.siteUid(id, $0.key), site: $0) } }
    static func liveRefs(_ id: String, _ c: TVBoxConfig) -> [TVBoxLiveRef] { c.lives.map { TVBoxLiveRef(uid: TVBoxConfig.liveUid(id, $0.identity), live: $0) } }

    /// Anything that changes how spiders of this config run.
    func sameAs(_ o: RepoRuntime) -> Bool { self === o || (trusted == o.trusted && allowPrivate == o.allowPrivate && local == o.local && config == o.config) }
}

/// A value shown now plus whether it is already up to date.
struct Snapshot<T> {
    let value: T
    let fresh: Bool
    var error: String? = nil
}

struct SiteRef {
    let repo: RepoRuntime
    let site: TVBoxSite
    let uid: String
}

struct LiveRef {
    let repo: RepoRuntime
    let live: TVBoxLive
    let uid: String
}

final class LiveData {
    let ref: LiveRef
    let list: LiveList
    private let lock = NSLock()
    private var keys: Set<String>?

    init(_ ref: LiveRef, _ list: LiveList) { self.ref = ref; self.list = list }

    /// Every name a programme guide may know these channels by.
    var guideKeys: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let k = keys { return k }
        var out = Set<String>()
        for g in list.groups { for c in g.channels { for n in [c.tvgId, c.tvgName, c.name] where !n.isEmpty { out.insert(EpgParser.key(n)) } } }
        out.remove("")
        keys = out
        return out
    }
}

struct SearchHit {
    let ref: SiteRef
    let items: [VodItem]
    let error: String?
}

/// Everything TVBox behind one object: spider sessions, vod calls with stale-while-revalidate caching, parsing, live lists,
/// guides and the loopback proxy. No UI; blocking work never runs on the caller's thread.
final class TVBoxEngine {
    enum SpiderStatus: String { case idle, loading, ready }

    private static let freshMs = 3 * 60_000
    private static let searchTimeoutMs = 12_000
    /// Parsed live lists kept in memory; a big one takes tens of megabytes.
    private static let maxLiveLists = 3

    let net: TVBoxNet
    private let makePlatform: () -> TVBoxPlatform
    private let cache: TVBoxCache
    private let scriptCache: ScriptCache
    private let epg: EpgService
    private let startProxy: (@escaping ([String: String]) -> ProxyReply) -> Int

    private let lock = NSLock()
    private let proxyLock = NSLock()
    private var platformValue: TVBoxPlatform?
    private var boundPort = 0
    private var repos: [String: RepoRuntime] = [:]
    private var sites: [String: SiteRef] = [:]
    private var lives: [String: LiveRef] = [:]
    private var activeRepo = ""
    /// Ids of sites that changed identity when an old store was migrated.
    private var aliases: [String: String] = [:]
    private var sessions: [String: SpiderSession] = [:]
    private var scopes: [String: (repo: RepoRuntime, http: TVBoxNet.Scope)] = [:]
    private var liveMemory: [String: (text: String, data: LiveData, used: Date)] = [:]
    private var liveRefreshes = Set<String>()
    /// Channels in the order they were last listed for a page or the player.
    private var listed: [String: [ChannelKey]] = [:]
    private var homes: [String: VodHome] = [:]

    init(_ net: TVBoxNet, platform: @escaping () -> TVBoxPlatform, cache: TVBoxCache, scripts: URL, epgDir: URL,
         startProxy: @escaping (@escaping ([String: String]) -> ProxyReply) -> Int = TVBoxRuntime.startProxy) {
        self.net = net
        makePlatform = platform
        self.cache = cache
        scriptCache = ScriptCache(scripts)
        epg = EpgService(epgDir)
        self.startProxy = startProxy
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    private var platform: TVBoxPlatform {
        locked {
            if let p = platformValue { return p }
            let p = makePlatform()
            platformValue = p
            return p
        }
    }

    /// Port of the loopback proxy; starts it on first use. Blocking for a moment then.
    var proxyPort: Int {
        proxyLock.lock()
        defer { proxyLock.unlock() }
        let port = startProxy { [weak self] in self?.proxy($0) ?? .text("stopped", code: 503) }
        locked { boundPort = port }
        return port
    }

    /// 0 while the proxy has not been needed yet.
    var runningPort: Int { locked { boundPort } }

    // MARK: Registry

    /// Replaces the known configs; spiders of removed or changed ones are destroyed.
    func setRepos(_ list: [RepoRuntime], active: String, aliases: [String: String] = [:]) {
        var now: [String: RepoRuntime] = [:], siteMap: [String: SiteRef] = [:], liveMap: [String: LiveRef] = [:]
        for r in list {
            now[r.id] = r
            for s in r.sites { siteMap[s.uid] = SiteRef(repo: r, site: s.site, uid: s.uid) }
            for l in r.lives { liveMap[l.uid] = LiveRef(repo: r, live: l.live, uid: l.uid) }
        }
        let closing = locked { () -> [SpiderSession] in
            let gone = Set(repos.values.filter { !(now[$0.id]?.sameAs($0) ?? false) }.map(\.id))
            repos = now
            sites = siteMap
            lives = liveMap
            activeRepo = active
            self.aliases = aliases
            if gone.isEmpty { return [] }
            for id in gone { scopes[id] = nil }
            liveMemory = liveMemory.filter { !gone.contains($0.value.data.ref.repo.id) }
            return drop { gone.contains($0) }
        }
        closing.forEach { $0.close() }
    }

    /// Under `lock`: removes the sessions of the matching configs.
    private func drop(_ match: (String) -> Bool) -> [SpiderSession] {
        let keys = sessions.keys.filter { match($0.substringBefore("/")) }
        return keys.compactMap { sessions.removeValue(forKey: $0) }
    }

    func site(_ uid: String) -> SiteRef? { locked { sites[uid] ?? aliases[uid].flatMap { sites[$0] } } }
    func live(_ uid: String) -> LiveRef? { locked { lives[uid] ?? aliases[uid].flatMap { lives[$0] } } }
    func repo(_ id: String) -> RepoRuntime? { locked { repos[id] } }
    /// Categories of the last home seen in this session.
    func knownHome(_ uid: String) -> VodHome? { locked { homes[uid] } }

    func http(_ repo: RepoRuntime) -> TVBoxNet.Scope {
        locked {
            if let s = scopes[repo.id], s.repo.sameAs(repo) { return s.http }
            let s = TVBoxNet.Scope(net, NetRules(hosts: repo.config.hosts, headers: repo.config.headers, allowPrivate: repo.allowPrivate))
            scopes[repo.id] = (repo, s)
            return s
        }
    }

    private func need(_ uid: String) throws -> SiteRef {
        guard let r = site(uid) else { throw ProviderError.invalid("这个站点所在的 TVBox 配置已删除") }
        return r
    }

    private func needLive(_ uid: String) throws -> LiveRef {
        guard let r = live(uid) else { throw ProviderError.invalid("这个直播源所在的 TVBox 配置已删除") }
        return r
    }

    // MARK: Spiders

    private func session(_ ref: SiteRef) -> SpiderSession {
        session(ref.repo.id + "/" + ref.uid, ref.site, ref.repo, ref.uid, ref.repo.config.jarOf(ref.site))
    }

    private func session(_ key: String, _ site: TVBoxSite, _ repo: RepoRuntime, _ uid: String, _ jar: String) -> SpiderSession {
        var idle: [SpiderSession] = []
        let s = locked { () -> SpiderSession in
            if let s = sessions[key], !s.dead { return s }
            let fresh = SpiderSession(site.name, kind: site.kind, create: { [weak self] in
                guard let self else { throw SpiderStopped("「\(site.name)」已停止") }
                return try self.create(repo, site, uid, jar)
            }, begin: { [weak self] in try self?.begin($0, site) })
            sessions[key] = fresh
            idle = evict(key)
            return fresh
        }
        idle.forEach { $0.close() }
        return s
    }

    /// Under `lock`. Script contexts are heavy and an aggregated search touches every site: idle ones beyond the budget are
    /// closed, oldest first.
    private func evict(_ keep: String) -> [SpiderSession] {
        var out: [SpiderSession] = []
        func over(_ all: [(key: String, value: SpiderSession)], _ max: Int) {
            if all.count <= max { return }
            let idle = all.filter { $0.key != keep && !$0.value.busy }.sorted { $0.value.lastUsed < $1.value.lastUsed }
            for e in idle.prefix(all.count - max) {
                sessions[e.key] = nil
                out.append(e.value)
            }
        }
        func heavy(_ s: SpiderSession) -> Bool { s.kind == .js || s.kind == .py }
        over(Array(sessions.filter { heavy($0.value) }), 8)
        over(Array(sessions.filter { !heavy($0.value) }), 48)
        return out
    }

    private func create(_ repo: RepoRuntime, _ site: TVBoxSite, _ uid: String, _ jar: String) throws -> Spider {
        let kind = site.kind
        if kind.isCode && !repo.trusted { throw TVBoxError("配置「\(repo.name)」尚未信任，\(kind.badge) 站点不会运行") }
        let http = self.http(repo)
        switch kind {
        case .cmsXml, .cmsJson: return CmsSpider(site, http)
        case .remote: return RemoteSpider(site, http, localExt: repo.local && TVBoxNet.isLoopback(site.api))
        case .jar:
            guard let host = platform.jar, host.paired else { throw TVBoxError("JAR 站点需要配对 Android 桥接") }
            if SpiderRef.parse(jar).isEmpty { throw ProviderError.invalid("配置没有给出 spider 地址") }
            return try host.spider(site: site, jar: jar)
        case .js:
            let p = platform
            guard let factory = p.js else { throw TVBoxError("此版本未包含 JavaScript 运行时") }
            guard let bootstrap = p.jsAsset("bootstrap.js") else { throw TVBoxError("内置脚本库缺失") }
            let host = p.makeHost(site.key, http) { [weak self] in self?.proxyPort ?? 0 }
            let modules = JsModules(asset: { p.jsAsset("lib/" + $0) }, http: http, cache: scriptCache, entry: site.api, tag: host.tag)
            let s = JsSpider(site: site, engineFactory: factory, host: host, modules: modules, bootstrap: bootstrap)
            s.onInterrupt = { [tag = host.tag] in http.cancel(tag) }
            return s
        case .py:
            let p = platform
            guard let engine = p.python else { throw TVBoxError("此版本未包含 Python 运行时") }
            let (url, _) = try PySpider.script(site.api, site.ext)
            let host = p.makeHost(site.key, http) { [weak self] in self?.proxyPort ?? 0 }
            let s = PySpider(uid: uid, site: site, engine: engine, host: host, source: { [scriptCache, tag = host.tag] in try scriptCache.load(url, http: http, tag: tag) }, url: url)
            s.onInterrupt = { [tag = host.tag] in http.cancel(tag) }
            return s
        case .unsupported:
            throw TVBoxError("不支持的站点类型（type=\(site.type)，api=\(site.api.prefix(40))）")
        }
    }

    private func begin(_ s: Spider, _ site: TVBoxSite) throws {
        switch site.kind {
        case .jar: break // initialised on the paired device
        case .remote: try s.start(ext: site.ext) // sent to another host: never read through the loopback server
        case .py:
            let (_, ext) = try PySpider.script(site.api, site.ext)
            try s.start(ext: served(ext))
        default: try s.start(ext: served(site.ext))
        }
    }

    /// Scripts fetch their parameters themselves: imported files reach them through the loopback server.
    private func served(_ ext: String) -> String {
        guard ext.contains("clan://localhost/") else { return ext }
        return ext.replacingOccurrences(of: "clan://localhost/", with: "http://127.0.0.1:\(proxyPort)/file/")
    }

    private func call<T>(_ ref: SiteRef, _ what: String, timeoutMs: Int? = nil, _ block: @escaping (Spider) throws -> T) async throws -> T {
        let t = timeoutMs ?? ref.site.timeoutMs
        // a session evicted between lookup and use is simply started again
        do { return try await session(ref).call(t, what, block) } catch is SpiderStopped { return try await session(ref).call(t, what, block) }
    }

    /// Loads a site's spider ahead of use (last-used site at app start).
    func preload(_ uid: String) {
        guard let ref = site(uid), !ref.site.kind.isCode || ref.repo.trusted else { return }
        Task.detached(priority: .utility) { [self] in try? await session(ref).warm() }
    }

    func status(_ uid: String) -> SpiderStatus {
        locked { () -> SpiderStatus in
            guard let r = sites[uid], let s = sessions[r.repo.id + "/" + uid], !s.dead else { return .idle }
            return s.ready ? .ready : .loading
        }
    }

    private func fixer(_ ref: SiteRef) -> (String) -> String {
        { [weak self] u in
            if u.hasPrefix("proxy://") || u.contains("127.0.0.1:9978") || u.contains("localhost:9978") { return VodMapper.localProxy(u, self?.proxyPort ?? 0, ref.site.key) }
            return u.hasPrefix("//") ? "https:" + u : u
        }
    }

    // MARK: Vod

    private func stream<T>(_ body: @escaping (@escaping (Snapshot<T>) -> Void) async throws -> Void) -> AsyncThrowingStream<Snapshot<T>, Error> {
        AsyncThrowingStream { c in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await body { c.yield($0) }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    private func swr<T>(_ owner: String, _ key: String, _ force: Bool, usable: (T) -> Bool, map: (String) throws -> T, emit: (Snapshot<T>) -> Void, load: () async throws -> String) async throws {
        var old: T?
        if let hit = cache.get(owner, key), let v = try? map(hit.text), usable(v) {
            let fresh = !force && hit.ageMs < Self.freshMs
            emit(Snapshot(value: v, fresh: fresh))
            if fresh { return }
            old = v
        }
        do {
            let text = try await load()
            let value = try map(text)
            if usable(value) { cache.put(owner, key, text) } else if let old {
                // an empty answer does not replace what works
                emit(Snapshot(value: old, fresh: true, error: "站点没有返回内容"))
                return
            }
            emit(Snapshot(value: value, fresh: true))
        } catch {
            try Task.checkCancellation()
            guard let old, !(error is CancellationError) else { throw error }
            emit(Snapshot(value: old, fresh: true, error: SpiderErrors.text(error)))
        }
    }

    /// Cached home first, then the refreshed one; without a cached one the categories come ahead of the recommended rail.
    func home(_ uid: String, force: Bool = false) -> AsyncThrowingStream<Snapshot<VodHome>, Error> {
        stream { [self] emit in
            let ref = try need(uid)
            let fix = fixer(ref)
            var shown = false
            func show(_ s: Snapshot<VodHome>) {
                shown = true
                locked { homes[uid] = s.value }
                emit(s)
            }
            try await swr(uid, "home", force, usable: { (h: VodHome) in !h.categories.isEmpty || !h.items.isEmpty }, map: { text in
                VodMapper.home(try VodMapper.root(text, "首页"), uid, ref.site.categories, fix)
            }, emit: show, load: {
                let o = try VodMapper.root(try await call(ref, "首页") { try $0.homeContent(filter: true) }, "首页")
                // the recommended rail is a second call for most spiders; its failure or delay never hides the categories
                let cms = ref.site.kind == .cmsJson || ref.site.kind == .cmsXml
                if cms || (o.optJSONArray("list") ?? []).isEmpty {
                    var early = VodMapper.home(o, uid, ref.site.categories, fix)
                    if cms { early.items = [] } // without covers
                    if !shown, !early.categories.isEmpty { show(Snapshot(value: early, fresh: false)) }
                    var more = ""
                    do { more = try await call(ref, "推荐") { try $0.homeVideoContent() } } catch {
                        try Task.checkCancellation()
                        if !o.has("class") { throw error }
                    }
                    if let list = (try? VodMapper.root(more, "推荐"))?.optJSONArray("list"), !list.isEmpty { o.put("list", list) }
                }
                return o.toString()
            })
        }
    }

    /// First pages come from the cache first; deeper pages are always fetched.
    func category(_ uid: String, _ tid: String, _ page: Int, _ extend: [String: String] = [:], force: Bool = false) -> AsyncThrowingStream<Snapshot<VodPage>, Error> {
        stream { [self] emit in
            let ref = try need(uid)
            let fix = fixer(ref)
            let load = { () async throws -> String in try await self.call(ref, "分类") { try $0.categoryContent(tid: tid, pg: String(page), filter: true, extend: extend) } }
            if page > 1 {
                emit(Snapshot(value: VodMapper.page(try VodMapper.root(try await load(), "分类"), uid, page, fix), fresh: true))
                return
            }
            let key = "cat|\(tid)|" + extend.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            try await swr(uid, key, force, usable: { (p: VodPage) in !p.items.isEmpty }, map: { VodMapper.page(try VodMapper.root($0, "分类"), uid, 1, fix) }, emit: emit, load: load)
        }
    }

    func search(_ uid: String, _ key: String, page: Int = 1, quick: Bool = false) async throws -> VodPage {
        let ref = try need(uid)
        let text = try await call(ref, "搜索") { try $0.searchContent(key: key, quick: quick, pg: String(page)) }
        return VodMapper.page(try VodMapper.root(text, "搜索"), uid, page, fixer(ref))
    }

    /// Results per site in the order they arrive: bounded parallelism, own deadline per site, no barrier.
    func searchAll(_ uids: [String], _ key: String, parallel: Int = 8) -> AsyncStream<SearchHit> {
        AsyncStream { c in
            let task = Task.detached(priority: .userInitiated) { [self] in
                let gate = AsyncGate(parallel)
                await withTaskGroup(of: Void.self) { group in
                    for uid in uids {
                        guard let ref = site(uid) else { continue }
                        group.addTask {
                            let hit = try? await gate.run { try await self.hit(ref, uid, key) }
                            if let hit { c.yield(hit) }
                        }
                    }
                }
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    private func hit(_ ref: SiteRef, _ uid: String, _ key: String) async throws -> SearchHit {
        do {
            let text = try await call(ref, "搜索", timeoutMs: min(ref.site.timeoutMs, Self.searchTimeoutMs)) { try $0.searchContent(key: key, quick: true, pg: "1") }
            return SearchHit(ref: ref, items: VodMapper.items(try VodMapper.root(text, "搜索"), uid, fixer(ref)), error: nil)
        } catch {
            try Task.checkCancellation()
            return SearchHit(ref: ref, items: [], error: SpiderErrors.text(error))
        }
    }

    func detail(_ uid: String, _ id: String) async throws -> HGSeriesDetail {
        let ref = try need(uid)
        let text = try await call(ref, "详情") { try $0.detailContent(ids: [id]) }
        return try VodMapper.detail(try VodMapper.root(text, "详情"), uid, id, ref.site, fixer(ref))
    }

    func action(_ uid: String, _ action: String) async throws -> String {
        try await call(try need(uid), "操作") { try $0.action(action) }
    }

    func resolve(_ uid: String, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        guard let e = TVBoxId.parseEpisode(ep.vid) else { throw ProviderError.invalid("剧集编号无效") }
        let ref = try need(uid)
        var media = ep.media.flatMap { LenientJson.objectOrNull($0) }
        if (media?.string("id") ?? "").isEmpty {
            // an episode restored from history has no media: it is looked up again
            let d = try await detail(uid, e.id)
            media = e.line < d.lines.count && e.index < d.lines[e.line].episodes.count ? d.lines[e.line].episodes[e.index].media.flatMap { LenientJson.objectOrNull($0) } : nil
        }
        guard let m = media, !m.string("id").isEmpty else { throw TVBoxError("站点没有给出这一集的播放地址") }
        return try await play(ref, ep.vid, m.string("f"), m.string("id"))
    }

    private func play(_ ref: SiteRef, _ vid: String, _ flag: String, _ id: String) async throws -> HGResolvedVideo {
        if let p = TVBoxUrl.p2p(id) { throw TVBoxError("\(p) 链接需要 P2P 内核，暂不支持") }
        let config = ref.repo.config
        let text = try await call(ref, "播放") { try $0.playerContent(flag: flag, id: id, vipFlags: config.flags) }
        if text.trimmed.isEmpty { throw ProviderError.upstream("站点没有返回播放信息") }
        let r = try PlayerResult.parse(text)
        var manual: ParseChain.Manual?
        if r.parse == 1, ref.site.kind.isCode, (try? await call(ref, "校验", { try $0.manualVideoCheck() })) ?? false {
            manual = { [weak self] u in (try? await self?.call(ref, "校验") { try $0.isVideoFormat(u) }) ?? false }
        }
        let parsed = try await chain(ref.repo, config.jarOf(ref.site)).resolve(r, flag, click: ref.site.click, manual: manual)
        let fix = fixer(ref)
        let subs = r.subs.map { s -> HGSubtitle in var c = s; c.url = fix(s.url); return c }
        let headers = ref.site.headers.merging(parsed.headers) { $1 }
        var streams: [HGStream] = [], refused: Error?
        for (i, u) in parsed.urls.enumerated() {
            let name = u.name.nonEmptyOr(parsed.urls.count > 1 ? "画质 \(i + 1)" : parsed.via.nonEmptyOr(flag))
            do { if let s = try stream(ref.repo, "tvb\(i)", name, TVBoxUrl.vod(fix(u.url)), headers, subs, r.format) { streams.append(s) } } catch { refused = error }
        }
        guard let first = streams.first else { throw refused ?? ProviderError.upstream(r.message.nonEmptyOr("没有可播放的地址")) }
        return HGResolvedVideo(vid: vid, url: first.url, key: nil, duration: nil, expiresAt: nil, err: nil, streams: streams, danmaku: r.danmaku.nilIfEmpty.map(fix))
    }

    private func chain(_ repo: RepoRuntime, _ jar: String) -> ParseChain {
        var parsers: JarParsers?
        if let host = platform.jar, host.paired, repo.trusted, !SpiderRef.parse(jar).isEmpty { parsers = BridgeParsers(host: host, jar: jar, session: { [self] in parseSession(repo) }) }
        return ParseChain(config: repo.config, http: http(repo), sniffer: platform.sniffer, jar: parsers, allowPrivate: repo.allowPrivate, preferred: repo.parse)
    }

    /// 解析 types 2 and 3 on the paired device.
    private struct BridgeParsers: JarParsers {
        let host: JarHost
        let jar: String
        let session: () -> SpiderSession

        func json(_ key: String, _ jxs: [String: String], _ url: String) async throws -> JSONObject? { try await call("jsonExt", [key, jxs, url]) }
        func mix(_ key: String, _ name: String, _ flag: String, _ jxs: [String: [String: String]], _ url: String) async throws -> JSONObject? { try await call("jsonExtMix", [key, name, flag, jxs, url]) }

        private func call(_ method: String, _ args: [Any]) async throws -> JSONObject? {
            let host = self.host, jar = self.jar
            return LenientJson.objectOrNull(try await session().call(20_000, "解析") { _ in try host.parse(jar: jar, method: method, args: args) })
        }
    }

    private final class NoSpider: Spider {}

    /// Jar parse extensions run on their own thread so a slow one never blocks the site's spider.
    private func parseSession(_ repo: RepoRuntime) -> SpiderSession {
        locked {
            let key = repo.id + "/parse"
            if let s = sessions[key], !s.dead { return s }
            let s = SpiderSession("解析", create: { NoSpider() })
            sessions[key] = s
            return s
        }
    }

    private func stream(_ repo: RepoRuntime, _ id: String, _ name: String, _ s: TVBoxUrl.Stream, _ headers: [String: String], _ subs: [HGSubtitle], _ format: String) throws -> HGStream? {
        if s.url.isEmpty { return nil }
        if let p = TVBoxUrl.p2p(s.url) { throw TVBoxError("\(p) 链接需要 P2P 内核，暂不支持") }
        if let why = LanPolicy.refusal(s.url, lan: repo.allowPrivate, own: runningPort, bridge: platform.jar?.address ?? "") { throw TVBoxError(why) }
        let host = TVBoxUrl.host(s.url)
        var all = headers.merging(s.headers) { $1 }
        for rule in repo.config.headers where rule.matches(host) { all.merge(rule.headers) { $1 } }
        let l = s.url.lowercased()
        let path = l.substringBefore("?").substringBefore("#")
        let hls = format.containsIgnoringCase("mpegurl") || (format.isEmpty && l.contains(".m3u8"))
        var mime = format.nilIfEmpty
        if mime == nil {
            if hls { mime = "application/x-mpegURL" }
            else if path.hasSuffix(".mpd") { mime = "application/dash+xml" }
            else if path.hasSuffix(".flv") { mime = "video/x-flv" }
            else if path.hasSuffix(".mkv") { mime = "video/x-matroska" }
        }
        return HGStream(streamId: id, quality: name.nilIfEmpty ?? s.label.nilIfEmpty, url: s.url, key: "", kind: hls ? .hls : .mp4Clear, headers: all, subtitles: subs, format: mime, lan: repo.allowPrivate)
    }

    /// Round trip of a site's cheapest call, in milliseconds.
    func latency(_ uid: String) async throws -> Int {
        let ref = try need(uid)
        let filter = !ref.site.kind.isCode
        let t = DispatchTime.now().uptimeNanoseconds
        _ = try await call(ref, "测速") { try $0.homeContent(filter: filter) }
        return max(1, Int((DispatchTime.now().uptimeNanoseconds - t) / 1_000_000))
    }

    /// Streams measurements as they finish (-1 = failed).
    func latencies(_ uids: [String], parallel: Int = 6) -> AsyncStream<(uid: String, ms: Int)> {
        AsyncStream { c in
            let task = Task.detached(priority: .utility) { [self] in
                let gate = AsyncGate(parallel)
                await withTaskGroup(of: Void.self) { group in
                    for uid in uids {
                        group.addTask {
                            let ms = try? await gate.run { () async throws -> Int in
                                do { return try await self.latency(uid) } catch {
                                    try Task.checkCancellation()
                                    return -1
                                }
                            }
                            if let ms { c.yield((uid, ms)) }
                        }
                    }
                }
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Live

    private func parseLive(_ ref: LiveRef, _ text: String) -> LiveData {
        if let m = locked({ () -> (text: String, data: LiveData, used: Date)? in
            liveMemory[ref.uid]?.used = Date()
            return liveMemory[ref.uid]
        }), m.data.ref.repo === ref.repo, m.text == text { return m.data }
        var list = LiveParser.parse(text, skipPass: ref.live.pass)
        list.groups = list.groups.compactMap { g in
            if ContentFilter.isBlocked([g.name]) { return nil }
            var c = g
            c.channels.removeAll { ContentFilter.isBlocked([$0.name]) }
            return c.channels.isEmpty ? nil : c
        }
        let d = LiveData(ref, list)
        locked {
            liveMemory[ref.uid] = (text, d, Date())
            while liveMemory.count > Self.maxLiveLists, let old = liveMemory.min(by: { $0.value.used < $1.value.used })?.key { liveMemory[old] = nil }
        }
        return d
    }

    private func fetchLive(_ ref: LiveRef) async throws -> String {
        let live = ref.live
        if live.kind != nil {
            let site = TVBoxSite(key: "live_" + live.name, name: live.name, type: 3, api: live.api, ext: live.ext, jar: live.jar, timeoutMs: live.timeoutMs)
            let s = session(ref.repo.id + "/live-" + ref.uid, site, ref.repo, "live-" + ref.uid, ref.repo.config.jarOf(live))
            return try await s.call(max(live.timeoutMs, 20_000), "直播列表") { try $0.liveContent(url: live.url) }
        }
        let r = try await http(ref.repo).fetch(NetRequest(url: live.url, headers: live.requestHeaders, timeoutMs: max(live.timeoutMs, 12_000)))
        if !r.ok { throw ProviderError.upstream("直播列表 HTTP \(r.code)") }
        return try TVBoxDecoder.decode(r.body)
    }

    func liveChannels(_ uid: String, force: Bool = false) -> AsyncThrowingStream<Snapshot<LiveData>, Error> {
        stream { [self] emit in
            let ref = try needLive(uid)
            if !ref.live.groups.isEmpty, ref.live.url.isEmpty, ref.live.api.isEmpty {
                emit(Snapshot(value: LiveData(ref, LiveList(groups: ref.live.groups)), fresh: true))
                return
            }
            try await swr("live-" + uid, "list", force, usable: { (d: LiveData) in !d.list.groups.isEmpty }, map: { parseLive(ref, $0) }, emit: emit, load: { try await fetchLive(ref) })
        }
    }

    /// Current list (cached when there is one; a stale one is refreshed behind the caller's back).
    func liveList(_ uid: String) async throws -> LiveData {
        for try await s in liveChannels(uid) where !s.value.list.groups.isEmpty {
            if !s.fresh { refreshLive(uid) }
            return s.value
        }
        try Task.checkCancellation()
        throw ProviderError.upstream("直播列表为空")
    }

    /// One at a time per list: the player asks for its guide every minute.
    private func refreshLive(_ uid: String) {
        guard locked({ liveRefreshes.insert(uid).inserted }) else { return }
        Task.detached(priority: .utility) { [self] in
            do { for try await _ in liveChannels(uid, force: true) {} } catch {}
            locked { _ = liveRefreshes.remove(uid) }
        }
    }

    /// The channel that was at `index` when the list was last shown.
    func listedChannel(_ uid: String, _ index: Int) -> ChannelKey? {
        locked { listed[uid].flatMap { $0.indices.contains(index) ? $0[index] : nil } }
    }

    /// Contract §1: channels as episodes. Locked groups stay out unless `unlocked` holds their name.
    func liveDetail(_ uid: String, unlocked: Set<String>) async throws -> HGSeriesDetail {
        let d = try await liveList(uid)
        let live = d.ref.live
        var eps: [HGEpisode] = [], keys: [ChannelKey] = []
        for g in d.list.groups where g.pass.isEmpty || unlocked.contains(g.name) {
            for c in g.channels {
                eps.append(HGEpisode(ep: eps.count + 1, vid: TVBoxId.channel(uid, eps.count), duration: 0, title: c.name, page: g.name, media: media(d, c)))
                keys.append(ChannelKey(group: g.name, name: c.name, url: c.urls.first ?? ""))
            }
        }
        if eps.isEmpty { throw TVBoxError("没有可以播放的频道") }
        locked {
            if listed.count > 8 { listed.removeAll() }
            listed[uid] = keys
        }
        return HGSeriesDetail(source: .tvboxLive(uid), seriesId: uid, title: live.name, cover: live.logo.contains("{") ? "" : live.logo, author: nil, actors: [], onlineTime: 0,
                              totalEps: eps.count, episodes: eps, episodeLabel: "共\(eps.count)个频道", isLive: true)
    }

    private func epgOf(_ d: LiveData) -> String { d.ref.live.epg.nonEmptyOr(d.list.epg) }
    private func catchupOf(_ d: LiveData, _ c: LiveChannel) -> Catchup? { c.catchup ?? d.list.catchup ?? d.ref.live.catchup ?? c.urls.first.flatMap(Catchup.implied) }

    private func media(_ d: LiveData, _ c: LiveChannel) -> String {
        var x = c
        if x.logo.isEmpty, d.ref.live.logo.contains("{name}") { x.logo = EpgParser.url(d.ref.live.logo, c.guideName, "", c.tvgId) }
        return x.mediaJSON(d.ref.live.requestHeaders, epgOf(d), catchupOf(d, c))
    }

    func resolveLive(_ uid: String, _ ep: HGEpisode, unlocked: Set<String>) async throws -> HGResolvedVideo {
        let ref = try needLive(uid)
        var media = ep.media.flatMap { LenientJson.objectOrNull($0) }
        if media == nil {
            let eps = try await liveDetail(uid, unlocked: unlocked).episodes
            let place = TVBoxId.liveIndex(ep.vid), i = ChannelKey(ep).index(in: eps, near: place) ?? place
            if eps.indices.contains(i) { media = eps[i].media.flatMap { LenientJson.objectOrNull($0) } }
        }
        guard let o = media else { throw TVBoxError("频道不存在") }
        let headers = TVBoxConfig.headerMap(o["headers"]), format = o.string("format")
        let urls = J.arr(o["urls"]).map { J.str($0) }.filter { !$0.isEmpty }
        var streams: [HGStream] = [], refused: Error?
        for (i, raw) in urls.enumerated() {
            let u = raw.hasPrefix("proxy://") || raw.contains(":9978/proxy") ? VodMapper.localProxy(raw, proxyPort, "") : raw
            if TVBoxUrl.p2p(u) != nil { continue }
            let s = TVBoxUrl.stream(u)
            do { if let x = try stream(ref.repo, "tvl\(i)", s.label.nonEmptyOr("线路 \(i + 1)"), s, headers, [], format) { streams.append(x) } } catch { refused = error }
        }
        guard let first = streams.first else {
            throw refused ?? TVBoxError(urls.first.map { "\(TVBoxUrl.p2p($0) ?? "该") 链接需要 P2P 内核，暂不支持" } ?? "频道没有播放地址")
        }
        if J.int(o["parse"]) != 1 { return Self.resolved(ep.vid, streams) }
        let click = o.string("click")
        let config = ref.repo.config
        let found = try await platform.sniffer.sniff(SniffRequest(url: first.url, headers: first.headers, scripts: click.isEmpty ? [] : [click], rules: config.rules, ads: config.ads, allowPrivate: ref.repo.allowPrivate))
        guard let real = try stream(ref.repo, "tvl0", first.quality ?? "", TVBoxUrl.vod(found.url), found.headers, [], format) else { throw ProviderError.upstream("没有嗅探到播放地址") }
        return Self.resolved(ep.vid, [real] + streams.dropFirst())
    }

    private static func resolved(_ vid: String, _ streams: [HGStream]) -> HGResolvedVideo {
        HGResolvedVideo(vid: vid, url: streams.first?.url, key: nil, duration: nil, expiresAt: nil, err: nil, streams: streams)
    }

    /// Programmes of a channel on the day of `at`; empty when no guide is configured.
    func guide(_ uid: String, _ name: String, tvgId: String = "", tvgName: String = "", at: Int64 = Catchup.nowMs) async throws -> [Programme] {
        let d: LiveData
        do { d = try await liveList(uid) } catch {
            try Task.checkCancellation()
            return []
        }
        var ch = LiveChannel(name: name, urls: [], tvgId: tvgId, tvgName: tvgName)
        search: for g in d.list.groups {
            for c in g.channels where c.name == name && (tvgId.isEmpty || c.tvgId == tvgId) {
                ch = c
                break search
            }
        }
        let source = ch.epg.nonEmptyOr(epgOf(d))
        if source.isEmpty { return [] }
        return try await epg.programmes(http(d.ref.repo), source, ch, d.guideKeys, at, zone(d.ref.live))
    }

    private func zone(_ live: TVBoxLive) -> TimeZone { live.timeZone.isEmpty ? .current : TimeZone(identifier: live.timeZone) ?? TimeZone(abbreviation: live.timeZone) ?? .current }

    /// Replay streams of a finished programme, one per line whose template works.
    func catchup(_ uid: String, _ ep: HGEpisode, _ p: Programme) -> HGResolvedVideo? {
        guard let ref = live(uid), let o = ep.media.flatMap({ LenientJson.objectOrNull($0) }) else { return nil }
        let c = o.optJSONObject("catchup").flatMap(Catchup.fromJSON)
        let headers = TVBoxConfig.headerMap(o["headers"])
        var streams: [HGStream] = []
        for (i, raw) in J.arr(o["urls"]).map({ J.str($0) }).enumerated() {
            let s = TVBoxUrl.stream(raw)
            guard let u = (c ?? Catchup.implied(s.url))?.url(s.url, p.start, p.end, zone: zone(ref.live)),
                  let x = try? stream(ref.repo, "tvc\(i)", s.label.nonEmptyOr("线路 \(i + 1)"), .init(url: u, headers: s.headers, label: ""), headers, [], o.string("format")) else { continue }
            streams.append(x)
        }
        return streams.isEmpty ? nil : Self.resolved("\(ep.vid)@\(p.start)", streams)
    }

    // MARK: Proxy

    /// Handler of the loopback server (query and lower-cased request headers merged). Blocking; runs on the server's thread.
    func proxy(_ params: [String: String]) -> ProxyReply {
        let kind = params["do"] ?? ""
        switch kind {
        case "ck": return .text("ok")
        case "file": return file(params["path"] ?? "")
        case "live": return liveProxy(params)
        default: break
        }
        let siteKey = params["siteKey"] ?? ""
        let script = kind == "js" || kind == "py"
        let ref = script || !siteKey.isEmpty ? proxyTarget(kind == "js" ? .js : kind == "py" ? .py : .jar, siteKey) : nil
        if script && ref == nil { return .text("没有找到站点 \(siteKey)", code: 404) }
        guard let ref else { return .text("no handler", code: 404) }
        do {
            let block: (Spider) throws -> ProxyReply? = { try $0.proxyLocal(params) }
            var reply: ProxyReply?
            do { reply = try session(ref).callBlocking(30_000, "代理", block) } catch is SpiderStopped { reply = try session(ref).callBlocking(30_000, "代理", block) }
            return reply ?? .text("no handler", code: 404)
        } catch { return .text(SpiderErrors.text(error), code: 500) }
    }

    /// `clan://localhost/<path>` for scripts.
    private func file(_ path: String) -> ProxyReply {
        guard let f = net.localFile("clan://localhost/" + TVBoxUrl.encode(path)), let d = try? Data(contentsOf: f, options: .mappedIfSafe) else { return .text("not found", code: 404) }
        return ProxyReply(body: d, length: Int64(d.count))
    }

    /// The live spider a proxied address belongs to: same key, loaded sessions and the active config first.
    private func proxyTarget(_ kind: SiteKind, _ key: String) -> SiteRef? {
        let (all, active) = locked { (Array(sites.values), activeRepo) }
        let mine = all.filter { $0.repo.trusted && $0.site.kind == kind && (key.isEmpty || $0.site.key == key || $0.uid == key) }
        func score(_ r: SiteRef) -> Int { (status(r.uid) == .ready ? 2 : 0) + (r.repo.id == active ? 1 : 0) }
        let ranked = mine.map { ($0, score($0)) }.filter { !key.isEmpty || $0.1 >= 2 }
        return ranked.max { $0.1 < $1.1 }?.0
    }

    private func liveProxy(_ params: [String: String]) -> ProxyReply {
        guard let repo = locked({ repos[activeRepo] }) else { return .text("no config", code: 404) }
        let url = TVBoxConfig.proxyLive("proxy://do=live&ext=" + (params["ext"] ?? ""))
        if url.isEmpty { return .text("bad ext", code: 400) }
        do {
            let r = try http(repo).execute(NetRequest(url: url))
            return ProxyReply(code: r.code, type: "text/plain; charset=utf-8", body: r.body, length: Int64(r.body.count))
        } catch { return .text(SpiderErrors.text(error), code: 502) }
    }

    // MARK: Lifecycle

    func clearCache(_ uid: String) { cache.clear(uid) }
    func trimCaches() { cache.trim() }

    /// Drops a config's running spiders and cached scripts, so an explicit refresh really runs the newest code.
    func restart(_ repoId: String) {
        scriptCache.clear()
        locked { drop { $0 == repoId } }.forEach { $0.close() }
    }

    func shutdown() {
        let all = locked { () -> [SpiderSession] in
            defer { sessions.removeAll() }
            return Array(sessions.values)
        }
        all.forEach { $0.close() }
    }
}
