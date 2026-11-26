import Combine
import Foundation
import UIKit

/// One imported config for the UI: what is persisted about it plus its parsed content.
struct TVBoxRepo: Identifiable {
    let record: RepoRecord
    let config: TVBoxConfig
    let error: String?
    let sites: [TVBoxSiteRef]
    let lives: [TVBoxLiveRef]
    let hasCode: Bool

    init(_ record: RepoRecord, _ config: TVBoxConfig, error: String? = nil) {
        self.record = record
        self.config = config
        self.error = error
        sites = RepoRuntime.siteRefs(record.id, config)
        lives = RepoRuntime.liveRefs(record.id, config)
        hasCode = config.hasCode
    }

    private init(_ old: TVBoxRepo, _ record: RepoRecord) {
        self.record = record
        config = old.config
        error = old.error
        sites = old.sites
        lives = old.lives
        hasCode = old.hasCode
    }

    /// Same content, changed choices.
    func with(_ record: RepoRecord) -> TVBoxRepo { TVBoxRepo(self, record) }

    var id: String { record.id }
    var name: String { record.name }
    var trusted: Bool { record.trust == .trusted }
    var needsTrust: Bool { hasCode && record.trust == .ask }
    func enabled(_ uid: String) -> Bool { !record.disabled.contains(uid) }
}

enum ImportResult {
    case imported(TVBoxRepo)
    /// The address is a list of configs: the user picks one.
    case depot(DepotRecord, nested: Bool)
    /// A jar / script / list saved for local configs to reference.
    case attachment(String)
}

/// Values that change many times a second while something runs: rows observe this, pages do not.
@MainActor
final class TVBoxMeters: ObservableObject {
    /// Milliseconds per site uid (-1 = failed).
    @Published fileprivate(set) var latency: [String: Int] = [:]
    @Published fileprivate(set) var testing = false
    @Published fileprivate(set) var status: [String: TVBoxEngine.SpiderStatus] = [:]

    /// Pulls the spider state of the rows on screen.
    func refreshStatus(_ uids: [String]) {
        var next = status
        for u in uids { next[u] = TVBoxStore.engine.status(u) }
        if next != status { status = next }
    }
}

/// Everything the app knows about TVBox: persisted configs and choices, and the engine that runs them. Files are read and
/// written in the background only; importing never contacts the sites.
@MainActor
final class TVBoxStore: ObservableObject {
    static let shared = TVBoxStore()

    // MARK: Shared, any thread

    nonisolated private static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tvbox", isDirectory: true)
    nonisolated private static let stateFile = root.appendingPathComponent("tvbox_store_v2.json")
    nonisolated private static let localDir = root.appendingPathComponent("local", isDirectory: true)
    nonisolated private static let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    /// Single writer: state files never interleave.
    nonisolated private static let disk = DispatchQueue(label: "stv.tvbox.disk", qos: .utility)

    nonisolated private static let net: TVBoxNet = TVBoxNet(localDir, ownPort: { TVBoxStore.engine.runningPort })
    nonisolated static let engine: TVBoxEngine = TVBoxEngine(net, platform: TVBoxRuntime.platform, cache: TVBoxCache(caches.appendingPathComponent("tvbox", isDirectory: true)),
                                                scripts: root.appendingPathComponent("scripts", isDirectory: true), epgDir: caches.appendingPathComponent("tvbox-epg", isDirectory: true))

    nonisolated static func site(_ uid: String) -> TVBoxSite? { engine.site(uid)?.site }
    nonisolated static func live(_ uid: String) -> TVBoxLive? { engine.live(uid)?.live }

    nonisolated private static let adultLock = NSLock()
    nonisolated(unsafe) private static var adultUids: Set<String>?
    nonisolated private static let adultKey = "stv.tvbox.adult"

    /// Known before the configs are read and after they are removed, so history rows of adult sites never show up unasked.
    nonisolated static func isAdult(_ uid: String) -> Bool {
        if let s = site(uid) { return s.adult }
        adultLock.lock()
        defer { adultLock.unlock() }
        if adultUids == nil { adultUids = Set(UserDefaults.standard.stringArray(forKey: adultKey) ?? []) }
        return adultUids?.contains(uid) ?? false
    }

