import Foundation

/// The native half of `shared/tvbox/HOST_ABI.md`, one instance per script spider. Python scripts may call it from several
/// threads at once.
final class ScriptHost: ScriptHosting {
    private final class Tag {}

    let tag: AnyObject = Tag()
    private let siteKey: String
    private let http: TVBoxHttp
    private let storage: ScriptStorage
    private let proxyPort: () -> Int
    private let log: (String) -> Void

    // html documents live until the spider call returns
    private let lock = NSRecursiveLock()
    private var nodes: [HtmlNode] = []
    private var ids: [HtmlNode: Int] = [:]
    /// Recently parsed pages of the pdf* calls, newest last.
    private var docs: [(html: String, node: HtmlNode)] = []
    private static let maxNodes = 300_000

    init(siteKey: String, http: TVBoxHttp, storage: ScriptStorage, proxyPort: @escaping () -> Int, log: @escaping (String) -> Void = { _ in }) {
        self.siteKey = siteKey
        self.http = http
        self.storage = storage
        self.proxyPort = proxyPort
        self.log = log
    }

    func endCall() {
        lock.lock(); defer { lock.unlock() }
        nodes = []; ids = [:]; docs = []
    }

    func call(_ name: String, _ argsJson: String) -> String {
        autoreleasepool {
            do {
                let blank = argsJson.allSatisfy(\.isWhitespace)
                guard let a = blank ? [:] : RT.object(argsJson) else { throw TVBoxError("宿主参数不是 JSON 对象") }
                switch try dispatch(name, a) {
                case nil: return "{\"v\":null}"
                case let s as String: return "{\"v\":" + RT.quote(s) + "}"
                case let raw as RawJSON: return "{\"v\":" + raw.text + "}"
                case let v?: return RT.json(["v": v])
                }
            } catch {
                return "{\"e\":" + RT.quote(SpiderErrors.text(error)) + "}"
            }
        }
    }

    private struct RawJSON { let text: String }

    private func dispatch(_ name: String, _ a: [String: Any]) throws -> Any? {
        func s(_ k: String) -> String { Self.string(a[k]) }
        func bytes(_ k: String) -> Data { RT.base64(s(k)) }
        func given(_ k: String) -> Bool { a[k] != nil && !(a[k] is NSNull) }
        func ns() -> String { s("ns").isEmpty ? siteKey : s("ns") }
        switch name {
        case "http": return try request(a)
        case "html.load", "html.select", "html.text", "html.html", "html.outer", "html.attr", "html.rel", "html.xpath", "pdfh", "pd", "pdfa", "pdfl":
            lock.lock(); defer { lock.unlock() }
            return try html(name, a)
        case "joinUrl": return TVBoxUrl.join(s("base"), s("ref"))
        case "local.get": return storage.get(ns(), s("k"))
        case "local.set": storage.set(ns(), s("k"), s("v")); return nil
        case "local.delete": storage.delete(ns(), s("k")); return nil
        case "hash": return HostCrypto.hex(try HostCrypto.hash(s("alg"), bytes("b64"), key: given("hmacB64") ? bytes("hmacB64") : nil))
        case "cipher":
            return try HostCrypto.cipher(s("alg"), s("mode"), s("pad"), encrypt: J.bool(a["encrypt"]), key: bytes("keyB64"), iv: s("ivB64").isEmpty ? nil : bytes("ivB64"), data: bytes("dataB64")).base64EncodedString()
        case "rsa":
            switch s("op") {
            case "sign": return try HostCrypto.rsaSign(key: s("key"), hash: s("hash"), data: bytes("dataB64")).base64EncodedString()
            case "verify": return try HostCrypto.rsaVerify(key: s("key"), hash: s("hash"), data: bytes("dataB64"), signature: bytes("sigB64"))
            default: return try HostCrypto.rsa(encrypt: s("op") != "decrypt", key: s("key"), public: J.bool(a["public"]), pad: s("pad"), data: bytes("dataB64")).base64EncodedString()
            }
        case "gbk": return s("op") == "encode" ? RT.gbkEncode(s("s")).base64EncodedString() : RT.gbkDecode(bytes("b64"))
        case "inflate": return try HostCrypto.inflate(bytes("b64"), s("kind")).base64EncodedString()
        case "json5": return RawJSON(text: JSONObject.text(try LenientJson.parse(s("s"))))
        case "s2t": return s("s").applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? s("s")
        case "t2s": return s("s").applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s("s")
        case "proxyUrl":
            return "http://127.0.0.1:\(proxyPort())/proxy?do=\(s("kind").isEmpty ? "js" : s("kind"))&siteKey=" + GoURL.queryEscape(s("siteKey").isEmpty ? siteKey : s("siteKey"))
        case "log": log(s("m")); return nil
        default: throw TVBoxError("未知的宿主接口 \(name)")
        }
    }

    /// Unlike `J.str` this keeps the words "null" and "<nil>": scripts store and encrypt them.
    private static func string(_ v: Any?) -> String { (v as? String) ?? J.str(v) }

    // MARK: http

    private func request(_ a: [String: Any]) throws -> Any {
        var r = NetRequest(url: Self.string(a["url"]))
        let method = Self.string(a["method"])
        r.method = method.isEmpty ? "GET" : method
        r.headers = J.dict(a["headers"]).mapValues { Self.string($0) }
        if case let b = Self.string(a["bodyB64"]), !b.isEmpty { r.body = RT.base64(b) } else if let b = a["body"], !(b is NSNull) { r.body = Data(Self.string(b).utf8) }
        let t = J.int(a["timeout"])
        r.timeoutMs = t <= 0 ? 10_000 : min(max(t, 1_000), 60_000)
        r.redirect = a["redirect"] == nil || J.bool(a["redirect"])
        r.verify = a["verify"] == nil || J.bool(a["verify"])
        r.tag = tag
        let x = try http.execute(r)
        let charset = Self.string(a["charset"])
        let body = Self.string(a["out"]) == "b64" ? x.body.base64EncodedString() : x.text(charset.isEmpty ? nil : charset)
        return ["code": x.code, "url": x.url, "headers": x.headers, "body": body] as [String: Any]
    }

