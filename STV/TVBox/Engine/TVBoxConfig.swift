import Foundation

struct TVBoxParse: Hashable {
    var name: String
    var type: Int
    var url: String
    var flags: [String] = []
    var headers: [String: String] = [:]
    var ext = ""
}

struct TVBoxHeaderRule: Hashable {
    var host: String
    var headers: [String: String]

    func matches(_ h: String) -> Bool { h == host || h.hasSuffix("." + host) }
}

struct TVBoxDoh: Hashable {
    var name: String
    var url: String
    var ips: [String]
}

struct TVBoxLive: Hashable {
    var name: String
    var type = 0
    var url = ""
    var api = ""
    var ext = ""
    var jar = ""
    var epg = ""
    var logo = ""
    var ua = ""
    var referer = ""
    var origin = ""
    var headers: [String: String] = [:]
    var timeZone = ""
    var timeoutMs = TVBoxSite.defaultTimeoutMs
    var pass = false
    var catchup: Catchup? = nil
    var groups: [LiveGroup] = []

    /// What identifies this list inside its config (contract: `repoId + "|live|" + url`).
    var identity: String { !url.isEmpty ? url : api.isEmpty ? name : "\(api) \(ext)" }

    /// type 3 = the list comes from a spider's `liveContent`.
    var kind: SiteKind? {
        if api.isEmpty { return nil }
        let k = SiteKind.of(type: 3, api: api)
        return k == .unsupported ? nil : k
    }

    var requestHeaders: [String: String] {
        var h = headers
        if !ua.isEmpty { h["User-Agent"] = ua }
        if !referer.isEmpty { h["Referer"] = referer }
        if !origin.isEmpty { h["Origin"] = origin }
        return h
    }
}

struct TVBoxDepotEntry: Hashable, Identifiable {
    var name: String
    var url: String
    var id: String { url }
}

/// What an address / file turned out to be.
enum ParsedConfig {
    case config(TVBoxConfig)
    case depot([TVBoxDepotEntry])
    /// Not a config at all but a channel list (M3U / TXT / JSON groups).
    case live(String)
}

struct TVBoxConfig: Equatable {
    var spider = ""
    var sites: [TVBoxSite] = []
    var lives: [TVBoxLive] = []
    var parses: [TVBoxParse] = []
    var flags: [String] = []
    var rules: [TVBoxRule] = []
    var ads: [String] = []
    var headers: [TVBoxHeaderRule] = []
    var hosts: [String: String] = [:]
    var doh: [TVBoxDoh] = []
    var name = ""
    var logo = ""
    var wallpaper = ""
    var notice = ""

    /// Contains anything that would execute downloaded code (drives the trust prompt).
    var hasCode: Bool {
        sites.contains { $0.kind.isCode } || lives.contains { $0.kind?.isCode == true } || parses.contains { $0.type == 2 || $0.type == 3 }
    }

    func jarOf(_ site: TVBoxSite) -> String { site.jar.isEmpty ? spider : site.jar }
    func jarOf(_ live: TVBoxLive) -> String { live.jar.isEmpty ? spider : live.jar }

    // MARK: Identity

    static func siteUid(_ repoId: String, _ key: String) -> String { uid("\(repoId)|\(key)") }
    static func liveUid(_ repoId: String, _ identity: String) -> String { uid("\(repoId)|live|\(identity)") }

