import Foundation

// Seams of the TVBox engine. Port of `android/core/.../tvbox` (same names, same behaviour; both platforms run
// `shared/tvbox/cases.json`). Everything here is blocking and confined to the caller's thread unless marked async.

// MARK: Site kinds

enum SiteKind: String, Codable, Sendable {
    case cmsXml = "cms-xml", cmsJson = "cms-json", remote, jar, js, py, unsupported

    var badge: String {
        switch self {
        case .cmsXml, .cmsJson: return "CMS"
        case .remote: return "T4"
        case .jar: return "JAR"
        case .js: return "JS"
        case .py: return "PY"
        case .unsupported: return "不支持"
        }
    }

    /// Runs downloaded code on the device (or, for JAR, on the paired one): needs the config's trust.
    var isCode: Bool { self == .jar || self == .js || self == .py }

    static func of(type: Int, api: String) -> SiteKind {
        let path = api.substringBefore("?").substringBefore("#").lowercased()
        let query = api.substringAfter("?", "").lowercased()
        switch type {
        case 0: return .cmsXml
        case 1: return .cmsJson
        case 4: return .remote
        case 3:
            if api.hasPrefix("csp_") { return .jar }
            if path.hasSuffix(".py") || api.hasPrefix("py_") { return .py }
            if path.hasSuffix(".js") || query.hasSuffix(".js") { return .js }
            if query.hasSuffix(".py") { return .py }
            return .unsupported
        default: return .unsupported
        }
    }
}

// MARK: HTTP seam

struct NetRequest {
    var url: String
    var method = "GET"
    var headers: [String: String] = [:]
    var body: Data? = nil
    var timeoutMs = 15_000
    var redirect = true
    var verify = true
    var maxBytes = NetRequest.defaultMaxBytes
    /// Requests carrying the same tag are aborted together.
    var tag: AnyObject? = nil
    /// False: not even the app's own proxy, on any hop (what comes back is sent on to a remote server).
    var loopback = true
    static let defaultMaxBytes = 20 << 20
}

struct NetResponse {
    let code: Int
    let url: String
    let headers: [String: [String]]
    let body: Data
    var ok: Bool { (200..<300).contains(code) }
    func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value.last }
}

/// Blocking HTTP: real client in the app, a table of canned replies in tests.
protocol TVBoxHttp: AnyObject {
    func execute(_ r: NetRequest) throws -> NetResponse
    /// Aborts the requests carrying `tag`.
    func cancel(_ tag: AnyObject)
}

// MARK: Spiders

/// Reply of `proxyLocal`. `stream` (when set) is pulled chunk by chunk by the local server; nil chunk = end.
struct ProxyReply {
    var code = 200
    var type = "application/octet-stream"
    var headers: [String: String] = [:]
    var body = Data()
    var stream: (() throws -> Data?)? = nil
    /// Total length when known (streams).
    var length: Int64 = -1

    static func text(_ s: String, code: Int = 200, type: String = "text/plain; charset=utf-8") -> ProxyReply {
        ProxyReply(code: code, type: type, body: Data(s.utf8))
    }

    /// `{"code","type","b64","headers"}` as produced by the JS / Python runners.
    static func fromRunner(_ json: String) -> ProxyReply? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        func s(_ v: Any?) -> String { v as? String ?? (v as? NSNumber)?.stringValue ?? "" }
        let headers = (o["headers"] as? [String: Any] ?? [:]).mapValues { s($0) }
        let code = Int(s(o["code"])) ?? 0
        let type = s(o["type"])
        return ProxyReply(code: code > 0 ? code : 200, type: type.isEmpty ? "application/octet-stream" : type, headers: headers,
                          body: Data(base64Encoded: s(o["b64"])) ?? Data())
    }
}

/// One TVBox site behind the common contract. Content methods return the TVBox JSON text ("" = nothing); calls are
/// blocking and confined to the owning `SpiderSession`'s thread.
protocol Spider: AnyObject {
    func start(ext: String) throws
    func homeContent(filter: Bool) throws -> String
    func homeVideoContent() throws -> String
    func categoryContent(tid: String, pg: String, filter: Bool, extend: [String: String]) throws -> String
    func detailContent(ids: [String]) throws -> String
    func searchContent(key: String, quick: Bool, pg: String) throws -> String
    func playerContent(flag: String, id: String, vipFlags: [String]) throws -> String
    func liveContent(url: String) throws -> String
    func proxyLocal(_ params: [String: String]) throws -> ProxyReply?
    func action(_ action: String) throws -> String
    func isVideoFormat(_ url: String) throws -> Bool
    func manualVideoCheck() throws -> Bool
    func destroy()
    /// Wakes the spider thread out of a network call (timeout / cancellation). Called from any thread.
    func interrupt()
    /// Before each call: what was interrupted before is over.
    func resume()
}

