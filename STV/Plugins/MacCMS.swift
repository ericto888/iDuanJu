import Foundation
import Combine
import CryptoKit

/// Per-CMS-site diagnostics. Each saved site has an independent ring; clearing logs never touches site data.
enum CMSLog {
    private static let lock = NSLock()
    private static let limit = 300
    private static let changed = Notification.Name("stv.cms.log")
    private static func storageKey(_ key: String) -> String { "stv.cms.debug.\(key)" }

    static func lines(_ key: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return UserDefaults.standard.stringArray(forKey: storageKey(key)) ?? []
    }

    static func add(_ key: String, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        lock.lock()
        var values = UserDefaults.standard.stringArray(forKey: storageKey(key)) ?? []
        values.append("\(stamp) \(message)")
        if values.count > limit { values.removeFirst(values.count - limit) }
        UserDefaults.standard.set(values, forKey: storageKey(key))
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: key) }
        #if DEBUG
        print("[cms \(key)] \(message)")
        #endif
    }

    static func clear(_ key: String) {
        lock.lock()
        UserDefaults.standard.removeObject(forKey: storageKey(key))
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: key) }
    }

    static func notificationName() -> Notification.Name { changed }

    static func safeURL(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "?" }
        c.queryItems = c.queryItems?.map { item in
            let sensitive = ["token", "key", "auth", "sign", "password", "pass", "api_key"].contains(item.name.lowercased())
            return URLQueryItem(name: item.name, value: sensitive ? "<redacted>" : item.value)
        }
        return c.string ?? (url.host ?? "?")
    }
}

/// 苹果 CMS (maccms v10) 采集接口: built-in generic adapter, no JS needed.
struct CMSSite: Codable, Hashable, Identifiable {
    var key: String
    var name: String
    var api: String
    var adult: Bool = false
    var enabled: Bool = true
    var categories: [PluginCategory] = []
    var origin: String = "manual"
    var id: String { key }
    var source: DramaSource { .cms(key) }

    static func key(for api: String) -> String {
        String(Insecure.MD5.hash(data: Data(api.utf8)).map { String(format: "%02x", $0) }.joined().prefix(10))
    }
}

@MainActor
final class CMSStore: ObservableObject {
    static let shared = CMSStore()
    @Published private(set) var sites: [CMSSite] = []
    @Published private(set) var revision = 0
    private let d = UserDefaults.standard
    private static let key = "stv.cms.sites"

