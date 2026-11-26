import Foundation

/// Downloaded scripts on disk. A stored copy is used at once; an aged one is refreshed behind the caller's back, for the next
/// time the site is opened.
final class ScriptCache {
    private let dir: URL
    private let freshMs: Int
    private let lock = NSLock()
    private var refreshing = Set<String>()
    /// Moves on with every `clear`: what was requested before is not stored afterwards.
    private var generation = 0

    init(_ dir: URL, freshMs: Int = 30 * 60_000) { self.dir = dir; self.freshMs = freshMs }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private func file(_ url: String) -> URL { dir.appendingPathComponent(Bytes.hex(Bytes.md5(url))) }

    func load(_ url: String, http: TVBoxHttp, headers: [String: String] = [:], tag: AnyObject? = nil) throws -> String {
        if TVBoxUrl.isLocal(url) { return TVBoxDecoder.text([UInt8](try http.execute(NetRequest(url: url, tag: tag)).body)) }
        let f = file(url)
        if let at = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date, let d = try? Data(contentsOf: f) {
            if Date().timeIntervalSince(at) * 1000 >= Double(freshMs) { refresh(url, http, headers) }
            return String(decoding: d, as: UTF8.self)
        }
        let turn = locked { generation }
        let text = try http.text(url, headers: headers, timeoutMs: 20_000, tag: tag)
        if Self.isPage(text) { throw TVBoxIOError("脚本地址返回的是网页：\(TVBoxUrl.fileName(url))") }
        store(text, f, turn)
        return text
    }

    private static func isPage(_ text: String) -> Bool {
        let head = text.withoutBOM
        return head.hasPrefixIgnoringCase("<!doctype") || head.hasPrefixIgnoringCase("<html")
    }

    private func store(_ text: String, _ f: URL, _ turn: Int) {
        locked {
            guard turn == generation else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: f, options: .atomic)
        }
    }

    /// One at a time per address. The date moves on first: an unreachable host is not asked again on every open.
    private func refresh(_ url: String, _ http: TVBoxHttp, _ headers: [String: String]) {
        let f = file(url)
        let turn = locked { () -> Int? in
            guard refreshing.insert(url).inserted else { return nil }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
            return generation
        }
        guard let turn else { return }
        Task.detached(priority: .utility) { [self] in
            if let r = try? await http.fetch(NetRequest(url: url, headers: headers, timeoutMs: 20_000)), r.ok {
                let text = r.text()
                if !text.trimmed.isEmpty, !Self.isPage(text) { store(text, f, turn) }
            }
            locked { _ = refreshing.remove(url) }
        }
    }

    func clear() {
        locked {
            generation += 1
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: f) }
        }
    }
}

/// ES-module loader of HOST_ABI.md: `assets://js/lib/…`, bare library names, http(s), relative to the importing module.
/// Confined to the script's thread.
final class JsModules {
    static let lib = "assets://js/lib/"
    static let entryName = "idj-entry.js"
    private static let spiderID = TVBoxRegex("(?<![\\w.$])(?:globalThis\\.)?__JS_SPIDER__")

    private let asset: (String) -> String?
    private let http: TVBoxHttp
    private let cache: ScriptCache
    private let entry: String
    private let tag: AnyObject
    private var libs: [String: String?] = [:]

    init(asset: @escaping (String) -> String?, http: TVBoxHttp, cache: ScriptCache, entry: String, tag: AnyObject) {
        self.asset = asset
        self.http = http
        self.cache = cache
        self.entry = entry
        self.tag = tag
    }

    private func library(_ name: String) -> String? {
        if let known = libs[name] { return known }
        let text = asset(name)
        libs.updateValue(text, forKey: name)
        return text
    }

    func normalize(_ base: String, _ name: String) -> String {
        if name == Self.entryName || name.hasPrefix(Self.lib) { return name }
        if name.hasPrefix("assets://") { return Self.lib + name.substringAfterLast("/") }
        if TVBoxUrl.isHttp(name) || TVBoxUrl.isLocal(name) { return name }
        if !name.hasPrefix("."), !name.hasPrefix("/"), library(name) != nil { return Self.lib + name }
        if base.hasPrefix(Self.lib) {
            var n = name
            if n.hasPrefix("./") { n.removeFirst(2) }
            if n.hasPrefix("/") { n.removeFirst() }
            return Self.lib + n
        }
        return TVBoxUrl.join(base.isEmpty || base == Self.entryName ? entry : base, name)
    }

