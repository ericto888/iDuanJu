import Foundation

/// Ids of the iOS contract: the site is the `DramaSource` (`tvb.<uid>` / `tvl.<uid>`), so series ids are the bare `vod_id`
/// (live: the list's uid), episodes are `<vod_id>#<line>#<index>` and channels `<uid>#<index>`.
enum TVBoxId {
    static func episode(_ id: String, _ line: Int, _ index: Int) -> String { "\(id)#\(line)#\(index)" }
    static func channel(_ uid: String, _ index: Int) -> String { "\(uid)#\(index)" }

    struct Ep: Equatable { let id: String; let line: Int; let index: Int }

    /// The vod id may itself contain `#`.
    static func parseEpisode(_ vid: String) -> Ep? {
        guard let b = vid.range(of: "#", options: [.literal, .backwards]),
              let a = vid.range(of: "#", options: [.literal, .backwards], range: vid.startIndex..<b.lowerBound),
              let line = Int(vid[a.upperBound..<b.lowerBound]), let index = Int(vid[b.upperBound...]), line >= 0, index >= 0 else { return nil }
        return Ep(id: String(vid[..<a.lowerBound]), line: line, index: index)
    }

    static func liveIndex(_ vid: String) -> Int { Int(vid.substringAfterLast("#", "")) ?? -1 }
}

struct VodCategory: Hashable, Identifiable {
    let id: String
    let name: String
}

struct VodFilter: Hashable, Identifiable {
    struct Option: Hashable { let name: String; let value: String }
    let key: String
    let name: String
    let initial: String
    let options: [Option]
    var id: String { key }
}

/// One card of a list. `folder`: opens a nested list (`vod_tag=folder`); `action`: handled by the spider's `action`.
struct VodItem: Hashable, Identifiable {
    let uid: String
    let vodId: String
    let title: String
    let cover: String
    let remark: String
    var tags: [String] = []
    var folder = false
    var action = ""
    var landscape = false
    var id: String { "\(uid):\(vodId):\(action)" }

    var series: HGSeries {
        HGSeries(source: .tvbox(uid), seriesId: vodId, title: title, cover: cover, subtitle: remark.nilIfEmpty, orientation: landscape ? "landscape" : "portrait", tags: tags)
    }
}

struct VodHome: Equatable {
    var categories: [VodCategory] = []
    var filters: [String: [VodFilter]] = [:]
    var items: [VodItem] = []
}

struct VodPage: Equatable {
    var items: [VodItem]
    var page: Int
    var hasMore: Bool
}

/// TVBox result JSON → app models; the content filter is applied to everything that leaves here.
enum VodMapper {
    static func s(_ v: Any?, _ max: Int = 300) -> String { String(J.str(v).trimmed.prefix(max)) }

    static func root(_ text: String, _ what: String) throws -> JSONObject {
        if text.trimmed.isEmpty { return JSONObject() }
        guard let o = LenientJson.objectOrNull(text) else { throw ProviderError.upstream("站点返回的\(what)不是 JSON") }
        return o
    }

    private static let breaks = TVBoxRegex("<br\\s*/?>|</p>", .caseInsensitive)
    private static let tags = TVBoxRegex("<[^>]+>")
    private static let blankLines = TVBoxRegex("\n{2,}")

    static func plain(_ html: String) -> String {
        var t = html
        if t.contains("<") { t = tags.replace(breaks.replace(t) { _ in "\n" }) { _ in "" } }
        if t.contains("&") {
            for (k, v) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&#39;", "'")] { t = t.replacingOccurrences(of: k, with: v) }
        }
        t = t.replacingOccurrences(of: "\u{3000}", with: " ")
        if t.contains(where: \.isNewline) {
            t = t.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { String($0).trimmed }.joined(separator: "\n")
            t = blankLines.replace(t) { _ in "\n" }
        }
        return t.trimmed
    }