    /// First 12 hex digits of the md5; computed for every site of every config, so no formatting helpers.
    private static func uid(_ seed: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(12)
        for b in Bytes.md5(seed).prefix(6) { out.append(hexDigits[Int(b >> 4)]); out.append(hexDigits[Int(b & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }
    private static let hexDigits = Array("0123456789abcdef".utf8)

    // MARK: Parsing

    /// Looks like something `parse` accepts as a config or depot (used where several formats may be pasted).
    static func isConfig(_ text: String) -> Bool {
        let t = text.withoutBOM
        guard t.contains("{"), let o = LenientJson.objectOrNull(t) else { return false }
        return ["sites", "lives", "spider", "storeHouse"].contains { o.has($0) } || (o.optJSONArray("urls") != nil && !o.has("plugins"))
    }

    /// `text` is already decoded; `base` resolves relative addresses.
    static func parse(_ text: String, _ base: String) throws -> ParsedConfig {
        let t = text.withoutBOM
        if LiveParser.looksLikeList(t) { return .live(text) }
        if t.hasPrefix("<") { throw LenientJson.Malformed("这个地址返回的是网页，不是 TVBox 配置") }
        guard let start = t.firstIndex(where: { $0 == "{" || $0 == "[" }) else { throw LenientJson.Malformed("不是 TVBox 配置或直播列表") }
        var root: Any
        do { root = try LenientJson.parse(t) } catch {
            if start == t.startIndex { throw error }
            root = try LenientJson.parse(String(t[start...]))
        }
        root = TVBoxUrl.resolveTree(root, base)
        if let a = root as? [Any] {
            if LiveParser.isJsonGroups(a) { return .live(text) }
            throw LenientJson.Malformed("不是 TVBox 配置")
        }
        guard let o = root as? JSONObject else { throw LenientJson.Malformed("不是 TVBox 配置") }
        if let d = depot(o) { return .depot(d) }
        guard ["sites", "lives", "spider", "parses"].contains(where: { o.has($0) }) else {
            throw LenientJson.Malformed(J.firstNonEmpty(o.string("msg"), o.string("message"), o.string("error")).nonEmptyOr("不是 TVBox 配置（缺少 sites / lives / spider）"))
        }
        let c = config(o)
        if c.sites.isEmpty && c.lives.isEmpty {
            throw LenientJson.Malformed(J.firstNonEmpty(o.string("msg"), o.string("warningText")).nonEmptyOr("配置里没有点播站点，也没有直播列表"))
        }
        return .config(c)
    }

    private static func depot(_ o: JSONObject) -> [TVBoxDepotEntry]? {
        let urls = o.optJSONArray("urls"), store = o.optJSONArray("storeHouse")
        if urls == nil && store == nil { return nil }
        var list: [TVBoxDepotEntry] = []
        for case let e as JSONObject in store ?? [] { list.append(TVBoxDepotEntry(name: e.string("sourceName").trimmed, url: e.string("sourceUrl").trimmed)) }
        for e in urls ?? [] {
            if let x = e as? JSONObject { list.append(TVBoxDepotEntry(name: x.string("name").trimmed, url: x.string("url").trimmed)) }
            else if let s = e as? String { list.append(TVBoxDepotEntry(name: "", url: s.trimmed)) }
        }
        var seen = Set<String>()
        list = list.filter { !$0.url.isEmpty && seen.insert($0.url).inserted }
        for i in list.indices where list[i].name.isEmpty { list[i].name = TVBoxUrl.host(list[i].url).nonEmptyOr("线路 \(i + 1)") }
        return !list.isEmpty && (store != nil || !o.has("sites")) ? list : nil
    }

    private static func objects(_ v: Any?) -> [JSONObject] { J.arr(v).compactMap { $0 as? JSONObject } }

    private static func distinct<T, K: Hashable>(_ list: [T], _ key: (T) -> K) -> [T] {
        var seen = Set<K>()
        return list.filter { seen.insert(key($0)).inserted }
    }

    private static func config(_ o: JSONObject) -> TVBoxConfig {
        var c = TVBoxConfig()
        c.spider = o.string("spider").trimmed
        c.sites = distinct(objects(o["sites"]).compactMap(site)) { $0.key }
        c.lives = lives(J.arr(o["lives"]))
        c.parses = distinct(objects(o["parses"]).compactMap(parseEntry)) { $0.name }
        c.flags = strings(o["flags"])
        c.rules = objects(o["rules"]).compactMap(rule)
        c.ads = strings(o["ads"])
        c.headers = objects(o["headers"]).map { TVBoxHeaderRule(host: $0.string("host").trimmed.lowercased(), headers: headerMap($0["header"] ?? $0["headers"])) }.filter { !$0.host.isEmpty }
        c.hosts = hosts(o["hosts"])
        c.doh = objects(o["doh"]).map { TVBoxDoh(name: $0.string("name"), url: $0.string("url").trimmed, ips: strings($0["ips"])) }.filter { $0.url.hasPrefix("https://") }
        c.name = String(J.firstNonEmpty(o.string("name"), o.string("title")).prefix(60))
        c.logo = o.string("logo")
        c.wallpaper = o.string("wallpaper")
        c.notice = J.firstNonEmpty(o.string("notice"), o.string("warningText"))
        return c
    }

    private static let adult = TVBoxRegex("🔞|18\\+|18禁|成人|情色|\\bporn\\b", .caseInsensitive)

    private static func timeout(_ v: Any?) -> Int {
        let t = Int(J.int64(v))
        let ms = t <= 0 ? TVBoxSite.defaultTimeoutMs : t < 1000 ? t * 1000 : t
        return min(max(ms, 3_000), 60_000)
    }

    private static func site(_ o: JSONObject) -> TVBoxSite? {
        let api = o.string("api").trimmed, name = o.string("name").trimmed
        let key = o.string("key").trimmed.nonEmptyOr(name.nonEmptyOr(api))
        if key.isEmpty || (api.isEmpty && name.isEmpty) { return nil }
        var s = TVBoxSite(key: key, name: String(name.nonEmptyOr(key).prefix(60)), type: J.int(o["type"]), api: api)
        s.ext = ext(o["ext"])
        s.jar = o.string("jar").trimmed
        s.playUrl = o.string("playUrl").trimmed
        s.click = o.string("click").trimmed
        s.searchable = flag(o, "searchable")
        s.quickSearch = flag(o, "quickSearch")
        s.filterable = flag(o, "filterable")
        s.changeable = flag(o, "changeable")
        s.hide = J.int(o["hide"]) == 1
        s.timeoutMs = timeout(o["timeout"])
        s.headers = headerMap(o["header"] ?? o["headers"])
        s.categories = strings(o["categories"])
        s.adult = J.bool(o["adult"]) || adult.test(name)
        return s
    }

    private static func flag(_ o: JSONObject, _ k: String) -> Bool {
        if o.isNull(k) { return true }
        let v = o.string(k)
        return v != "0" && v != "false"
    }

    /// Objects / arrays become compact JSON, everything else its text.
    static func ext(_ v: Any?) -> String {
        switch v {
        case let o as JSONObject: return o.toString()
        case let s as String: return s.trimmed
        case let a as [Any]: return JSONObject.text(a)
        default: return J.str(v)
        }
    }

    static func strings(_ v: Any?) -> [String] {
        switch v {
        case let s as String: return s.pieces(",").map(\.trimmed).filter { !$0.isEmpty }
        case let a as [Any]: return a.map { J.str($0).trimmed }.filter { !$0.isEmpty }
        default: return []
        }
    }

    /// Header object, JSON text of one, or `k=v&k=v`.
    static func headerMap(_ v: Any?) -> [String: String] {
        switch v {
        case let o as JSONObject:
            var out: [String: String] = [:]
            for k in o.keys {
                let x = o[k]
                let s = x is JSONObject || x is [Any] ? JSONObject.text(x) : J.str(x)
                if !s.isEmpty { out[TVBoxUrl.headerName(k)] = s }
            }
            return out
        case let s as String:
            let t = s.trimmed
            if t.hasPrefix("{") { return LenientJson.objectOrNull(t).map { headerMap($0) } ?? [:] }
            return t.contains("=") ? TVBoxUrl.headerQuery(t) : [:]
        default: return [:]
        }
    }

    private static func hosts(_ v: Any?) -> [String: String] {
        var out: [String: String] = [:]
        func add(_ k: String, _ x: String) {
            let key = k.trimmed.lowercased(), value = x.trimmed
            if !key.isEmpty && !value.isEmpty { out[key] = value }
        }
        if let o = v as? JSONObject { for k in o.keys { add(k, o.string(k)) } }
        else {
            for e in J.arr(v).map({ J.str($0) }) where e.contains("=") { add(e.substringBefore("="), e.substringAfter("=")) }
        }
        return out
    }

    private static func parseEntry(_ o: JSONObject) -> TVBoxParse? {
        let name = o.string("name").trimmed, url = o.string("url").trimmed, type = J.int(o["type"])
        if name.isEmpty || (url.isEmpty && type != 4) { return nil }
        let e = o.optJSONObject("ext")
        return TVBoxParse(name: name, type: type, url: url, flags: strings(e?["flag"]), headers: headerMap(e?["header"]), ext: ext(o["ext"]))
    }

    private static func rule(_ o: JSONObject) -> TVBoxRule? {
        let host = o.string("host")
        let hosts = strings(o["hosts"]) + (host.trimmed.isEmpty ? [] : [host])
        let regex = texts(o["regex"]) + texts(o["rule"])
        let exclude = texts(o["exclude"]) + texts(o["filter"])
        let script = texts(o["script"])
        if hosts.isEmpty || (regex.isEmpty && exclude.isEmpty && script.isEmpty) { return nil }
        return TVBoxRule(name: o.string("name"), hosts: hosts, regex: regex, exclude: exclude, script: script)
    }

    /// Rule texts may contain commas: never split a plain string.
    private static func texts(_ v: Any?) -> [String] {
        switch v {
        case let s as String: return s.isEmpty ? [] : [s]
        case let a as [Any]: return a.map { J.str($0) }.filter { !$0.isEmpty }
        default: return []
        }
    }

    private static func lives(_ list: [Any]) -> [TVBoxLive] {
        var out: [TVBoxLive] = [], inline: [Any] = []
        for case let o as JSONObject in list {
            let channels = o.optJSONArray("channels") ?? o.optJSONArray("channel")
            if let channels, o.string("group") == "redirect" { out += redirects(o, channels) }
            else if channels != nil && !o.has("url") && !o.has("api") { inline.append(o) }
            else if let l = live(o) { out.append(l) }
        }
        if !inline.isEmpty { out.insert(TVBoxLive(name: "配置直播", groups: LiveParser.json(inline)), at: 0) }
        return distinct(out) { $0.identity }
    }

    private static func redirects(_ o: JSONObject, _ channels: [Any]) -> [TVBoxLive] {
        var out: [TVBoxLive] = []
        for (i, c) in channels.enumerated() {
            guard let ch = c as? JSONObject else { continue }
            let urls = texts(ch["urls"])
            for (j, u) in urls.enumerated() {
                let real = proxyLive(u)
                if real.isEmpty { continue }
                let name = J.firstNonEmpty(ch.string("name"), o.string("name")).nonEmptyOr("直播 \(i + 1)") + (urls.count > 1 ? " \(j + 1)" : "")
                var l = TVBoxLive(name: name, url: real)
                l.epg = o.string("epg")
                l.ua = o.string("ua")
                out.append(l)
            }
        }
        return out
    }

    /// `proxy://do=live&type=txt&ext=<base64 address>` → the list address.
    static func proxyLive(_ u: String) -> String {
        guard u.hasPrefixIgnoringCase("proxy://") else { return u }
        var q: [String: String] = [:]
        for p in String(u.dropFirst(8)).pieces("&") {
            guard let i = p.firstIndex(of: "="), i > p.startIndex else { continue }
            q[String(p[..<i])] = String(p[p.index(after: i)...])
        }
        guard let ext = q["ext"] ?? q["url"] else { return "" }
        if TVBoxUrl.isHttp(ext) { return ext }
        let raw = TVBoxUrl.decode(ext)
        let plain = TVBoxDecoder.base64(raw).map { String(decoding: $0, as: UTF8.self).trimmed } ?? ""
        if TVBoxUrl.isHttp(plain) || TVBoxUrl.isLocal(plain) { return plain }
        return TVBoxUrl.isHttp(raw) ? raw : ""
    }

    private static func live(_ o: JSONObject) -> TVBoxLive? {
        let url = proxyLive(o.string("url").trimmed), api = o.string("api").trimmed
        let groups: [LiveGroup]
        if let g = o.optJSONArray("groups") { groups = LiveParser.json(g) }
        else if o.optJSONArray("channels") != nil { groups = LiveParser.json([o]) }
        else { groups = [] }
        if url.isEmpty && api.isEmpty && groups.isEmpty { return nil }
        var l = TVBoxLive(name: String(o.string("name").trimmed.nonEmptyOr(TVBoxUrl.host(url).nonEmptyOr("直播")).prefix(60)))
        l.type = J.int(o["type"])
        l.url = url
        l.api = api
        l.ext = ext(o["ext"])
        l.jar = o.string("jar").trimmed
        l.epg = o.string("epg").trimmed
        l.logo = o.string("logo").trimmed
        l.ua = o.string("ua").trimmed
        l.referer = o.string("referer").trimmed
        l.origin = o.string("origin").trimmed
        l.headers = headerMap(o["header"] ?? o["headers"])
        l.timeZone = o.string("timeZone").trimmed
        l.timeoutMs = timeout(o["timeout"])
        l.pass = J.bool(o["pass"])
        l.catchup = o.optJSONObject("catchup").flatMap(Catchup.fromJSON)
        l.groups = groups
        return l
    }
}
