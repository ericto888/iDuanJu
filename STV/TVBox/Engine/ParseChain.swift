import Foundation

/// A named address (quality or line name, may be empty).
struct PlayUrl: Hashable {
    var name: String
    var url: String
}

/// Normalised `playerContent` result.
struct PlayerResult: Equatable {
    var parse = 1
    var jx = 0
    var urls: [PlayUrl] = []
    var headers: [String: String] = [:]
    var playUrl = ""
    var subs: [HGSubtitle] = []
    var danmaku = ""
    var format = ""
    var click = ""
    var flag = ""
    var message = ""
    /// The result said `parse` itself (both TVBox lineages treat a missing one as "needs parsing").
    var parseGiven = true

    static func parse(_ text: String) throws -> PlayerResult {
        guard let o = LenientJson.objectOrNull(text) else { throw ProviderError.upstream("站点没有返回播放信息") }
        return fromJSON(o)
    }

    static func fromJSON(_ o: JSONObject) -> PlayerResult {
        var r = PlayerResult()
        r.parseGiven = !o.isNull("parse")
        r.parse = r.parseGiven ? J.int(o["parse"]) : 1
        r.jx = J.int(o["jx"])
        r.urls = urls(o["url"])
        if r.urls.isEmpty { r.urls = urls(o["urls"]) }
        r.headers = TVBoxConfig.headerMap(o["header"])
        if r.headers.isEmpty { r.headers = TVBoxConfig.headerMap(o["headers"]) }
        r.playUrl = o.string("playUrl").trimmed
        for case let s as JSONObject in J.arr(o["subs"]) where !s.string("url").isEmpty {
            r.subs.append(HGSubtitle(name: s.string("name").nonEmptyOr("字幕"), url: s.string("url"), language: s.string("lang").nilIfEmpty, format: s.string("format").nilIfEmpty))
        }
        if r.subs.isEmpty, o.string("subt").contains("://") { r.subs = [HGSubtitle(name: "字幕", url: o.string("subt"))] }
        r.danmaku = danmaku(o["danmaku"])
        let format = o.string("format")
        r.format = format.isEmpty ? "" : LiveParser.mime(format)
        r.click = o.string("click")
        r.flag = o.string("flag")
        r.message = J.firstNonEmpty(o.string("msg"), o.string("error"))
        return r
    }

    /// `"url"`, `["name", "url", …]`, the same as JSON text, or `{"values":[{"n","v"}]}`.
    private static func urls(_ v: Any?) -> [PlayUrl] {
        switch v {
        case let s as String:
            let t = s.trimmed
            if t.hasPrefix("["), let a = LenientJson.arrayOrNull(t) {
                let list = urls(a)
                if !list.isEmpty { return list }
            }
            return t.isEmpty ? [] : [PlayUrl(name: "", url: t)]
        case let o as JSONObject:
            let list = urls(o.optJSONArray("values"))
            return list.isEmpty ? urls(o.string("url")) : list
        case let a as [Any]:
            var out: [PlayUrl] = []
            if a.allSatisfy({ $0 is JSONObject }) {
                for case let e as JSONObject in a { out.append(PlayUrl(name: J.firstNonEmpty(e.string("n"), e.string("name")), url: J.firstNonEmpty(e.string("v"), e.string("url")))) }
            } else if a.count == 1 { out = [PlayUrl(name: "", url: J.str(a[0]))] }
            else { for i in stride(from: 0, to: a.count - 1, by: 2) { out.append(PlayUrl(name: J.str(a[i]), url: J.str(a[i + 1]))) } }
            return out.filter { !$0.url.trimmed.isEmpty }
        default: return []
        }
    }

    private static func danmaku(_ v: Any?) -> String {
        switch v {
        case let s as String: return s.trimmed
        case let o as JSONObject: return o.string("url")
        case let a as [Any]: return a.lazy.map { ($0 as? JSONObject)?.string("url") ?? J.str($0) }.first { !$0.isEmpty } ?? ""
        default: return ""
        }
    }
}

enum SniffRules {
    static func rulesFor(_ host: String, _ rules: [TVBoxRule]) -> [TVBoxRule] {
        let h = host.lowercased()
        return rules.filter { $0.matches(h) }
    }