    // MARK: html

    private func id(_ n: HtmlNode) throws -> Int {
        if let i = ids[n] { return i }
        guard nodes.count < Self.maxNodes else { throw TVBoxError("节点太多") }
        nodes.append(n)
        ids[n] = nodes.count
        return nodes.count
    }

    private func node(_ v: Any?) -> HtmlNode? {
        let i = J.int(v)
        return i >= 1 && i <= nodes.count ? nodes[i - 1] : nil
    }

    private func page(_ html: String) -> HtmlNode {
        if let i = docs.firstIndex(where: { $0.html == html }) {
            let d = docs.remove(at: i)
            docs.append(d)
            return d.node
        }
        let n = HtmlDoc(html).node
        if docs.count >= 6 { docs.removeFirst() }
        docs.append((html, n))
        return n
    }

    private func html(_ name: String, _ a: [String: Any]) throws -> Any? {
        func s(_ k: String) -> String { Self.string(a[k]) }
        let n = node(a["id"])
        switch name {
        case "html.load": return try id(HtmlDoc(s("html")).node)
        case "html.select": return try HtmlQuery.select(J.arr(a["ids"]).compactMap { node($0) }, s("css")).map(id)
        case "html.text": return n?.text ?? ""
        case "html.html": return n?.html ?? ""
        case "html.outer": return n?.outerHtml ?? ""
        case "html.attr": return n?.attr(s("k"))
        case "html.rel":
            guard let n else { return [Int]() }
            switch s("op") {
            case "parent": return try [n.parent].compactMap { $0 }.map(id)
            case "children": return try n.children.map(id)
            case "next": return try [n.next].compactMap { $0 }.map(id)
            case "prev": return try [n.previous].compactMap { $0 }.map(id)
            case "siblings": return try n.siblings.map(id)
            default: return [Int]()
            }
        case "html.xpath":
            guard let n else { return [Int]() }
            return try HtmlQuery.xpath(n, s("q")).map { hit -> [String: Any] in
                switch hit { case .node(let x): return ["n": try id(x)]; case .text(let t): return ["s": t] }
            }
        case "pdfh": return PdfRule.one(page(s("html")), s("rule"))
        case "pd": return PdfRule.one(page(s("html")), s("rule"), s("base"))
        case "pdfa": return PdfRule.list(page(s("html")), s("rule"))
        default: return PdfRule.pairs(page(s("html")), s("rule"), s("list"), s("url"), s("base"))
        }
    }
}

/// Values scripts persist (`local.*`): one JSON file per namespace (= site), written off the caller's thread, capped.
final class FileScriptStorage: ScriptStorage {
    static let maxValue = 512 << 10
    static let maxSite = 4 << 20

    private final class Site {
        var values: [String: String]
        var bytes: Int
        var dirty = false
        var used = Date()
        init(_ v: [String: String]) {
            values = v
            bytes = v.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        }
    }

    private let dir: URL
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "tvbox.storage", qos: .utility)
    private var sites: [String: Site] = [:]

    init(dir: URL) { self.dir = dir }

    private func file(_ ns: String) -> URL { dir.appendingPathComponent(Bytes.hex(Bytes.md5(ns)) + ".json") }

    /// `lock` is held.
    private func site(_ ns: String) -> Site {
        if let s = sites[ns] { s.used = Date(); return s }
        let saved = (try? Data(contentsOf: file(ns))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        if sites.count >= 64, let old = sites.filter({ !$0.value.dirty }).min(by: { $0.value.used < $1.value.used })?.key { sites[old] = nil }
        let s = Site(saved)
        sites[ns] = s
        return s
    }

    func get(_ ns: String, _ k: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return site(ns).values[k]
    }

    func set(_ ns: String, _ k: String, _ v: String) {
        guard v.utf8.count <= Self.maxValue, k.utf8.count <= 4096 else { return }
        lock.lock(); defer { lock.unlock() }
        let s = site(ns)
        if s.values[k] == v { return }
        let grown = s.bytes + v.utf8.count + (s.values[k].map { -$0.utf8.count } ?? k.utf8.count)
        guard grown <= Self.maxSite else { return }
        s.values[k] = v
        s.bytes = grown
        save(ns, s)
    }

    func delete(_ ns: String, _ k: String) {
        lock.lock(); defer { lock.unlock() }
        let s = site(ns)
        guard let old = s.values.removeValue(forKey: k) else { return }
        s.bytes -= k.utf8.count + old.utf8.count
        save(ns, s)
    }

    /// `lock` is held. Bursts of writes become one file write.
    private func save(_ ns: String, _ s: Site) {
        guard !s.dirty else { return }
        s.dirty = true
        queue.asyncAfter(deadline: .now() + 0.3) { [self] in write(ns, s) }
    }

    private func write(_ ns: String, _ s: Site) {
        lock.lock()
        let values = s.values
        let dirty = s.dirty
        s.dirty = false
        lock.unlock()
        guard dirty else { return }
        let f = file(ns)
        if values.isEmpty { try? FileManager.default.removeItem(at: f); return }
        guard let d = try? JSONSerialization.data(withJSONObject: values) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Writes what is still pending (tests, going to the background).
    func flush() {
        lock.lock()
        let pending = sites.filter { $0.value.dirty }
        lock.unlock()
        queue.sync { for (ns, s) in pending { write(ns, s) } }
    }
}