extension Spider {
    func start(ext: String) throws {}
    func homeContent(filter: Bool) throws -> String { "" }
    func homeVideoContent() throws -> String { "" }
    func categoryContent(tid: String, pg: String, filter: Bool, extend: [String: String]) throws -> String { "" }
    func detailContent(ids: [String]) throws -> String { "" }
    func searchContent(key: String, quick: Bool, pg: String) throws -> String { "" }
    func playerContent(flag: String, id: String, vipFlags: [String]) throws -> String { "" }
    func liveContent(url: String) throws -> String { "" }
    func proxyLocal(_ params: [String: String]) throws -> ProxyReply? { nil }
    func action(_ action: String) throws -> String { "" }
    func isVideoFormat(_ url: String) throws -> Bool { false }
    func manualVideoCheck() throws -> Bool { false }
    func destroy() {}
    func interrupt() {}
    func resume() {}
}

// MARK: Script runtimes

protocol ScriptStorage: AnyObject {
    func get(_ ns: String, _ k: String) -> String?
    func set(_ ns: String, _ k: String, _ v: String)
    func delete(_ ns: String, _ k: String)
}

/// The native half of `shared/tvbox/HOST_ABI.md`, one instance per script spider: `call(name, argsJson)` → `{"v":…}` / `{"e":…}`.
protocol ScriptHosting: AnyObject {
    /// Tag of every request the script makes, so a timeout can abort them.
    var tag: AnyObject { get }
    func call(_ name: String, _ argsJson: String) -> String
    /// Frees per-call state (parsed documents).
    func endCall()
}

/// QuickJS with ES modules. Thread-confined.
protocol JsEngine: AnyObject {
    func install(_ call: @escaping (String, String) -> String) throws
    func modules(normalize: @escaping (_ base: String, _ name: String) throws -> String, load: @escaping (_ name: String) throws -> String) throws
    /// Evaluates a global script; the completion value as a string (nil for undefined / null).
    func script(_ code: String, _ name: String) throws -> String?
    func module(_ code: String, _ name: String) throws
    /// Stops a running script from another thread.
    func interrupt()
    /// Forgets an interrupt that came too late for its call.
    func resume()
    func close()
}

extension JsEngine {
    func resume() {}
}

/// Embedded CPython. `key` names one spider's namespace.
protocol PyEngine: AnyObject {
    func load(key: String, source: String, ext: String, siteKey: String, url: String, host: ScriptHosting) throws
    func call(key: String, method: String, argsJson: String) throws -> String
    func unload(key: String)
    func interrupt(key: String)
}

/// JAR sites run on a paired Android device (`JAR 桥接`).
protocol JarHost: AnyObject {
    var paired: Bool { get }
    /// `host:port` of the paired device, "" without one.
    var address: String { get }
    func spider(site: TVBoxSite, jar: String) throws -> Spider
    /// 解析 types 2 (`jsonExt`) and 3 (`jsonExtMix`).
    func parse(jar: String, method: String, args: [Any]) throws -> String
}

extension JarHost {
    var address: String { "" }
}

// MARK: Sniffing

struct SniffRequest {
    var url: String
    var headers: [String: String] = [:]
    var scripts: [String] = []
    var rules: [TVBoxRule] = []
    var ads: [String] = []
    var allowPrivate = false
    var timeoutMs = 15_000
    /// Spider-side check (`manualVideoCheck` sites); nil = the built-in rule.
    var isVideo: ((String) async -> Bool)? = nil
}

struct SniffResult { let url: String; let headers: [String: String] }

/// Hidden browser that watches a page's requests for a media address.
protocol Sniffer: AnyObject { func sniff(_ r: SniffRequest) async throws -> SniffResult }

// MARK: Config pieces the seams mention

struct TVBoxSite: Hashable, Codable {
    static let defaultTimeoutMs = 15_000
    var key: String
    var name: String
    var type: Int
    var api: String
    /// Text handed to the spider: a plain string, or the compact JSON of an object / array.
    var ext = ""
    var jar = ""
    var playUrl = ""
    var click = ""
    var searchable = true
    var quickSearch = true
    var filterable = true
    var changeable = true
    var hide = false
    var timeoutMs = TVBoxSite.defaultTimeoutMs
    var headers: [String: String] = [:]
    /// Category names to keep, in this order (empty = everything the site returns).
    var categories: [String] = []
    var adult = false
    var kind: SiteKind { SiteKind.of(type: type, api: api) }
}

struct TVBoxRule: Hashable, Codable {
    var name: String
    var hosts: [String]
    var regex: [String]
    var exclude: [String]
    var script: [String]
    func matches(_ host: String) -> Bool {
        hosts.contains { raw in
            var h = raw.lowercased()
            if h == "*" || host == h { return true }
            if h.hasPrefix("*.") { h.removeFirst(2) } else if h.hasPrefix(".") { h.removeFirst() }
            return host.hasSuffix("." + h) || host.contains(raw.lowercased())
        }
    }
}

/// What only the app can provide. Runtimes that are nil are simply not part of this build.
struct TVBoxPlatform {
    var js: (() throws -> JsEngine)?
    var python: PyEngine?
    var jar: JarHost?
    var sniffer: Sniffer
    /// Bundled script assets (`bootstrap.js`, `lib/<name>`); nil when missing.
    var jsAsset: (String) -> String?
    var makeHost: (_ siteKey: String, _ http: TVBoxHttp, _ proxyPort: @escaping () -> Int) -> ScriptHosting
    var log: (String) -> Void = { _ in }
}