    private static func mine(_ u: String, _ page: String, _ rules: [TVBoxRule]) -> [TVBoxRule] {
        if rules.isEmpty { return [] }
        return rulesFor(TVBoxUrl.host(u), rules) + rulesFor(TVBoxUrl.host(page), rules)
    }

    static func excluded(_ u: String, _ page: String, _ rules: [TVBoxRule]) -> Bool { mine(u, page, rules).contains { $0.exclude.contains { hit(u, $0) } } }

    /// `page` decides which rules apply, `u` is the request being looked at.
    static func isVideo(_ u: String, _ page: String, _ rules: [TVBoxRule]) -> Bool {
        if !TVBoxUrl.isHttp(u) && !TVBoxUrl.isVideo(u) { return false }
        let own = mine(u, page, rules)
        if own.contains(where: { $0.exclude.contains { hit(u, $0) } }) { return false }
        // several regexes of one old-style rule must all match; new-style rules list alternatives
        if own.contains(where: { $0.regex.contains { hit(u, $0) } }) { return true }
        return TVBoxUrl.isVideo(u)
    }

    private static func hit(_ u: String, _ pattern: String) -> Bool { u.contains(pattern) || (TVBoxRegex(user: pattern)?.test(u) ?? false) }

    static func isAd(_ host: String, _ ads: [String]) -> Bool {
        ads.contains { a in
            !a.isEmpty && (host == a || host.hasSuffix("." + a) || (a.count > 4 && host.contains(a)) || (TVBoxRegex(user: a, whole: true)?.test(host) ?? false))
        }
    }
}

/// `com.github.catvod.parser.Json* / Mix*` of the config's jar.
protocol JarParsers {
    func json(_ key: String, _ jxs: [String: String], _ url: String) async throws -> JSONObject?
    func mix(_ key: String, _ name: String, _ flag: String, _ jxs: [String: [String: String]], _ url: String) async throws -> JSONObject?
}

struct ParsedVideo: Equatable {
    var urls: [PlayUrl]
    var headers: [String: String]
    var via = ""
}

/// Contract §3 "播放解析": what still has to happen between `playerContent` and a playable address.
struct ParseChain {
    let config: TVBoxConfig
    let http: TVBoxHttp
    let sniffer: Sniffer
    let jar: JarParsers?
    let allowPrivate: Bool
    var preferred = ""
    var timeoutMs = 15_000

    typealias Manual = (String) async -> Bool

    private struct Ctx {
        let headers: [String: String]
        let flag: String
        let scripts: [String]
        let manual: Manual?
    }

    /// `manual` = the spider asked to judge sniffed requests itself.
    func resolve(_ r: PlayerResult, _ flag: String, click: String = "", manual: Manual? = nil) async throws -> ParsedVideo {
        guard let first = r.urls.first?.url else { throw ProviderError.upstream(r.message.nonEmptyOr("站点没有返回播放地址")) }
        if let p = TVBoxUrl.p2p(first) { throw TVBoxError("\(p) 链接需要 P2P 内核，暂不支持") }
        let ctx = Ctx(headers: r.headers, flag: flag.nonEmptyOr(r.flag), scripts: [r.click, click].filter { !$0.trimmed.isEmpty }, manual: manual)
        if r.playUrl.hasPrefix("json:") { return try await json(TVBoxParse(name: "json", type: 1, url: String(r.playUrl.dropFirst(5))), first, ctx) }
        if r.playUrl.hasPrefix("parse:") {
            let name = String(r.playUrl.dropFirst(6))
            guard let p = config.parses.first(where: { $0.name == name }) else { throw TVBoxError("配置里没有名为「\(name)」的解析") }
            return try await run(p, first, ctx)
        }
        if r.jx == 1 { return try await parses(first, ctx) }
        if r.parse == 0 { return ParsedVideo(urls: r.urls.map { PlayUrl(name: $0.name, url: r.playUrl + $0.url) }, headers: r.headers) }
        if r.playUrl.isEmpty, !flag.isEmpty, config.flags.contains(where: { $0.caseInsensitiveCompare(flag) == .orderedSame }) { return try await parses(first, ctx) }
        if r.playUrl.isEmpty, TVBoxUrl.isVideo(TVBoxUrl.vod(first).url) || (!r.parseGiven && ownProxy(first)) { return ParsedVideo(urls: r.urls, headers: r.headers) }
        return try await sniff(r.playUrl + first, r.headers, ctx)
    }