    /// `keep`: category names the config wants, in that order.
    static func home(_ o: JSONObject, _ uid: String, _ keep: [String], _ fix: (String) -> String) -> VodHome {
        var seen = Set<String>()
        var all: [VodCategory] = []
        for case let e as JSONObject in J.arr(o["class"]) {
            let id = s(e["type_id"], 2000), name = plain(s(e["type_name"], 40))
            if id.isEmpty || name.isEmpty || ContentFilter.isBlocked([name]) || !seen.insert(id).inserted { continue }
            all.append(VodCategory(id: id, name: name))
        }
        let picked = keep.compactMap { n in all.first { $0.name == n } }
        var f: [String: [VodFilter]] = [:]
        if let fs = o.optJSONObject("filters") {
            for k in fs.keys {
                let list = filters(fs[k])
                if !list.isEmpty { f[k] = list }
            }
        }
        return VodHome(categories: picked.isEmpty ? all : picked, filters: f, items: items(o, uid, fix))
    }

    private static func filters(_ v: Any?) -> [VodFilter] {
        let rows: [Any] = v is JSONObject ? [v as Any] : J.arr(v)
        var known = Set<String>()
        return rows.compactMap { e -> VodFilter? in
            guard let o = e as? JSONObject else { return nil }
            let options = J.arr(o["value"]).compactMap { x -> VodFilter.Option? in
                guard let p = x as? JSONObject else { return nil }
                let n = s(p["n"], 40)
                return n.isEmpty || ContentFilter.isBlocked([n]) ? nil : VodFilter.Option(name: n, value: s(p["v"], 400))
            }
            let key = s(o["key"], 80)
            if key.isEmpty || options.isEmpty || !known.insert(key).inserted { return nil }
            return VodFilter(key: key, name: s(o["name"], 20).nonEmptyOr(key), initial: s(o["init"], 400), options: options)
        }
    }

    static func items(_ o: JSONObject, _ uid: String, _ fix: (String) -> String) -> [VodItem] {
        func ratio(_ x: JSONObject?) -> Double { x.map { J.double($0["ratio"]) } ?? 0 }
        let pageRatio = ratio(o.optJSONObject("style"))
        var out: [VodItem] = []
        var known = Set<String>()
        for case let v as JSONObject in J.arr(o["list"]) {
            let id = J.str(v["vod_id"]).trimmed, title = plain(s(v["vod_name"], 200)), action = v.string("action")
            if (id.isEmpty && action.isEmpty) || title.isEmpty { continue }
            let tags = [s(v["type_name"], 30), s(v["vod_class"], 60)].filter { !$0.isEmpty }
            if ContentFilter.isBlocked([title] + tags) { continue }
            let own = ratio(v.optJSONObject("style"))
            let item = VodItem(uid: uid, vodId: id, title: title, cover: fix(s(v["vod_pic"], 4000)), remark: plain(s(v["vod_remarks"], 60)), tags: tags,
                               folder: s(v["vod_tag"], 20) == "folder" || !v.isNull("cate"), action: action, landscape: (own > 0 ? own : pageRatio) > 1.1)
            // sites repeat entries
            if known.insert(item.id + "|" + title).inserted { out.append(item) }
        }
        return out
    }

    static func page(_ o: JSONObject, _ uid: String, _ page: Int, _ fix: (String) -> String) -> VodPage {
        let count = J.int(o["pagecount"])
        return VodPage(items: items(o, uid, fix), page: page, hasMore: !(o.optJSONArray("list") ?? []).isEmpty && (count <= 0 || page < count))
    }

    struct Episode: Equatable { let name: String; let play: String }
    struct Line: Equatable { let flag: String; let eps: [Episode] }

    /// `vod_play_from` / `vod_play_url` → lines; blank names get a number, a single unnamed episode is "正片".
    static func lines(_ from: String, _ url: String) -> [Line] {
        let names = from.pieces("$$$")
        var out: [Line] = []
        for (i, chunk) in url.pieces("$$$").enumerated() {
            let raw = chunk.pieces("#").map(\.trimmed).filter { !$0.isEmpty }
            var eps: [Episode] = []
            for (j, e) in raw.enumerated() {
                let p = e.pieces("$")
                let name = p.count > 1 ? p[0].trimmed : "", play = p.count > 1 ? p[1].trimmed : e
                if play.isEmpty { continue }
                eps.append(Episode(name: name.nonEmptyOr(raw.count == 1 ? "正片" : "第\(j + 1)集"), play: play))
            }
            if eps.isEmpty { continue }
            out.append(Line(flag: (i < names.count ? names[i].trimmed : "").nonEmptyOr("线路\(i + 1)"), eps: eps))
        }
        return out
    }

