import Foundation

/// 苹果 CMS collect interface, JSON (`type` 1) or XML (`type` 0).
final class CmsSpider: Spider {
    private let site: TVBoxSite
    private let http: TVBoxHttp
    private let detailAc: String
    private let tag = NSObject()

    init(_ site: TVBoxSite, _ http: TVBoxHttp) {
        self.site = site
        self.http = http
        detailAc = site.kind == .cmsXml ? "videolist" : "detail"
    }

    private func get(_ q: [(String, String)]) throws -> String {
        guard TVBoxUrl.target(site.api) != nil else { throw ProviderError.invalid("采集接口地址无效") }
        return try Self.decode(http.text(TVBoxUrl.withQuery(site.api, q), headers: site.headers, timeoutMs: site.timeoutMs, tag: tag)).toString()
    }

    func homeContent(filter: Bool) throws -> String { try get([("ac", "list")]) }
    func homeVideoContent() throws -> String { try get([("ac", detailAc), ("pg", "1")]) }

    func categoryContent(tid: String, pg: String, filter: Bool, extend: [String: String]) throws -> String {
        var q = [("ac", detailAc), ("t", tid), ("pg", pg)]
        if !extend.isEmpty { q.append(("f", JSONObject.text(extend))) }
        return try get(q)
    }

    func detailContent(ids: [String]) throws -> String { try get([("ac", detailAc), ("ids", ids.joined(separator: ","))]) }

    func searchContent(key: String, quick: Bool, pg: String) throws -> String {
        var q = [("ac", detailAc), ("wd", key)]
        if pg != "1" && !pg.isEmpty { q.append(("pg", pg)) }
        return try get(q)
    }

    func playerContent(flag: String, id: String, vipFlags: [String]) throws -> String {
        let direct = site.playUrl.isEmpty && TVBoxUrl.isVideo(TVBoxUrl.stream(id).url)
        return JSONObject().put("parse", direct ? 0 : 1).put("url", id).put("flag", flag).put("playUrl", site.playUrl).put("header", JSONObject(site.headers)).toString()
    }

    func interrupt() { http.cancel(tag) }

    private static let declaration = TVBoxRegex("^<\\?xml[^>]*\\?>", .caseInsensitive)

    static func decode(_ body: String) throws -> JSONObject {
        let t = body.withoutBOM
        let parsed: JSONObject?
        // the text is decoded already: a declared legacy encoding would be applied a second time
        if t.hasPrefix("<") { parsed = CMSXML.decode(Data(declaration.replace(t) { _ in "" }.utf8)).map { JSONObject($0) } }
        else { parsed = LenientJson.objectOrNull(t) }
        guard let o = parsed else { throw ProviderError.upstream("站点没有返回有效的 CMS JSON / XML") }
        if o.has("code"), !o.has("list"), !o.has("class"), !["1", "200"].contains(o.string("code")) { throw ProviderError.upstream("站点：" + o.string("msg").nonEmptyOr("请求失败")) }
        return o
    }
}

/// T4 / hipy remote interface (`type` 4): the same content calls as query parameters.
final class RemoteSpider: Spider {
    private let site: TVBoxSite
    private let http: TVBoxHttp
    private let localExt: Bool
    private var extend = ""
    /// Address of parameters that could not be read yet.
    private var pending: String?
    private var retryAt = Date.distantPast
    private let tag = NSObject()

    /// `localExt`: parameters in an imported file (or behind this device's own proxy) may be read. They are sent to the site, so
    /// only a local config with a server on this device may name them.
    init(_ site: TVBoxSite, _ http: TVBoxHttp, localExt: Bool = false) { self.site = site; self.http = http; self.localExt = localExt }

    func start(ext: String) throws {
        extend = ext
        guard TVBoxUrl.isHttp(ext) || TVBoxUrl.isLocal(ext), localExt || !(TVBoxUrl.isLocal(ext) || TVBoxNet.isLoopback(ext)) else { return }
        pending = ext
        try load()
    }

    /// A failed read is tried again now and then; an interrupted one ends the call.
    private func load() throws {
        guard let address = pending, Date() >= retryAt else { return }
        do {
            let r = try http.execute(NetRequest(url: address, headers: site.headers, timeoutMs: site.timeoutMs, tag: tag, loopback: localExt))
            if !r.ok { throw TVBoxIOError("HTTP \(r.code)") }
            extend = r.text().trimmed
            pending = nil
        } catch let e as URLError where e.code == .cancelled { throw e } catch { retryAt = Date().addingTimeInterval(60) }
    }

    private func call(_ params: [(String, String)]) throws -> String {
        guard TVBoxUrl.target(site.api) != nil else { throw ProviderError.invalid("站点接口地址无效") }
        try load()
        let q = extend.isEmpty ? params : params + [("extend", extend)]
        let r: NetRequest
        if extend.utf16.count <= 1000 {
            r = NetRequest(url: TVBoxUrl.withQuery(site.api, q), headers: site.headers, timeoutMs: site.timeoutMs, tag: tag)
        } else {
            let form = q.map { GoURL.queryEscape($0.0) + "=" + GoURL.queryEscape($0.1) }.joined(separator: "&")
            r = NetRequest(url: site.api, method: "POST", headers: site.headers.merging(["Content-Type": "application/x-www-form-urlencoded"]) { $1 },
                           body: Data(form.utf8), timeoutMs: site.timeoutMs, tag: tag)
        }
        let resp = try http.execute(r)
        if !resp.ok { throw ProviderError.upstream("站点 HTTP \(resp.code) · \(TVBoxUrl.host(site.api))") }
        return resp.text()
    }

    func homeContent(filter: Bool) throws -> String { try call([("filter", filter ? "true" : "false")]) }

    func categoryContent(tid: String, pg: String, filter: Bool, extend: [String: String]) throws -> String {
        try call([("ac", "detail"), ("t", tid), ("pg", pg), ("ext", Data(JSONObject.text(extend).utf8).base64EncodedString())])
    }

    func detailContent(ids: [String]) throws -> String { try call([("ac", "detail"), ("ids", ids.joined(separator: ","))]) }

    func searchContent(key: String, quick: Bool, pg: String) throws -> String {
        var q = [("wd", key), ("quick", quick ? "true" : "false")]
        if pg != "1" && !pg.isEmpty { q.append(("pg", pg)) }
        return try call(q)
    }

    func playerContent(flag: String, id: String, vipFlags: [String]) throws -> String { try call([("play", id), ("flag", flag)]) }
    func action(_ action: String) throws -> String { try call([("ac", "action"), ("action", action)]) }
    func interrupt() { http.cancel(tag) }
}