    nonisolated(unsafe) private static var snap: [String: CMSSite] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    nonisolated private static let lock = NSLock()
    nonisolated static func site(_ key: String) -> CMSSite? { lock.lock(); defer { lock.unlock() }; return snap[key] }
    nonisolated static func sources() -> [DramaSource] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { snap[$0] }.filter(\.enabled).map(\.source)
    }

    private init() {
        sites = d.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([CMSSite].self, from: $0) } ?? []
        publish()
    }

    private func publish() {
        Self.lock.lock()
        Self.snap = Dictionary(uniqueKeysWithValues: sites.map { ($0.key, $0) })
        Self.order = sites.map(\.key)
        Self.lock.unlock()
        revision += 1
    }
    private func save() {
        if let data = try? JSONEncoder().encode(sites) { d.set(data, forKey: Self.key) }
        publish()
    }

    nonisolated static func normalize(_ api: String, allowHTTP: Bool = false) throws -> String {
        var s = api.trimmingCharacters(in: .whitespacesAndNewlines)
        if !allowHTTP, s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }
        guard var c = URLComponents(string: s),
              c.scheme == "https" || (allowHTTP && c.scheme == "http"),
              let h = c.host, !h.isEmpty, !NetGuard.isIPLiteral(h) else {
            throw ProviderError.invalid(allowHTTP ? "需要 http(s) 的采集接口地址（不支持 IP / 内网地址）" : "需要 https 的采集接口地址（不支持 IP / 内网地址）")
        }
        c.queryItems = c.queryItems?.filter { !["ac", "t", "pg", "wd", "ids", "h"].contains($0.name) }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        c.fragment = nil
        return c.url?.absoluteString ?? s
    }

    /// Validates by fetching the class list, then saves.
    @discardableResult
    func add(name: String, api raw: String, adult: Bool, origin: String = "manual") async throws -> CMSSite {
        let api = try Self.normalize(raw)
        let siteKey = CMSSite.key(for: api)
        let cats = try await MacCMSProvider.fetchCategories(api: api, siteKey: siteKey)
        var site = CMSSite(key: siteKey, name: name.isEmpty ? (URL(string: api)?.host ?? "采集站") : name, api: api,
                           adult: adult, categories: cats, origin: origin)
        if let i = sites.firstIndex(where: { $0.key == site.key }) { site.enabled = sites[i].enabled; sites[i] = site } else { sites.append(site) }
        save()
        return site
    }
    #if DEBUG
    func debugInsert(_ site: CMSSite) { sites.removeAll { $0.key == site.key }; sites.append(site); save() }
    #endif
    func remove(_ key: String) { sites.removeAll { $0.key == key }; save() }
    func setEnabled(_ key: String, _ on: Bool) { if let i = sites.firstIndex(where: { $0.key == key }) { sites[i].enabled = on; save() } }
    func setAdult(_ key: String, _ on: Bool) { if let i = sites.firstIndex(where: { $0.key == key }) { sites[i].adult = on; save() } }
    func cacheCategories(_ key: String, _ cats: [PluginCategory]) {
        guard let i = sites.firstIndex(where: { $0.key == key }), sites[i].categories != cats else { return }
        sites[i].categories = cats; save()
    }
    var visibleSites: [CMSSite] { sites.filter { !$0.adult || SourceGate.shared.unlocked } }
}

struct MacCMSProvider: SiteProvider {
    let source: DramaSource
    let site: CMSSite

    init(source: DramaSource, site: CMSSite) { self.source = source; self.site = site }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    static func url(_ api: String, _ q: [String: String]) -> URL? {
        guard var c = URLComponents(string: api) else { return nil }
        c.queryItems = (c.queryItems ?? []) + q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url
    }

    static func fetch(_ api: String, _ q: [String: String], siteKey: String? = nil, stage: String = "请求") async throws -> [String: Any] {
        guard let u = url(api, q), let host = u.host,
              u.scheme == "https" || u.scheme == "http" else { throw ProviderError.invalid("采集接口地址无效") }
        let started = Date()
        if let siteKey { CMSLog.add(siteKey, "→ \(stage) GET \(CMSLog.safeURL(u))") }
        do {
            let blocked = await Task.detached { NetGuard.resolvesToBlocked(host) }.value
            if blocked { throw ProviderError.invalid("采集接口解析到内网地址") }
            var data: Data
            var status = 200
            var finalURL = u
            var contentType = "fixture"
            if let fx = PluginFixtures.responder, let r = fx(URLRequest(url: u)) {
                data = r.body
                status = r.status
            } else {
                var req = URLRequest(url: u)
                req.setValue(PluginHostContext.defaultUA, forHTTPHeaderField: "User-Agent")
                let (d, resp) = try await session.data(for: req)
                let http = resp as? HTTPURLResponse
                status = http?.statusCode ?? 0
                finalURL = resp.url ?? u
                contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                guard (200..<300).contains(status) else { throw ProviderError.upstream("采集站 HTTP \(status) · \(host)") }
                if let fu = finalURL.host, fu != host, NetGuard.resolvesToBlocked(fu) { throw ProviderError.invalid("跳转到内网地址") }
                data = d
            }
            guard (200..<300).contains(status) else { throw ProviderError.upstream("采集站 HTTP \(status) · \(host)") }
            guard data.count < 8 << 20, let o = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? CMSXML.decode(data) else {
                throw ProviderError.upstream("采集站没有返回有效的 CMS JSON / XML")
            }
            if let code = o["code"], PluginOut.s(code) != "1" {
                throw ProviderError.upstream("采集站：" + PluginOut.s(o["msg"]).nonEmptyOr("请求失败"))
            }
            if let siteKey {
                CMSLog.add(siteKey, "← \(stage) HTTP \(status) · \(data.count)B · \(Int(Date().timeIntervalSince(started) * 1000))ms · \(contentType) · \(CMSLog.safeURL(finalURL))")
            }
            return o
        } catch {
            if let siteKey { CMSLog.add(siteKey, "✕ \(stage) \(error.localizedDescription) · \(CMSLog.safeURL(u)) · \(Int(Date().timeIntervalSince(started) * 1000))ms") }
            throw error
        }
    }

