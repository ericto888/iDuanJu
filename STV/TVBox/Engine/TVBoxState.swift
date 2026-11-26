import Foundation

/// Downloads and decodes a config address (contract §3): never touches the sites inside it.
struct ConfigLoader {
    let net: TVBoxNet
    static let timeoutMs = 12_000

    struct Loaded {
        let parsed: ParsedConfig
        let text: String
        let url: String
    }

    /// `raw` may carry `;pk;key`. `allowLan` = the user's LAN switch; a private config address implies it for itself.
    func load(_ raw: String, allowLan: Bool) async throws -> Loaded {
        let (address, key) = TVBoxDecoder.splitKey(raw)
        let url = try Self.normalize(address)
        let scope = TVBoxNet.Scope(net, NetRules(allowPrivate: allowLan || TVBoxNet.isPrivateAddress(url)))
        let r: NetResponse
        do { r = try await scope.fetch(NetRequest(url: url, timeoutMs: Self.timeoutMs)) } catch {
            if error is CancellationError { throw error }
            throw ProviderError.upstream(SpiderErrors.text(error))
        }
        if !r.ok { throw ProviderError.upstream("HTTP \(r.code) · \(TVBoxUrl.host(url))") }
        if r.body.isEmpty { throw ProviderError.upstream("配置地址没有返回内容") }
        let text = try TVBoxDecoder.decode(r.body, key)
        return Loaded(parsed: try TVBoxConfig.parse(text, url), text: text, url: raw.trimmed)
    }

    static func normalize(_ raw: String) throws -> String {
        let t = raw.trimmed
        if TVBoxUrl.isLocal(t) || TVBoxUrl.isHttp(t) { return t }
        if t.contains("://") { throw ProviderError.invalid("不支持的地址类型") }
        if t.contains("."), !t.contains(" "), !t.contains("\n") { return "http://" + t }
        throw ProviderError.invalid("请输入配置地址")
    }
}

enum Trust: String { case ask = "Ask", trusted = "Trusted", denied = "Denied" }

/// One imported config as persisted; its decoded text lives in its own file.
struct RepoRecord: Hashable {
    var id: String
    var name: String
    var url: String
    var depot = ""
    var trust = Trust.ask
    /// Milliseconds.
    var updatedAt: Int64 = 0
    /// Disabled site / live uids.
    var disabled: Set<String> = []
    /// User-chosen default parse.
    var parse = ""
    /// Migrated from store v1: uid → normalised api, until the first refresh maps them onto real site keys.
    var legacy: [String: String] = [:]

    /// Base for relative addresses.
    var base: String { TVBoxDecoder.splitKey(url).0 }

    static func id(_ url: String) -> String { String(Bytes.hex(Bytes.md5(url.trimmed)).prefix(12)) }

    func toJSON() -> JSONObject {
        let o = JSONObject().put("id", id).put("name", name).put("url", url).put("depot", depot).put("trust", trust.rawValue).put("updatedAt", Int(updatedAt))
            .put("disabled", disabled.sorted()).put("parse", parse)
        if !legacy.isEmpty { o.put("legacy", JSONObject(legacy)) }
        return o
    }

    static func fromJSON(_ o: JSONObject) -> RepoRecord? {
        let id = o.string("id")
        if id.isEmpty { return nil }
        var r = RepoRecord(id: id, name: o.string("name").nonEmptyOr("TVBox 配置"), url: o.string("url"))
        r.depot = o.string("depot")
        r.trust = Trust(rawValue: o.string("trust")) ?? .ask
        r.updatedAt = J.int64(o["updatedAt"])
        r.disabled = Set(J.arr(o["disabled"]).map { J.str($0) })
        r.parse = o.string("parse")
        r.legacy = o.optJSONObject("legacy")?.strings() ?? [:]
        return r
    }
}

struct DepotRecord: Hashable, Identifiable {
    var id: String
    var name: String
    var url: String
    var entries: [TVBoxDepotEntry]