    /// A stream of the app's own proxy: only an explicit `parse=1` sends it through the browser.
    private func ownProxy(_ u: String) -> Bool { u.hasPrefix("proxy://") || (u.hasPrefix("http://127.0.0.1:") && u.contains("/proxy?")) }

    /// Parse entries for a flag: the ones that name it, else the ones that name none, else all.
    private func candidates(_ type: Int, _ flag: String) -> [TVBoxParse] {
        let all = config.parses.filter { $0.type == type }
        let named = all.filter { $0.flags.contains { $0.caseInsensitiveCompare(flag) == .orderedSame } }
        if !named.isEmpty { return named }
        let open = all.filter { $0.flags.isEmpty }
        return open.isEmpty ? all : open
    }

    private func parses(_ url: String, _ ctx: Ctx) async throws -> ParsedVideo {
        if config.parses.isEmpty { return try await sniff(url, ctx.headers, ctx) }
        if !preferred.isEmpty, let p = config.parses.first(where: { $0.name == preferred }) {
            do { return try await run(p, url, ctx) } catch {
                try Task.checkCancellation()
                if config.parses.count == 1 { throw error }
            }
        }
        return try await superParse(url, ctx)
    }

    private func run(_ p: TVBoxParse, _ url: String, _ ctx: Ctx) async throws -> ParsedVideo {
        switch p.type {
        case 0: return try await sniff(p.url + url, p.headers.isEmpty ? ctx.headers : p.headers, ctx, p.name)
        case 1: return try await json(p, url, ctx)
        case 2:
            var jxs: [String: String] = [:]
            for x in config.parses where x.type == 1 { jxs[x.name] = extUrl(x) }
            let o = try await needJar().json(p.url, jxs, url)
            return try await ext(p.name, ctx, o)
        case 3:
            var jxs: [String: [String: String]] = [:]
            for x in config.parses { jxs[x.name] = ["type": String(x.type), "ext": x.ext, "url": x.url] }
            let o = try await needJar().mix(p.url, p.name, ctx.flag, jxs, url)
            return try await ext(p.name, ctx, o)
        case 4: return try await superParse(url, ctx)
        default: throw TVBoxError("不支持的解析类型 \(p.type)")
        }
    }

    private func needJar() throws -> JarParsers {
        guard let jar else { throw TVBoxError("这个解析依赖 JAR，需要配对 Android 桥接并信任当前配置") }
        return jar
    }