    static func parseCategories(_ o: [String: Any]) -> [PluginCategory] {
        ((o["class"] as? [[String: Any]]) ?? []).compactMap { c in
            let id = PluginOut.s(c["type_id"]), name = PluginOut.s(c["type_name"], max: 30)
            guard !id.isEmpty, !name.isEmpty, !ContentFilter.isBlocked([name]) else { return nil }
            return PluginCategory(id: id, name: name)
        }
    }

    static func fetchCategories(api: String, siteKey: String? = nil) async throws -> [PluginCategory] {
        let o = try await fetch(api, ["ac": "list"], siteKey: siteKey, stage: "分类验证")
        guard o["list"] != nil || o["class"] != nil else { throw ProviderError.upstream("不像苹果 CMS 接口（缺少 list/class 字段）") }
        return parseCategories(o)
    }

    static func parseItems(_ o: [String: Any], source: DramaSource) -> [HGSeries] {
        ((o["list"] as? [[String: Any]]) ?? []).compactMap { v in
            let id = PluginOut.s(v["vod_id"]), title = PluginOut.s(v["vod_name"], max: 200)
            guard !id.isEmpty, !title.isEmpty else { return nil }
            let tags = [PluginOut.s(v["type_name"], max: 30), PluginOut.s(v["vod_class"], max: 60)].filter { !$0.isEmpty }
            guard !ContentFilter.isBlocked([title] + tags) else { return nil }
            var cover = PluginOut.s(v["vod_pic"], max: 2000)
            if cover.hasPrefix("//") { cover = "https:" + cover }
            if cover.hasPrefix("http://") { cover = "https://" + cover.dropFirst(7) }
            let remarks = PluginOut.s(v["vod_remarks"], max: 40)
            let typeName = PluginOut.s(v["type_name"], max: 30)
            let total = Int(PluginOut.s(v["vod_total"])) ?? 0
            let eps = lines(from: PluginOut.s(v["vod_play_from"], max: 1000),
                            urls: (v["vod_play_url"] as? String) ?? "").map(\.eps.count).max() ?? 0
            // 电影 / 连续剧区分：接口给的总集数、线路集数、备注与分类名共同判断。
            let episodic = isEpisodic(typeName: typeName, remarks: remarks, total: total, episodeCount: eps)
            return HGSeries(source: source, seriesId: id, title: title, cover: cover, subtitle: remarks.nilIfEmpty,
                            author: PluginOut.s(v["vod_director"], max: 60).nilIfEmpty,
                            actors: PluginOut.s(v["vod_actor"], max: 200).split(whereSeparator: { ",，/ ".contains($0) }).prefix(6).map(String.init),
                            episodeCount: episodic ? max(total, eps, Self.episodeCount(fromRemarks: remarks)) : 0,
                            orientation: "portrait", tags: tags)
        }
    }