    func toJSON() -> JSONObject {
        JSONObject().put("id", id).put("name", name).put("url", url).put("entries", entries.map { JSONObject().put("name", $0.name).put("url", $0.url) })
    }

    static func fromJSON(_ o: JSONObject) -> DepotRecord? {
        let id = o.string("id")
        if id.isEmpty { return nil }
        return DepotRecord(id: id, name: o.string("name"), url: o.string("url"), entries: J.arr(o["entries"]).compactMap { e in
            (e as? JSONObject).map { TVBoxDepotEntry(name: $0.string("name"), url: $0.string("url")) }
        })
    }
}

/// A watch record of store v1, on its way into the app's history. Times are milliseconds.
struct LegacyWatch: Equatable {
    let uid: String
    let vodId: String
    let title: String
    let cover: String
    let episodeIndex: Int
    let positionMs: Int64
    let durationMs: Int64
    let updatedAt: Int64
}

/// Persistent TVBox state (`tvbox_store_v2.json`). A value: the store swaps whole snapshots and writes them in the background.
struct TVBoxState: Equatable {
    static let version = 2

    var repos: [RepoRecord] = []
    var depots: [DepotRecord] = []
    var active = ""
    var lastSite: [String: String] = [:]
    var lastLive: [String: String] = [:]
    var favorites: [String] = []
    /// Live uid → names of password groups the user opened.
    var unlocked: [String: Set<String>] = [:]
    var aliases: [String: String] = [:]
    var allowLan = false
    var doh = ""
    var latency: [String: Int] = [:]

    func toJSON() -> JSONObject {
        let locks = JSONObject()
        for k in unlocked.keys.sorted() { locks.put(k, (unlocked[k] ?? []).sorted()) }
        return JSONObject().put("v", Self.version).put("repos", repos.map { $0.toJSON() }).put("depots", depots.map { $0.toJSON() }).put("active", active)
            .put("lastSite", JSONObject(lastSite)).put("lastLive", JSONObject(lastLive)).put("favorites", favorites)
            .put("unlocked", locks).put("aliases", JSONObject(aliases)).put("allowLan", allowLan).put("doh", doh).put("latency", JSONObject(latency))
    }

    static func fromJSON(_ o: JSONObject) -> TVBoxState {
        func map(_ k: String) -> [String: String] { o.optJSONObject(k)?.strings() ?? [:] }
        var s = TVBoxState()
        s.repos = J.arr(o["repos"]).compactMap { ($0 as? JSONObject).flatMap(RepoRecord.fromJSON) }
        s.depots = J.arr(o["depots"]).compactMap { ($0 as? JSONObject).flatMap(DepotRecord.fromJSON) }
        s.active = o.string("active")
        s.lastSite = map("lastSite")
        s.lastLive = map("lastLive")
        s.favorites = J.arr(o["favorites"]).map { J.str($0) }.filter { !$0.isEmpty }
        if let u = o.optJSONObject("unlocked") { for k in u.keys { s.unlocked[k] = Set(J.arr(u[k]).map { J.str($0) }) } }
        s.aliases = map("aliases")
        s.allowLan = J.bool(o["allowLan"])
        s.doh = o.string("doh")
        if let l = o.optJSONObject("latency") { for k in l.keys { s.latency[k] = J.int(l[k]) } }
        return s
    }

    // MARK: Store v1

    struct Migrated {
        let state: TVBoxState
        let configs: [String: String]
        let watches: [LegacyWatch]
    }