    /// JSON parses receive their own options as `cat_ext` (CatVod convention).
    private func extUrl(_ p: TVBoxParse) -> String {
        guard !p.ext.isEmpty, let i = p.url.firstIndex(of: "?") else { return p.url }
        let after = p.url.index(after: i)
        let b64 = Data(p.ext.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "\(p.url[..<after])cat_ext=\(b64)&\(p.url[after...])"
    }

    private func json(_ p: TVBoxParse, _ url: String, _ ctx: Ctx) async throws -> ParsedVideo {
        let r = try await http.fetch(NetRequest(url: p.url + url, headers: p.headers, timeoutMs: timeoutMs))
        if !r.ok { throw ProviderError.upstream("解析「\(p.name)」HTTP \(r.code)") }
        guard let o = LenientJson.objectOrNull(r.text()) else { throw ProviderError.upstream("解析「\(p.name)」没有返回 JSON") }
        return try await result(o, p.name, ctx)
    }

    private func ext(_ name: String, _ ctx: Ctx, _ o: JSONObject?) async throws -> ParsedVideo {
        guard let o else { throw ProviderError.upstream("解析「\(name)」没有结果") }
        return try await result(o, name, ctx)
    }

    private func result(_ root: JSONObject, _ name: String, _ ctx: Ctx) async throws -> ParsedVideo {
        var o = root
        if let d = root.optJSONObject("data"), d.has("url") { o = d }
        let r = PlayerResult.fromJSON(o)
        let url = r.urls.first?.url ?? ""
        var headers = r.headers
        for k in o.keys where ["user-agent", "referer", "ua"].contains(k.lowercased()) {
            let v = o.string(k)
            if !v.isEmpty { headers[TVBoxUrl.headerName(k)] = v }
        }
        if !TVBoxUrl.isHttp(url), !TVBoxUrl.isVideo(url), !url.hasPrefix("proxy://") {
            throw ProviderError.upstream("解析「\(name)」没有给出播放地址" + (r.message.isEmpty ? "" : "：\(r.message)"))
        }
        if J.int(o["parse"]) == 1 || r.jx == 1, !TVBoxUrl.isVideo(url) { return try await sniff(url, headers, ctx, name) }
        return ParsedVideo(urls: r.urls, headers: headers, via: name)
    }

    private func sniff(_ url: String, _ headers: [String: String], _ ctx: Ctx, _ via: String = "") async throws -> ParsedVideo {
        if !TVBoxUrl.isHttp(url) { throw TVBoxError("无法解析的播放地址：\(url.prefix(60))") }
        var seen = Set<String>()
        let scripts = (ctx.scripts + SniffRules.rulesFor(TVBoxUrl.host(url), config.rules).flatMap(\.script)).filter { seen.insert($0).inserted }
        let s = try await sniffer.sniff(SniffRequest(url: url, headers: headers, scripts: scripts, rules: config.rules, ads: config.ads, allowPrivate: allowPrivate, timeoutMs: timeoutMs, isVideo: ctx.manual))
        return ParsedVideo(urls: [PlayUrl(name: "", url: s.url)], headers: s.headers, via: via)
    }

    /// 超级解析: JSON parses and (at most two at a time) browser parses race; the first playable address wins and cancels the rest.
    private func superParse(_ url: String, _ ctx: Ctx) async throws -> ParsedVideo {
        let jsons = candidates(1, ctx.flag), webs = candidates(0, ctx.flag)
        let exts = jar == nil ? [] : candidates(2, ctx.flag) + candidates(3, ctx.flag)
        if jsons.isEmpty && webs.isEmpty && exts.isEmpty { return try await sniff(url, ctx.headers, ctx) }
        let gate = AsyncGate(2)
        let budget = UInt64(timeoutMs) * 2_000_000
        return try await withThrowingTaskGroup(of: Result<ParsedVideo, Error>?.self) { group in
            let tasks = jsons + exts + webs
            for p in tasks {
                group.addTask {
                    do {
                        if p.type != 0 { return .success(try await run(p, url, ctx)) }
                        return .success(try await gate.run { try await run(p, url, ctx) })
                    } catch { return .failure(error) }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: budget)
                return nil
            }
            defer { group.cancelAll() }
            var left = tasks.count
            var last: Error?
            while left > 0, let next = try await group.next() {
                guard let r = next else { break }
                left -= 1
                switch r {
                case .success(let v): return v
                case .failure(let e): if !(e is CancellationError) { last = e }
                }
            }
            try Task.checkCancellation()
            if let e = last, e is ProviderError || e is TVBoxError { throw e }
            throw ProviderError.upstream("所有解析都没有返回播放地址")
        }
    }
}

/// Bounded parallelism for tasks.
actor AsyncGate {
    private var free: Int
    private var waiters: [(id: Int, go: CheckedContinuation<Bool, Never>)] = []
    private var nextId = 0

    init(_ n: Int) { free = n }

    /// Throws `CancellationError` when the task is cancelled while it waits.
    func run<T>(_ body: @escaping () async throws -> T) async throws -> T {
        try await enter()
        defer { leave() }
        return try await body()
    }

    private func enter() async throws {
        try Task.checkCancellation()
        if free > 0 { free -= 1; return }
        nextId += 1
        let id = nextId
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { await self.drop(id) }
        }
        if !granted { throw CancellationError() }
    }

    private func drop(_ id: Int) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).go.resume(returning: false)
    }

    private func leave() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().go.resume(returning: true) }
    }
}