    /// 只靠 type_name 会误判（“剧情片”是电影、“综艺片”是综艺），所以同时看总集数、
    /// 线路集数和“更新至/全 N 集”这类备注。
    static func isEpisodic(typeName: String, remarks: String, total: Int, episodeCount: Int) -> Bool {
        let lower = typeName.lowercased()
        let episodicType = (lower.contains("剧") && !lower.contains("片"))
            || ["动漫", "动画", "综艺", "番剧"].contains(where: { lower.contains($0) })
        let episodicRemark = remarks.contains("更新至")
            || (remarks.contains("集") && remarks.rangeOfCharacter(from: .decimalDigits) != nil)
        return episodicType || episodicRemark || total > 1 || episodeCount > 1
    }

    /// “更新至第07集”、“全40集”、“共 24 集” → 集数。
    static func episodeCount(fromRemarks r: String) -> Int {
        guard r.contains("集") else { return 0 }
        return r.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.last ?? 0
    }

    static func page(_ o: [String: Any], source: DramaSource, page p: Int) -> HGPage {
        let items = parseItems(o, source: source)
        let pageCount = Int(PluginOut.s(o["pagecount"])) ?? 0
        return HGPage(items: items, hasMore: !items.isEmpty && (pageCount == 0 ? items.count >= 10 : p < pageCount), nextOffset: p + 1)
    }

    /// `vod_play_from` "a$$$b", `vod_play_url` "第1集$url#第2集$url$$$..." → lines of (name, [(epName, url)]).
    static func lines(from: String, urls: String) -> [(name: String, eps: [(String, String)])] {
        let chunks = urls.components(separatedBy: "$$$")
        var names = from.components(separatedBy: "$$$")
        // 部分采集站（包括 FFZY）在 vod_play_from 中用逗号列出线路名，
        // 但 vod_play_url 仍按 $$$ 分隔；按线路数量对齐，避免线路名错位。
        if names.count == 1, chunks.count > 1 {
            let commaNames = from.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if commaNames.count == chunks.count { names = commaNames }
        }
        return chunks.enumerated().compactMap { i, chunk in
            let eps: [(String, String)] = chunk.split(separator: "#").enumerated().compactMap { j, e in
                let parts = e.split(separator: "$", maxSplits: 1).map(String.init)
                let (n, u) = parts.count == 2 ? (parts[0], parts[1]) : ("第\(j + 1)集", parts.first ?? "")
                return u.isEmpty ? nil : (n.trimmingCharacters(in: .whitespaces), u.trimmingCharacters(in: .whitespaces))
            }
            return eps.isEmpty ? nil : ((i < names.count ? names[i] : "线路\(i + 1)"), eps)
        }
    }
    static func isDirect(_ u: String) -> Bool {
        let l = u.lowercased()
        return (l.hasPrefix("https://") || l.hasPrefix("http://")) && (l.contains(".m3u8") || l.contains(".mp4"))
    }

    static func isHTTPURL(_ u: String) -> Bool {
        let l = u.lowercased()
        return l.hasPrefix("https://") || l.hasPrefix("http://")
    }