    func load(_ name: String) throws -> String {
        if name.hasPrefix(Self.lib) {
            let n = String(name.dropFirst(Self.lib.count))
            guard let text = library(n) else { throw TVBoxIOError("内置脚本库里没有 \(n)") }
            return text
        }
        let text: String
        do { text = try cache.load(name, http: http, tag: tag) } catch {
            // a repository that forgot one of the well-known helper files still works with the bundled one
            guard let known = library(TVBoxUrl.decode(TVBoxUrl.fileName(name))) else { throw TVBoxIOError("无法下载脚本 \(TVBoxUrl.fileName(name))：\(SpiderErrors.text(error))") }
            text = known
        }
        if text.hasPrefix("//bb") { throw TVBoxIOError("\(TVBoxUrl.fileName(name)) 是 QuickJS 字节码（//bb），本机引擎无法加载") }
        return name == entry ? Self.spiderID.replace(text) { _ in "globalThis.__JS_SPIDER__" } : text
    }
}

/// drpy / CatVod JavaScript spider driven through shared/tvbox/js/bootstrap.js.
final class JsSpider: Spider {
    private let site: TVBoxSite
    private let engineFactory: () throws -> JsEngine
    private let host: ScriptHosting
    private let modules: JsModules
    private let bootstrap: String
    /// Aborts the script's requests (set by the engine).
    var onInterrupt: () -> Void = {}

    private let lock = NSLock()
    private var engineRef: JsEngine?
    private var stopped = false

    init(site: TVBoxSite, engineFactory: @escaping () throws -> JsEngine, host: ScriptHosting, modules: JsModules, bootstrap: String) {
        self.site = site
        self.engineFactory = engineFactory
        self.host = host
        self.modules = modules
        self.bootstrap = bootstrap
    }

    private final class Failure { var text: String? }

    private var engine: JsEngine? {
        get { lock.lock(); defer { lock.unlock() }; return engineRef }
        set { lock.lock(); engineRef = newValue; lock.unlock() }
    }

    func start(ext: String) throws {
        let js = try engineFactory()
        engine = js
        defer { host.endCall() }
        do {
            let failure = Failure()
            try js.install { [host] name, args in host.call(name, args) }
            try js.modules(normalize: { [modules] base, name in modules.normalize(base, name) }, load: { [modules] name in
                do { return try modules.load(name) } catch { failure.text = SpiderErrors.text(error); throw error }
            })
            _ = try js.script(bootstrap, "bootstrap.js")
            let api = JSONObject.quote(site.api)
            do { try js.module("import * as m from \(api); __idj.attach(m);", JsModules.entryName) } catch {
                throw TVBoxError("脚本加载失败：" + (failure.text ?? SpiderErrors.text(error)))
            }
            var status = try state(js, "__idj.status()", "status.js")
            if !J.bool(status["ok"]), status.string("e").isEmpty {
                _ = try? js.script("import(\(api)).then(function (m) { __idj.attach(m); }).catch(__idj.fail)", "retry.js")
                status = try state(js, "__idj.status()", "status.js")
            }
            if !J.bool(status["ok"]) { throw TVBoxError("脚本加载失败：" + (failure.text ?? status.string("e").nonEmptyOr("模块执行出错"))) }
            _ = try run("init", [ext, site.key, site.type])
        } catch {
            engine = nil
            js.close()
            throw error
        }
    }

    private func state(_ js: JsEngine, _ code: String, _ name: String) throws -> JSONObject {
        let text = try js.script(code, name) ?? ""
        return LenientJson.objectOrNull(text) ?? JSONObject()
    }