    nonisolated private static func rememberAdult(_ uids: [String]) {
        adultLock.lock()
        defer { adultLock.unlock() }
        let old = adultUids ?? Set(UserDefaults.standard.stringArray(forKey: adultKey) ?? [])
        let all = old.union(uids)
        adultUids = all
        if all != old { UserDefaults.standard.set(Array(all), forKey: adultKey) }
    }

    nonisolated private static func onDisk<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in disk.async { c.resume(with: Result(catching: body)) } }
    }

    // MARK: Published state

    @Published private(set) var state = TVBoxState()
    @Published private(set) var repos: [TVBoxRepo] = []
    /// False until the persisted configs have been read.
    @Published private(set) var loaded = false
    /// The chosen DoH server does not answer: the system resolver is in use.
    @Published private(set) var dohError: String?
    let meters = TVBoxMeters()

    var activeRepo: TVBoxRepo? { repos.first { $0.id == state.active } ?? repos.first }

    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pending: Task<Void, Never>?
    private var speed: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        Task { await boot() }
    }

    /// Returns once the persisted configs are known to the engine.
    func ready() async {
        if loaded { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    // MARK: Start

    private struct Stored {
        var state = TVBoxState()
        var repos: [TVBoxRepo] = []
        var watches: [LegacyWatch] = []
    }

    private func boot() async {
        let s = (try? await Self.onDisk { Self.read() }) ?? Stored()
        state = s.state
        repos = s.repos
        meters.latency = s.state.latency
        pushEngine()
        loaded = true
        let queue = waiters
        waiters = []
        queue.forEach { $0.resume() }
        if !s.watches.isEmpty { importWatches(s.watches) }
        if !state.doh.isEmpty { applyDoh() }
        // the site the user will most likely look at is warmed up off the main thread
        if let r = activeRepo, let uid = state.lastSite[r.id] { Self.engine.preload(uid) }
        Self.disk.async { Self.engine.trimCaches() }
    }

    nonisolated private static func repoFile(_ id: String) -> URL {
        root.appendingPathComponent("repos", isDirectory: true).appendingPathComponent(String(id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) + ".json")
    }

    nonisolated private static func write(_ f: URL, _ data: Data) throws {
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    nonisolated private static func read() -> Stored {
        var out = Stored()
        let fm = FileManager.default
        if let data = try? Data(contentsOf: stateFile) {
            if let o = LenientJson.objectOrNull(String(decoding: data, as: UTF8.self)) { out.state = TVBoxState.fromJSON(o) }
            else { try? fm.moveItem(at: stateFile, to: stateFile.appendingPathExtension("bad")) }
        } else {
            let v1 = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tvbox_store_v1.json")
            var old = (try? Data(contentsOf: v1)).flatMap { LenientJson.objectOrNull(String(decoding: $0, as: UTF8.self)) }
            if J.arr(old?["repos"]).isEmpty { old = legacyCms() ?? old }
            if let old {
                let m = TVBoxState.migrateV1(old)
                for (id, text) in m.configs { try? write(repoFile(id), Data(text.utf8)) }
                out.state = m.state
                out.watches = m.watches
                do {
                    try write(stateFile, Data(m.state.toJSON().toString().utf8))
                    try? fm.removeItem(at: v1.appendingPathExtension("migrated"))
                    try? fm.moveItem(at: v1, to: v1.appendingPathExtension("migrated"))
                } catch {}
            }
        }
        out.repos = out.state.repos.map(parseRepo)
        return out
    }

    /// Sites of even older builds lived among the 采集站.
    nonisolated private static func legacyCms() -> JSONObject? {
        let all = UserDefaults.standard.data(forKey: "stv.cms.sites").flatMap { try? JSONDecoder().decode([CMSSite].self, from: $0) } ?? []
        let mine = all.filter { $0.origin.hasPrefixIgnoringCase("TVBox") }
        if mine.isEmpty { return nil }
        let sites = mine.map { JSONObject().put("key", $0.key).put("name", $0.name).put("api", $0.api).put("adult", $0.adult).put("enabled", $0.enabled) }
        return JSONObject().put("activeRepoId", "legacy-tvbox").put("repos", [JSONObject().put("id", "legacy-tvbox").put("name", "已导入 TVBox").put("url", "").put("sites", sites)])
    }

    nonisolated private static func parseRepo(_ record: RepoRecord) -> TVBoxRepo {
        do {
            let text = String(decoding: try Data(contentsOf: repoFile(record.id)), as: UTF8.self)
            if case .config(let c) = try TVBoxConfig.parse(text, record.base) { return TVBoxRepo(record, c) }
            return TVBoxRepo(record, TVBoxConfig(), error: "配置内容已损坏，请刷新")
        } catch { return TVBoxRepo(record, TVBoxConfig(), error: SpiderErrors.text(error)) }
    }

    private func importWatches(_ list: [LegacyWatch]) {
        LibraryStore.shared.merge(list.map { w in
            WatchProgress(series: HGSeries(source: .tvbox(w.uid), seriesId: w.vodId, title: w.title, cover: w.cover, orientation: "portrait"), episodeIndex: w.episodeIndex, episodeNumber: w.episodeIndex + 1,
                          seconds: Double(w.positionMs) / 1000, duration: Double(w.durationMs) / 1000, updatedAt: Date(timeIntervalSince1970: Double(w.updatedAt) / 1000))
        })
    }

    // MARK: Persistence

    /// Swaps the state; the file is written shortly after the last change.
    private func update(push: Bool = false, _ change: (inout TVBoxState) -> Void) {
        var next = state
        change(&next)
        if next == state { return }
        state = next
        if push { pushEngine() }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { self?.flush() }
        }
    }

    private func flush() {
        guard loaded, pending != nil else { return }
        pending?.cancel()
        pending = nil
        let snap = state
        Self.disk.async { try? Self.write(Self.stateFile, Data(snap.toJSON().toString().utf8)) }
    }

    private func pushEngine() {
        let lan = state.allowLan
        Self.rememberAdult(repos.flatMap { r in r.sites.filter(\.site.adult).map(\.uid) })
        Self.engine.setRepos(repos.map { r in
            RepoRuntime(r.id, r.name, r.config, trusted: r.trusted, allowPrivate: lan || TVBoxNet.isPrivateAddress(r.record.base), parse: r.record.parse, local: r.record.url.isEmpty || TVBoxUrl.isLocal(r.record.base), sites: r.sites, lives: r.lives)
        }, active: activeRepo?.id ?? "", aliases: state.aliases)
    }

    private func replaceRecord(_ id: String, push: Bool, _ change: (inout RepoRecord) -> Void) {
        guard let i = repos.firstIndex(where: { $0.id == id }) else { return }
        var rec = repos[i].record
        change(&rec)
        if rec == repos[i].record { return }
        repos[i] = repos[i].with(rec)
        update(push: push) { s in if let k = s.repos.firstIndex(where: { $0.id == id }) { s.repos[k] = rec } }
    }

    // MARK: Import

    /// Address of a config, a depot or a channel list. `depot` is the list it was picked from.
    func importUrl(_ raw: String, depot: DepotRecord? = nil, nested: Bool = false, name: String = "") async throws -> ImportResult {
        await ready()
        let l = try await ConfigLoader(net: Self.net).load(raw, allowLan: state.allowLan)
        return try await accept(l.parsed, l.text, l.url, name, depot, nested)
    }

    /// Pasted text: a config, a channel list, or just an address.
    func importText(_ text: String, name: String = "") async throws -> ImportResult {
        let t = text.trimmed
        if !t.contains("\n"), TVBoxUrl.isHttp(t) || TVBoxUrl.isLocal(t) { return try await importUrl(t) }
        return try await importLocal(Data(t.utf8), fileName: "paste-\(RepoRecord.id(t)).json", name: name.nonEmptyOr("粘贴的配置"))
    }

    private static let attachments: Set<String> = ["jar", "js", "py", "dex", "png", "jpg", "jpeg", "gif", "zip"]

    /// A picked file: configs and lists are imported, anything else is kept for local configs to reference as `./name`.
    func importLocal(_ data: Data, fileName: String, name: String? = nil) async throws -> ImportResult {
        await ready()
        if data.count > 48 << 20 { throw ProviderError.invalid("文件过大") }
        let cleaned = fileName.components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|").union(.whitespacesAndNewlines)).filter { !$0.isEmpty }.joined(separator: "_")
        let safe = String(cleaned.suffix(80)).nonEmptyOr("config.json")
        let url = "clan://localhost/" + safe
        let file = Self.localDir.appendingPathComponent(safe)
        let keep = Self.attachments.contains(safe.substringAfterLast(".").lowercased())
        let parsed = try await Self.onDisk { () -> (ParsedConfig, String)? in
            var read: (ParsedConfig, String)?
            // a file that cannot be read leaves the one of the same name alone
            if !keep {
                let text = try TVBoxDecoder.decode(data)
                read = (try TVBoxConfig.parse(text, url), text)
            }
            try Self.write(file, data)
            return read
        }
        guard let (config, text) = parsed else { return .attachment(safe) }
        return try await accept(config, text, url, name ?? fileName.substringBeforeLast("."), nil, false)
    }

    /// A single 苹果 CMS site, collected in a config of its own.
    func addManualSite(name: String, api: String, adult: Bool) async throws -> ImportResult {
        await ready()
        let address = try ConfigLoader.normalize(api)
        guard TVBoxUrl.isHttp(address) else { throw ProviderError.invalid("需要 http(s) 的采集接口地址") }
        let old = try await Self.onDisk { (try? Data(contentsOf: Self.localDir.appendingPathComponent("manual.json"))).flatMap { LenientJson.objectOrNull(String(decoding: $0, as: UTF8.self)) } }
        var sites = J.arr(old?["sites"]).filter { ($0 as? JSONObject)?.string("api") != address }
        sites.append(JSONObject().put("key", RepoRecord.id(address)).put("name", name.trimmed.nonEmptyOr(TVBoxUrl.host(address))).put("type", 1).put("api", address).put("adult", adult))
        return try await importLocal(Data(JSONObject().put("sites", sites).toString().utf8), fileName: "manual.json", name: "自建配置")
    }

    private func accept(_ parsed: ParsedConfig, _ text: String, _ url: String, _ name: String, _ depot: DepotRecord?, _ nested: Bool) async throws -> ImportResult {
        switch parsed {
        case .depot(let entries):
            if nested { throw TVBoxError("多仓嵌套过深") }
            let d = DepotRecord(id: RepoRecord.id(url), name: name.nonEmptyOr(TVBoxUrl.host(url).nonEmptyOr("多仓")), url: url, entries: entries)
            if depot == nil {
                update { s in
                    s.depots.removeAll { $0.id == d.id }
                    s.depots.append(d)
                }
            }
            return .depot(d, nested: depot != nil)
        case .live:
            let empty = await Task.detached { LiveParser.parse(text).groups.isEmpty }.value
            if empty { throw ProviderError.invalid("没有识别到频道") }
            let title = name.nonEmptyOr(TVBoxUrl.fileName(url).substringBeforeLast(".").nonEmptyOr(TVBoxUrl.host(url))).nonEmptyOr("直播源")
            return try await store(JSONObject().put("lives", [JSONObject().put("name", title).put("url", url)]).toString(), url, title, depot)
        case .config(let c):
            return try await store(text, url, name.nonEmptyOr(c.name).nonEmptyOr(TVBoxUrl.host(url)).nonEmptyOr("TVBox 配置"), depot)
        }
    }

    private func store(_ text: String, _ url: String, _ title: String, _ depot: DepotRecord?) async throws -> ImportResult {
        let id = RepoRecord.id(url)
        // a migrated config keeps the id of its first import
        let known = repos.first { $0.id == id } ?? repos.first { !$0.record.url.isEmpty && $0.record.url == url }
        var record = known?.record ?? RepoRecord(id: id, name: String(title.prefix(60)), url: url)
        record.url = url
        record.depot = depot?.id ?? record.depot
        record.updatedAt = Catchup.nowMs
        let fresh = record
        var repo = try await Self.onDisk { () -> TVBoxRepo in
            var r = fresh
            let data = Data(text.utf8), file = Self.repoFile(r.id)
            // another file under the same name may be somebody else's code
            if TVBoxUrl.isLocal(url), let old = try? Data(contentsOf: file), old != data { r.trust = .ask }
            try Self.write(file, data)
            return Self.parseRepo(r)
        }
        record = repo.record
        var alias: [String: String] = [:]
        if !record.legacy.isEmpty {
            // first refresh of a migrated config: keep what the user had switched off under the sites' real ids
            alias = TVBoxState.aliases(record, repo.config)
            record.legacy = [:]
            record.disabled = Set(record.disabled.map { alias[$0] ?? $0 })
            repo = repo.with(record)
        }
        let rec = record
        repos = [repo] + repos.filter { $0.id != rec.id }
        update { s in
            s.repos = [rec] + s.repos.filter { $0.id != rec.id }
            s.active = rec.id
            s.aliases.merge(alias) { $1 }
        }
        pushEngine()
        return .imported(repo)
    }

    /// Re-reads a config from where it came from.
    func refresh(_ id: String) async throws -> ImportResult {
        guard let r = repos.first(where: { $0.id == id }) else { throw ProviderError.invalid("配置不存在") }
        if r.record.url.isEmpty { throw ProviderError.invalid("这个配置没有来源地址") }
        let keep = state.active
        let result = try await importUrl(r.record.url, depot: state.depots.first { $0.id == r.record.depot }, name: r.name)
        if !keep.isEmpty { select(keep) }
        let owners = r.sites.map(\.uid) + r.lives.map { "live-" + $0.uid }
        _ = try? await Self.onDisk { () -> Void in
            Self.engine.restart(id)
            owners.forEach { Self.engine.clearCache($0) }
        }
        return result
    }

    func openDepot(_ d: DepotRecord, _ e: TVBoxDepotEntry, nested: Bool) async throws -> ImportResult {
        try await importUrl(e.url, depot: d, nested: nested, name: e.name)
    }

    func select(_ id: String) {
        guard repos.contains(where: { $0.id == id }) else { return }
        update(push: true) { $0.active = id }
    }

    func rename(_ id: String, _ name: String) {
        let n = String(name.trimmed.prefix(60))
        if !n.isEmpty { replaceRecord(id, push: true) { $0.name = n } }
    }

    func remove(_ id: String) {
        guard let gone = repos.first(where: { $0.id == id }) else { return }
        repos.removeAll { $0.id == id }
        update { s in
            s.repos.removeAll { $0.id == id }
            let left = s.repos
            if s.active == id { s.active = left.first?.id ?? "" }
            s.lastSite[id] = nil
            s.lastLive[id] = nil
            s.depots.removeAll { d in d.id == gone.record.depot && !left.contains { $0.depot == d.id } }
        }
        pushEngine()
        Self.disk.async {
            try? FileManager.default.removeItem(at: Self.repoFile(id))
            if gone.record.url.hasPrefix("clan://"), let f = Self.net.localFile(gone.record.url) { try? FileManager.default.removeItem(at: f) }
            gone.sites.forEach { Self.engine.clearCache($0.uid) }
            gone.lives.forEach { Self.engine.clearCache("live-" + $0.uid) }
        }
    }

    func removeDepot(_ id: String) { update { $0.depots.removeAll { $0.id == id } } }

    // MARK: Choices

    func setTrust(_ id: String, _ t: Trust) { replaceRecord(id, push: true) { $0.trust = t } }
    func setEnabled(_ repoId: String, _ uid: String, _ on: Bool) { setAllEnabled(repoId, [uid], on) }
    func setAllEnabled(_ repoId: String, _ uids: [String], _ on: Bool) {
        replaceRecord(repoId, push: false) { r in r.disabled = on ? r.disabled.subtracting(uids) : r.disabled.union(uids) }
    }
    func setParse(_ repoId: String, _ name: String) { replaceRecord(repoId, push: true) { $0.parse = name } }
    func setAllowLan(_ on: Bool) { update(push: true) { $0.allowLan = on } }
    /// Empty = system resolver.
    func setDoh(_ name: String) {
        update { $0.doh = name }
        applyDoh()
    }
    func setLastSite(_ repoId: String, _ uid: String) { update { $0.lastSite[repoId] = uid } }
    func setLastLive(_ repoId: String, _ uid: String) { update { $0.lastLive[repoId] = uid } }

    var favoriteChannels: [String] { state.favorites }
    func isFavoriteChannel(_ name: String) -> Bool { state.favorites.contains(name) }
    func toggleFavoriteChannel(_ name: String) {
        update { s in
            let i = s.favorites.firstIndex(of: name)
            if let i { s.favorites.remove(at: i) } else { s.favorites.insert(name, at: 0) }
        }
    }

    func unlocked(_ liveUid: String) -> Set<String> { state.unlocked[liveUid] ?? [] }
    func unlock(_ liveUid: String, _ group: String) { update { _ = $0.unlocked[liveUid, default: []].insert(group) } }

    private static let builtinDoh = [
        TVBoxDoh(name: "阿里 DNS", url: "https://dns.alidns.com/dns-query", ips: ["223.5.5.5", "223.6.6.6"]),
        TVBoxDoh(name: "腾讯 DNS", url: "https://doh.pub/dns-query", ips: ["1.12.12.12", "120.53.53.53"]),
    ]

    /// Built-in resolvers plus the ones the active config suggests.
    func dohOptions() -> [TVBoxDoh] {
        var seen = Set<String>()
        return (Self.builtinDoh + (activeRepo?.config.doh ?? [])).filter { seen.insert($0.name).inserted }
    }

    private func applyDoh() {
        let choice = dohOptions().first { $0.name == state.doh }
        Task {
            let ok = await TVBoxNet.applyDoh(choice)
            dohError = ok ? nil : "\(choice?.name ?? "DoH") 没有响应，已使用系统 DNS"
        }
    }

    /// Sites the pickers show: enabled, not hidden by the config, adult ones only behind the gate.
    func visibleSites(_ repo: TVBoxRepo, adult: Bool) -> [TVBoxSiteRef] { repo.sites.filter { repo.enabled($0.uid) && !$0.site.hide && (adult || !$0.site.adult) } }
    func visibleLives(_ repo: TVBoxRepo) -> [TVBoxLiveRef] { repo.lives.filter { repo.enabled($0.uid) } }

    /// Series of a live list for `Route.play(series, channel)`.
    func liveSeries(_ l: TVBoxLiveRef) -> HGSeries { HGSeries(source: .tvboxLive(l.uid), seriesId: l.uid, title: l.live.name, cover: l.live.logo.contains("{") ? "" : l.live.logo, orientation: "landscape") }

    // MARK: Speed test

    func testSpeed(_ uids: [String]) {
        speed?.cancel()
        let again = Set(uids)
        meters.latency = meters.latency.filter { !again.contains($0.key) }
        meters.testing = true
        speed = Task { [weak self] in
            var batch: [String: Int] = [:]
            var shown = Date()
            for await r in Self.engine.latencies(uids) {
                batch[r.uid] = r.ms
                // rows fill in a few times a second, not once per answer
                if Date().timeIntervalSince(shown) > 0.15 {
                    self?.meters.latency.merge(batch) { $1 }
                    batch = [:]
                    shown = Date()
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.meters.latency.merge(batch) { $1 }
            self.finishSpeedTest()
        }
    }

    func stopSpeedTest() {
        speed?.cancel()
        finishSpeedTest()
    }

    private func finishSpeedTest() {
        speed = nil
        meters.testing = false
        let snap = meters.latency
        update { $0.latency = snap }
    }

    // MARK: Guide

    /// Programmes of the channel behind a live episode (`at`: any moment of the wanted day, epoch ms).
    func guide(_ liveUid: String, _ ep: HGEpisode, at: Int64 = Catchup.nowMs) async -> [Programme] {
        await ready()
        let o = ep.media.flatMap { LenientJson.objectOrNull($0) }
        return (try? await Self.engine.guide(liveUid, ep.title, tvgId: o?.string("tvgId") ?? "", tvgName: o?.string("tvgName") ?? "", at: at)) ?? []
    }

    /// 回看 streams of a past programme; nil when the channel has no catch-up.
    func catchup(_ liveUid: String, _ ep: HGEpisode, _ p: Programme) -> HGResolvedVideo? { Self.engine.catchup(liveUid, ep, p) }

    /// Now / next of a channel for the player.
    func program(_ s: HGSeries, _ ep: HGEpisode) async -> LiveHooks.Program? {
        guard let uid = s.source.tvboxLiveUID else { return nil }
        let now = Catchup.nowMs
        let list = await guide(uid, ep, at: now)
        if list.isEmpty { return nil }
        let (cur, next) = EpgService.nowNext(list, now)
        return LiveHooks.Program(now: cur?.title ?? "", next: next?.title ?? "")
    }
}