    static func parseDetail(_ o: [String: Any], series s: HGSeries, source: DramaSource) throws -> HGSeriesDetail {
        guard let v = (o["list"] as? [[String: Any]])?.first else { throw ProviderError.upstream("采集站没有返回详情") }
        let title = PluginOut.s(v["vod_name"], max: 200).nonEmptyOr(s.title)
        let tags = [PluginOut.s(v["type_name"], max: 30)] + PluginOut.s(v["vod_class"], max: 80).split(separator: ",").map(String.init)
        guard !ContentFilter.isBlocked([title] + tags) else { throw ProviderError.unsupported("该内容已被过滤") }
        let all = lines(from: PluginOut.s(v["vod_play_from"], max: 2000), urls: (v["vod_play_url"] as? String) ?? "")
        // Prefer lines with an explicit m3u8/mp4 suffix. Extensionless HTTP(S) endpoints are
        // retained when no explicit line exists and MPV can determine their container.
        let direct = all.filter { $0.eps.contains { isDirect($0.1) } }
        let playable = direct.isEmpty ? all.filter { $0.eps.contains { isHTTPURL($0.1) } } : direct
        guard let main = playable.max(by: { $0.eps.count < $1.eps.count }) else { throw ProviderError.unsupported("该资源没有可直接播放的线路（需要解析器的线路暂不支持）") }
        let eps = main.eps.enumerated().map { i, e -> HGEpisode in
            let alts: [[String: String]] = playable.compactMap { l in i < l.eps.count && isHTTPURL(l.eps[i].1) ? ["n": l.name, "u": l.eps[i].1] : nil }
            let media = (try? JSONSerialization.data(withJSONObject: alts)).map { String(decoding: $0, as: UTF8.self) }
            return HGEpisode(ep: i + 1, vid: "\(s.seriesId)#\(i)", duration: 0, title: e.0.isEmpty ? "第\(i + 1)集" : e.0, page: main.name, media: media)
        }
        var cover = PluginOut.s(v["vod_pic"], max: 2000)
        if cover.hasPrefix("http://") { cover = "https://" + cover.dropFirst(7) }
        var desc = PluginOut.s(v["vod_content"], max: 4000)
        desc = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "&nbsp;", with: " ")
        let meta = [PluginOut.s(v["vod_year"]), PluginOut.s(v["vod_area"]), PluginOut.s(v["vod_remarks"])].filter { !$0.isEmpty }.joined(separator: " · ")
        let typeName = PluginOut.s(v["type_name"], max: 40).trimmingCharacters(in: .whitespacesAndNewlines)
        let remarks = PluginOut.s(v["vod_remarks"], max: 80)
        let total = Int(PluginOut.s(v["vod_total"])) ?? 0
        // 电影 / 连续剧统一走同一个判定：分类名 + 备注 + 总集数 + 线路集数。
        let isLongVideo = !isEpisodic(typeName: typeName, remarks: remarks, total: total, episodeCount: eps.count)
        return HGSeriesDetail(source: source, seriesId: s.seriesId, title: title, cover: cover.isEmpty ? s.cover : cover,
                              desc: [meta, desc].filter { !$0.isEmpty }.joined(separator: "\n"),
                              author: PluginOut.s(v["vod_director"], max: 60).nilIfEmpty,
                              actors: PluginOut.s(v["vod_actor"], max: 300).split(whereSeparator: { ",，/".contains($0) }).prefix(12).map { $0.trimmingCharacters(in: .whitespaces) },
                              onlineTime: 0, totalEps: eps.count, episodes: eps, tags: tags.filter { !$0.isEmpty },
                              episodeLabel: isLongVideo ? "长视频" : "共\(max(eps.count, 1))集",
                              isLongVideo: isLongVideo)
    }

    static func streams(for ep: HGEpisode) -> [HGStream] {
        let alts = ep.media.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: String]] } ?? []
        return alts.enumerated().compactMap { i, a in
            guard let u = a["u"] else { return nil }
            guard let url = URL(string: u),
                  url.scheme == "https" || url.scheme == "http",
                  let h = url.host, !NetGuard.isIPLiteral(h) else { return nil }
            return HGStream(streamId: "cms\(i)", quality: (a["n"] ?? "线路\(i + 1)") + (u.contains(".m3u8") ? " · HLS" : " · MP4"), url: u, key: "",
                            kind: u.contains(".m3u8") ? .hls : .mp4Clear, headers: ["User-Agent": PluginHostContext.defaultUA])
        }
    }

    var categories: [SiteCategory] {
        let cats = CMSStore.site(site.key)?.categories ?? site.categories
        return [SiteCategory(id: "", title: "最新", path: "")] + cats.map { SiteCategory(id: $0.id, title: $0.name, path: $0.id) }
    }

    func list(_ c: SiteCategory, page p: Int) async throws -> HGPage {
        var q = ["pg": String(p)]
        if !c.id.isEmpty { q["t"] = c.id }
        let o = try await Self.fetchPage(site.api, q, siteKey: site.key,
                                         stage: c.id.isEmpty ? "首页/列表" : "分类列表", page: p)
        // Only the unfiltered latest page carries the site-wide class list. A category
        // response can contain a partial class array and must not replace the home modules.
        if c.id.isEmpty, p == 1, case let cats = Self.parseCategories(o), !cats.isEmpty {
            let k = site.key
            await MainActor.run { CMSStore.shared.cacheCategories(k, cats) }
        }
        var result = Self.page(o, source: source, page: p)
        await Self.fillMissingCovers(&result, site: site, source: source)
        CMSLog.add(site.key, "ℹ 列表解析完成：\(result.items.count) 条，封面地址：\(result.items.prefix(5).map { URL(string: $0.cover).map(CMSLog.safeURL) ?? "无" }.joined(separator: " | "))")
        return result
    }

    func search(_ q: String, page p: Int) async throws -> HGPage {
        let o = try await Self.fetchPage(site.api, ["wd": q, "pg": String(p)], siteKey: site.key, stage: "搜索", page: p)
        var result = Self.page(o, source: source, page: p)
        await Self.fillMissingCovers(&result, site: site, source: source)
        CMSLog.add(site.key, "ℹ 搜索结果解析：\(result.items.count) 条")
        return result
    }

    /// 浏览列表优先用 `ac=detail`：一页一个请求就带回封面、类型与总集数，和其它内置站源
    /// 一样按页懒加载；不支持分页（忽略 pg）或字段不全时退回 `ac=list` 并用详情补封面。
    /// 同时兼容 maccms v8 的 `ac=videolist`。
    private static func fetchPage(_ api: String, _ extra: [String: String], siteKey: String, stage: String, page p: Int) async throws -> [String: Any] {
        var lastError: Error?
        for ac in ["detail", "videolist", "list"] {
            do {
                var q = extra
                q["ac"] = ac
                let o = try await fetch(api, q, siteKey: siteKey, stage: "\(stage)·\(ac)")
                guard o["list"] is [[String: Any]] else { throw ProviderError.upstream("采集站没有返回列表") }
                if ac != "list" {
                    // 部分站点忽略 pg 直接返回全量，或该模式返回空壳；页号/页数对不上就换下一种模式。
                    let returned = Int(PluginOut.s(o["page"])) ?? p
                    let pages = Int(PluginOut.s(o["pagecount"])) ?? 0
                    let rows = (o["list"] as? [[String: Any]])?.count ?? 0
                    if returned != p || (rows == 0 && pages == 0) {
                        throw ProviderError.upstream("采集站不支持该模式（\(ac)）")
                    }
                }
                return o
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ProviderError.upstream("采集站请求失败")
    }

    /// `ac=list` 只返回精简字段，多数采集站（如 FFZY）不返回 `vod_pic`，首页卡片因此没有海报。
    /// 对缺少封面的条目用一次详情请求补齐当前页，失败时保留原样、不影响列表。
    private static func fillMissingCovers(_ page: inout HGPage, site: CMSSite, source: DramaSource) async {
        let missing = page.items.filter { $0.cover.isEmpty }.map(\.seriesId)
        guard !missing.isEmpty else { return }
        let ids = missing.joined(separator: ",")
        var detail: [String: Any]?
        for ac in ["detail", "videolist"] {
            if let o = try? await fetch(site.api, ["ac": ac, "ids": ids], siteKey: site.key, stage: "封面补齐·\(ac)") {
                detail = o
                break
            }
        }
        guard let o = detail else {
            CMSLog.add(site.key, "⚠ 封面补齐失败：\(missing.count) 条无封面")
            return
        }
        let covers = Dictionary(parseItems(o, source: source).map { ($0.seriesId, $0.cover) }, uniquingKeysWith: { first, _ in first })
        var filled = 0
        page.items = page.items.map { item in
            guard item.cover.isEmpty, let cover = covers[item.seriesId], !cover.isEmpty else { return item }
            var fixed = item
            fixed.cover = cover
            filled += 1
            return fixed
        }
        CMSLog.add(site.key, "ℹ 封面补齐：\(filled)/\(missing.count) 条")
    }

    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        let o: [String: Any]
        do {
            o = try await Self.fetch(site.api, ["ac": "detail", "ids": s.seriesId], siteKey: site.key, stage: "详情")
        } catch {
            // maccms v8 用 ac=videolist 取详情。
            o = try await Self.fetch(site.api, ["ac": "videolist", "ids": s.seriesId], siteKey: site.key, stage: "详情·videolist")
        }
        return try Self.parseDetail(o, series: s, source: source)
    }

    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        CMSLog.add(site.key, "▶ 播放解析：\(s.title) · 第\(ep.ep)集 · media=\(ep.media == nil ? "缺失" : "存在")")
        var st = Self.streams(for: ep)
        if st.isEmpty {
            // Episode objects restored from history may lack `media`; refetch detail.
            let d = try await detail(s)
            if let e = d.episodes.first(where: { $0.vid == ep.vid }) ?? d.episodes.first(where: { $0.ep == ep.ep }) { st = Self.streams(for: e) }
        }
        guard let first = st.first else { CMSLog.add(site.key, "✕ 播放解析失败：没有可播放线路"); throw ProviderError.unsupported("没有可播放的线路") }
        CMSLog.add(site.key, "✓ 播放地址已解析：\(first.quality) · \(URL(string: first.url).map(CMSLog.safeURL) ?? "invalid URL") · headers=User-Agent（播放器实际 HTTP 响应由播放器内核处理，当前层无法读取）")
        return HGResolvedVideo(vid: ep.vid, url: first.url, key: nil, duration: nil, expiresAt: nil, err: nil, streams: st)
    }
}