    private var isStopped: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stopped }
        set { lock.lock(); stopped = newValue; lock.unlock() }
    }

    private func run(_ method: String, _ args: [Any]) throws -> String {
        guard let js = engine else { throw SpiderStopped("「\(site.name)」已停止") }
        isStopped = false
        defer { host.endCall() }
        _ = try js.script("__idj.start(\(JSONObject.quote(method)),\(literal(JSONObject.text(args))))", "call.js")
        while true {
            let s = try state(js, "__idj.poll()", "poll.js")
            if J.bool(s["done"]) {
                if s.has("e") { throw TVBoxError(s.string("e").nonEmptyOr("脚本出错")) }
                return s["v"] as? String ?? ""
            }
            if isStopped { throw SpiderTimeout("「\(site.name)」请求被中断") }
            let wait = J.int(s["wait"])
            if wait > 0 { Thread.sleep(forTimeInterval: Double(min(wait, 100)) / 1000) }
        }
    }

    /// JSON text is a valid JS string literal once line separators are escaped.
    private func literal(_ s: String) -> String {
        JSONObject.quote(s).replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    func homeContent(filter: Bool) throws -> String { try run("homeContent", [filter]) }
    func homeVideoContent() throws -> String { try run("homeVideoContent", []) }
    func categoryContent(tid: String, pg: String, filter: Bool, extend: [String: String]) throws -> String { try run("categoryContent", [tid, pg, filter, extend]) }
    func detailContent(ids: [String]) throws -> String { try run("detailContent", [ids]) }
    func searchContent(key: String, quick: Bool, pg: String) throws -> String { try run("searchContent", [key, quick, pg]) }
    func playerContent(flag: String, id: String, vipFlags: [String]) throws -> String { try run("playerContent", [flag, id, vipFlags]) }
    func liveContent(url: String) throws -> String { try run("liveContent", [url]) }
    func proxyLocal(_ params: [String: String]) throws -> ProxyReply? { ProxyReply.fromRunner(try run("proxyLocal", [params])) }
    func action(_ action: String) throws -> String { try run("action", [action]) }
    func isVideoFormat(_ url: String) throws -> Bool { try run("isVideoFormat", [url]) == "true" }
    func manualVideoCheck() throws -> Bool { try run("manualVideoCheck", []) == "true" }

    func interrupt() {
        isStopped = true
        engine?.interrupt()
        onInterrupt()
    }

    func resume() { engine?.resume() }

    func destroy() {
        guard let js = engine else { return }
        _ = try? run("destroy", [])
        engine = nil
        js.close()
    }
}

/// Embedded Python behind shared/tvbox/py/idj_runner.py.
final class PySpider: Spider {
    /// Namespace of this instance: a predecessor that unloads late must not take it along.
    private let key: String
    private let site: TVBoxSite
    private let engine: PyEngine
    private let host: ScriptHosting
    private let source: () throws -> String
    private let url: String
    /// Aborts the script's requests (set by the engine).
    var onInterrupt: () -> Void = {}

    init(uid: String, site: TVBoxSite, engine: PyEngine, host: ScriptHosting, source: @escaping () throws -> String, url: String) {
        key = "\(uid)#\(UUID().uuidString.prefix(8))"
        self.site = site
        self.engine = engine
        self.host = host
        self.source = source
        self.url = url
    }

    func start(ext: String) throws {
        defer { host.endCall() }
        try engine.load(key: key, source: try source(), ext: ext, siteKey: site.key, url: url, host: host)
    }

    private func run(_ method: String, _ args: [Any]) throws -> String {
        defer { host.endCall() }
        return try engine.call(key: key, method: method, argsJson: JSONObject.text(args))
    }

    func homeContent(filter: Bool) throws -> String { try run("homeContent", [filter]) }
    func homeVideoContent() throws -> String { try run("homeVideoContent", []) }
    func categoryContent(tid: String, pg: String, filter: Bool, extend: [String: String]) throws -> String { try run("categoryContent", [tid, pg, filter, extend]) }
    func detailContent(ids: [String]) throws -> String { try run("detailContent", [ids]) }
    func searchContent(key: String, quick: Bool, pg: String) throws -> String { try run("searchContent", [key, quick, pg]) }
    func playerContent(flag: String, id: String, vipFlags: [String]) throws -> String { try run("playerContent", [flag, id, vipFlags]) }
    func liveContent(url: String) throws -> String { try run("liveContent", [url]) }
    func proxyLocal(_ params: [String: String]) throws -> ProxyReply? { ProxyReply.fromRunner(try run("proxyLocal", [params])) }
    func action(_ action: String) throws -> String { try run("action", [action]) }
    func isVideoFormat(_ url: String) throws -> Bool { try run("isVideoFormat", [url]) == "true" }
    func manualVideoCheck() throws -> Bool { try run("manualVideoCheck", []) == "true" }

    func interrupt() {
        engine.interrupt(key: key)
        onInterrupt()
    }

    func destroy() { engine.unload(key: key) }

    /// `py_xxx` sites carry the script address in `ext`; otherwise `api` is the script and `ext` its parameter.
    static func script(_ api: String, _ ext: String) throws -> (url: String, ext: String) {
        guard api.hasPrefix("py_"), !api.contains("/") else { return (api, ext) }
        guard ext.contains(".py") else { throw ProviderError.invalid("\(api) 没有给出脚本地址（ext）") }
        return (ext, "")
    }
}