    private static let separators = TVBoxRegex("[,，/、]|\\s{2,}")

    static func detail(_ o: JSONObject, _ uid: String, _ id: String, _ site: TVBoxSite, _ fix: (String) -> String) throws -> HGSeriesDetail {
        guard let v = J.arr(o["list"]).first as? JSONObject else { throw ProviderError.upstream(o.string("msg").nonEmptyOr("站点没有返回详情")) }
        let title = plain(s(v["vod_name"], 200))
        var seen = Set<String>()
        var tags: [String] = []
        let classes = s(v["vod_class"], 80).components(separatedBy: CharacterSet(charactersIn: ",/ "))
        for t in [s(v["type_name"], 30)] + classes {
            let tag = t.trimmed
            if !tag.isEmpty, seen.insert(tag).inserted { tags.append(tag) }
        }
        if ContentFilter.isBlocked([title] + tags) { throw TVBoxError("该内容已被过滤") }
        let all = lines(v.string("vod_play_from"), v.string("vod_play_url"))
        if all.isEmpty { throw TVBoxError("站点没有给出播放列表") }
        let play = all.enumerated().map { li, l in
            HGPlayLine(id: String(li), name: l.flag, episodes: l.eps.enumerated().map { i, e in
                HGEpisode(ep: i + 1, vid: TVBoxId.episode(id, li, i), duration: 0, title: e.name, page: l.flag, media: JSONObject().put("f", l.flag).put("id", e.play).toString())
            })
        }
        func people(_ k: String, _ n: Int) -> [String] {
            var seen = Set<String>()
            return Array(separators.replace(plain(s(v[k], 400))) { _ in "\n" }.pieces("\n").map(\.trimmed).filter { !$0.isEmpty && $0 != "未知" && seen.insert($0).inserted }.prefix(n))
        }
        var known = Set<String>()
        let meta = [s(v["vod_year"], 20), s(v["vod_area"], 40), s(v["vod_lang"], 20), plain(s(v["vod_remarks"], 60))].filter { !$0.isEmpty && known.insert($0).inserted }.joined(separator: " · ")
        let eps = play[0].episodes
        return HGSeriesDetail(source: .tvbox(uid), seriesId: id, title: title, cover: fix(s(v["vod_pic"], 4000)),
                              desc: [meta, plain(s(v["vod_content"], 6000))].filter { !$0.isEmpty }.joined(separator: "\n"),
                              author: people("vod_director", 3).joined(separator: " / ").nilIfEmpty, actors: people("vod_actor", 16), onlineTime: 0,
                              totalEps: eps.count, episodes: eps, tags: tags, episodeLabel: eps.count > 1 ? "共\(eps.count)集" : "长视频", lines: play)
    }

    private static let scripted = TVBoxRegex("(?:^|&)do=(js|py)(?:&|$)")

    /// `proxy://do=…` and hard-coded `127.0.0.1:9978` addresses → the running local proxy.
    static func localProxy(_ u: String, _ port: Int, _ siteKey: String) -> String {
        if u.hasPrefix("proxy://") {
            let q = String(u.dropFirst(8))
            let need = scripted.test(q) && !q.contains("siteKey=")
            return "http://127.0.0.1:\(port)/proxy?\(q)" + (need ? "&siteKey=" + GoURL.queryEscape(siteKey) : "")
        }
        if port == 9978 { return u }
        return u.replacingOccurrences(of: "http://127.0.0.1:9978/proxy", with: "http://127.0.0.1:\(port)/proxy").replacingOccurrences(of: "http://localhost:9978/proxy", with: "http://127.0.0.1:\(port)/proxy")
    }
}