/// MacCMS RSS uses one <dd flag="…"> per playback line and carries pagination on <list>.
private final class CMSXML: NSObject, XMLParserDelegate {
    var output: [String: Any] = [:]
    var videos: [[String: String]] = [], categories: [[String: String]] = []
    var video: [String: String]?, flags: [String] = [], urls: [String] = []
    var text = "", categoryID = "", rootSeen = false
    static let fields = ["id":"vod_id", "name":"vod_name", "pic":"vod_pic", "type":"type_name", "last":"vod_time", "note":"vod_remarks", "actor":"vod_actor", "director":"vod_director", "des":"vod_content", "year":"vod_year", "area":"vod_area", "tid":"type_id"]
    static func decode(_ data: Data) -> [String: Any]? {
        guard let xml = String(data: data, encoding: .utf8), !xml.localizedCaseInsensitiveContains("<!DOCTYPE") else { return nil }
        let delegate = CMSXML(), parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !delegate.output.isEmpty else { return nil }
        return delegate.output
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String] = [:]) {
        if !rootSeen { rootSeen = true; guard name == "rss" else { parser.abortParsing(); return } }
        text = ""
        switch name {
        case "list": output["pagecount"] = attrs["pagecount"]
        case "ty": categoryID = attrs["id"] ?? ""
        case "video": video = [:]; flags = []; urls = []
        case "dd": flags.append(attrs["flag"] ?? "线路\(flags.count + 1)")
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "ty": categories.append(["type_id": categoryID, "type_name": text])
        case "class": output["class"] = categories
        case "list": output["list"] = videos
        case "dd": urls.append(text)
        case "video":
            video?["vod_play_from"] = flags.joined(separator: "$$$"); video?["vod_play_url"] = urls.joined(separator: "$$$")
            if let video { videos.append(video) }; video = nil
        default: if let key = Self.fields[name] { video?[key] = text }
        }
        text = ""
    }
}