    static func normalApi(_ api: String) -> String {
        var t = api.trimmed.lowercased().substringAfter("://").substringBefore("?")
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// `tvbox_store_v1.json` → v2: configs are rebuilt from the saved sites so everything works before the first refresh.
    /// Reads the iOS fields (`positionSec`, seconds) as well as the Android ones (`positionMs`, milliseconds).
    static func migrateV1(_ root: JSONObject) -> Migrated {
        var configs: [String: String] = [:]
        var uidOf: [String: String] = [:] // v1 site key → uid
        var state = TVBoxState()
        for case let r as JSONObject in J.arr(root["repos"]) {
            let url = r.string("url")
            let id = r.string("id").nonEmptyOr(RepoRecord.id(url.nonEmptyOr(r.string("name"))))
            var record = RepoRecord(id: id, name: r.string("name").nonEmptyOr("TVBox 配置"), url: url)
            var sites: [Any] = [], lives: [Any] = []
            for case let s as JSONObject in J.arr(r["sites"]) {
                let key = s.string("key"), api = s.string("api")
                if key.isEmpty || api.isEmpty { continue }
                let uid = TVBoxConfig.siteUid(id, key)
                sites.append(JSONObject().put("key", key).put("name", s.string("name")).put("type", 1).put("api", api).put("adult", J.bool(s["adult"])))
                if !url.isEmpty { record.legacy[uid] = normalApi(api) }
                if uidOf[key] == nil { uidOf[key] = uid }
                if s.has("enabled"), !J.bool(s["enabled"]) { record.disabled.insert(uid) }
            }
            for case let l as JSONObject in J.arr(r["lives"]) {
                let listUrl = l.string("url")
                let o = JSONObject().put("name", l.string("name")).put("url", listUrl)
                if listUrl.isEmpty {
                    var order: [String] = [], groups: [String: [Any]] = [:]
                    for case let c as JSONObject in J.arr(l["channels"]) {
                        let g = c.string("group").nonEmptyOr("默认分组")
                        if groups[g] == nil { order.append(g) }
                        groups[g, default: []].append(JSONObject().put("name", c.string("name")).put("urls", c.optJSONArray("urls") ?? []).put("logo", c.string("logo")))
                    }
                    if order.isEmpty { continue }
                    o.put("groups", order.map { JSONObject().put("name", $0).put("channel", groups[$0] ?? []) })
                }
                lives.append(o)
                if l.has("enabled"), !J.bool(l["enabled"]) { record.disabled.insert(TVBoxConfig.liveUid(id, listUrl.nonEmptyOr(l.string("name")))) }
            }
            configs[id] = JSONObject().put("sites", sites).put("lives", lives).put("name", r.string("name")).toString()
            record.updatedAt = millis(r["updatedAt"])
            state.repos.append(record)
        }
        state.active = root.string("activeRepoId")
        state.favorites = J.arr(root["favoriteChannels"]).map { J.str($0) }.filter { !$0.isEmpty }
        var watches: [LegacyWatch] = []
        for case let w as JSONObject in J.arr(root["recentWatches"]) {
            let raw = w.string("seriesId")
            let vod = raw.hasPrefix("cms:") ? String(raw.dropFirst(4)).substringAfter(":") : raw
            guard let uid = uidOf[w.string("siteKey")], !vod.isEmpty else { continue }
            watches.append(LegacyWatch(uid: uid, vodId: vod, title: w.string("title"), cover: w.string("cover"), episodeIndex: J.int(w["episodeIndex"]),
                                       positionMs: w.has("positionMs") ? J.int64(w["positionMs"]) : Int64(J.double(w["positionSec"]) * 1000),
                                       durationMs: w.has("durationMs") ? J.int64(w["durationMs"]) : Int64(J.double(w["durationSec"]) * 1000), updatedAt: millis(w["updatedAt"])))
        }
        return Migrated(state: state, configs: configs, watches: watches)
    }

    private static func millis(_ v: Any?) -> Int64 {
        let d = J.double(v)
        return d.isFinite && abs(d) < 1e15 ? Int64(d > 1e8 && d < 1e11 ? d * 1000 : d) : 0
    }

    /// First refresh of a migrated config: old uid → uid of the site with the same api.
    static func aliases(_ record: RepoRecord, _ config: TVBoxConfig) -> [String: String] {
        if record.legacy.isEmpty { return [:] }
        var byApi: [String: String] = [:]
        for s in config.sites { byApi[normalApi(s.api)] = TVBoxConfig.siteUid(record.id, s.key) }
        var out: [String: String] = [:]
        for (uid, api) in record.legacy { if let now = byApi[api], now != uid { out[uid] = now } }
        return out
    }
}
