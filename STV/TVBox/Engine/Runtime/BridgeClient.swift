import CryptoKit
import Foundation
import Security

/// What the settings page shows about the JAR bridge.
@MainActor
final class BridgeStatus: ObservableObject {
    enum State: Equatable {
        case unpaired
        /// Paired, not asked since the app started.
        case unknown
        case checking
        case online
        case offline(String)
    }

    @Published fileprivate(set) var address = ""
    @Published fileprivate(set) var state = State.unpaired
    @Published fileprivate(set) var lastSeen: Date?

    var paired: Bool { state != .unpaired }

    nonisolated init() {}

    var text: String {
        switch state {
        case .unpaired: return "未配对"
        case .unknown: return "已配对"
        case .checking: return "正在连接…"
        case .online: return "已连接"
        case .offline(let m): return m
        }
    }
}

/// JAR sites run on a paired Android device (docs/unified-player-tvbox.md §4 "JAR 桥接"). Requests are signed with the pairing
/// code, which never leaves this device; proxied media addresses come back rewritten and signed, ready to play.
final class BridgeClient: JarHost, @unchecked Sendable {
    static let shared = BridgeClient()
    static let defaultPort = 9979
    static let codeLength = 12

    /// Reply of the device: status and body. Tests put their own in.
    typealias Transport = (URLRequest, AnyObject?) throws -> (Int, Data)

    struct Store {
        var address: () -> String
        var setAddress: (String) -> Void
        var code: () -> String?
        var setCode: (String?) -> Void

        static let device = Store(
            address: { UserDefaults.standard.string(forKey: "tvbox.bridge.address") ?? "" },
            setAddress: { UserDefaults.standard.set($0, forKey: "tvbox.bridge.address") },
            code: Keychain.get, setCode: Keychain.set)
    }

    let status = BridgeStatus()
    private let store: Store
    private let now: () -> Date
    private let nonce: () -> String
    private let transport: Transport
    private let lock = NSLock()
    private var current: Pairing?

    private struct Pairing: Equatable { var address: String; var code: String }

    init(store: Store = .device, now: @escaping () -> Date = Date.init, nonce: @escaping () -> String = BridgeClient.newNonce, transport: Transport? = nil) {
        self.store = store
        self.now = now
        self.nonce = nonce
        self.transport = transport ?? BridgeHTTP().send
        if case let a = store.address(), !a.isEmpty, let c = store.code(), !c.isEmpty { current = Pairing(address: a, code: c) }
        if let a = current?.address { show(.unknown, address: a) }
    }

    private var pairing: Pairing? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    private func show(_ s: BridgeStatus.State, address: String? = nil) {
        let status = self.status, at = now()
        Task { @MainActor in
            if let address { status.address = address }
            if status.state != s { status.state = s }
            if s == .online { status.lastSeen = at }
        }
    }

    // MARK: Pairing

    /// Letters and digits only, upper case: the code is read off another screen and typed with blanks, dashes and whatever.
    static func normalizeCode(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        for u in raw.precomposedStringWithCompatibilityMapping.uppercased().unicodeScalars where (u >= "A" && u <= "Z") || (u >= "0" && u <= "9") { out.append(u) }
        return String(out)
    }

    /// `192.168.1.2`, `192.168.1.2:9979`, `http://192.168.1.2:9979/` → `192.168.1.2:9979`; only addresses of a local network.
    static func normalizeAddress(_ raw: String) throws -> String {
        var t = raw.precomposedStringWithCompatibilityMapping.trimmed.lowercased().replacingOccurrences(of: "。", with: ".")
        if let r = t.range(of: "://") { t = String(t[r.upperBound...]) }
        t = String(t.prefix { $0 != "/" && !$0.isWhitespace })
        let colon = t.lastIndex(of: ":")
        let host = String(colon.map { t[..<$0] } ?? t[...])
        let port = colon.map { String(t[t.index(after: $0)...]) } ?? String(defaultPort)
        guard !host.isEmpty, !host.contains(":"), let p = Int(port), (1...65535).contains(p) else { throw TVBoxError("桥接地址无效，应类似 192.168.1.2:\(defaultPort)") }
        let local = NetGuard.isIPLiteral(host) ? NetGuard.isBlockedIP(host) : host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") || !host.contains(".")
        guard local, host.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d || $0 == 0x2e || $0 == 0x5f }) else { throw TVBoxError("桥接只支持局域网地址") }
        return "\(host):\(p)"
    }

    /// Asks the device before anything is stored.
    func pair(address: String, code: String) async throws {
        let a = try Self.normalizeAddress(address), c = Self.normalizeCode(code)
        guard c.count == Self.codeLength else { throw TVBoxError("配对码是 \(Self.codeLength) 位字母和数字") }
        let p = Pairing(address: a, code: c), before = pairing
        show(.checking, address: a)
        do { try await onThread { try self.ping(p) } } catch {
            if before == nil { show(.unpaired, address: "") } else { show(.unknown, address: before?.address) }
            throw error
        }
        lock.lock(); current = p; lock.unlock()
        store.setAddress(a)
        store.setCode(c)
        show(.online, address: a)
    }

    func unpair() {
        lock.lock(); current = nil; lock.unlock()
        store.setAddress("")
        store.setCode(nil)
        show(.unpaired, address: "")
    }

    /// Updates `status`; never throws.
    func refresh() async {
        guard let p = pairing else { return show(.unpaired, address: "") }
        show(.checking)
        try? await onThread { try self.ping(p) }
    }

    private func onThread(_ body: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try body(); c.resume() } catch { c.resume(throwing: error) }
            }
        }
    }

    private func ping(_ p: Pairing) throws { _ = try request(p, "/bridge/ping", Data(), 8, nil) }

    // MARK: Requests

    static func newNonce() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    static func hmac(_ code: String, _ text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data(code.utf8))))
    }

    /// hex HMAC-SHA256(code, time \n nonce \n hex sha256(body))
    static func sign(code: String, time: String, nonce: String, body: Data) -> String {
        HostCrypto.hex(hmac(code, "\(time)\n\(nonce)\n" + HostCrypto.hex(SHA256.hash(data: body))))
    }

    private func request(_ p: Pairing, _ path: String, _ body: Data, _ timeout: TimeInterval, _ tag: AnyObject?) throws -> String {
        guard let url = URL(string: "http://\(p.address)\(path)") else { throw TVBoxError("桥接地址无效") }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let time = String(Int(now().timeIntervalSince1970)), n = nonce()
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.setValue(time, forHTTPHeaderField: "X-Idj-Time")
        r.setValue(n, forHTTPHeaderField: "X-Idj-Nonce")
        r.setValue(Self.sign(code: p.code, time: time, nonce: n, body: body), forHTTPHeaderField: "X-Idj-Sign")
        do {
            let (code, data) = try transport(r, tag)
            let o = RT.object(String(decoding: data, as: UTF8.self))
            if code == 200, let v = o?["v"], !(v is NSNull) {
                show(.online)
                return (v as? String) ?? RT.json(v)
            }
            // an answer that only concerns this call says nothing about the connection
            let e = Self.failure(code, (o?["e"] as? String) ?? "", json: o != nil)
            if o == nil || code == 401 || code == 429 { show(.offline(e.message)) } else { show(.online) }
            throw e
        } catch let e as URLError {
            if e.code == .cancelled { throw SpiderTimeout("桥接请求被中断") }
            let m = Self.network(e, p.address)
            show(.offline(m))
            throw TVBoxError(m)
        }
    }

    static func failure(_ code: Int, _ message: String, json: Bool) -> TVBoxError {
        guard json else { return TVBoxError("桥接地址上没有 i短剧（HTTP \(code)）") }
        switch code {
        case 401 where message.contains("时间"): return TVBoxError("两台设备的时间相差超过 60 秒，请在两台设备的系统设置里打开「自动设置时间」")
        case 401: return TVBoxError(message.isEmpty || message.contains("配对码") ? "配对码不正确，请重新配对" : "桥接验证失败：\(message)")
        case 403: return TVBoxError("桥接设备拒绝了请求：\(message.isEmpty ? "没有导入或信任这份配置" : message)")
        case 404, 405: return TVBoxError("桥接设备的版本不匹配（\(message.isEmpty ? "HTTP \(code)" : message)）")
        case 429: return TVBoxError("配对码错误次数过多，请一分钟后再试")
        case 502: return TVBoxError(message.isEmpty ? "桥接设备执行 JAR 失败" : "桥接：\(message)")
        case 200: return TVBoxError("桥接设备没有返回结果")
        default: return TVBoxError("桥接出错：\(message.isEmpty ? "HTTP \(code)" : message)")
        }
    }

    private static func network(_ e: URLError, _ address: String) -> String {
        switch e.code {
        case .timedOut: return "桥接设备没有响应（\(address)）"
        case .notConnectedToInternet, .dataNotAllowed: return "连不上桥接设备：请检查 Wi-Fi，以及系统设置里 i短剧 的「本地网络」权限"
        default: return "连不上桥接设备 \(address)：请确认两台设备在同一局域网，且对方已开启局域网桥接"
        }
    }

    // MARK: JarHost

    var paired: Bool { pairing != nil }
    var address: String { pairing?.address ?? "" }

    func spider(site: TVBoxSite, jar: String) throws -> Spider {
        guard paired else { throw TVBoxError("JAR 站点需要桥接：请先在设置里配对一台安卓设备") }
        return BridgeSpider(self, site, jar)
    }

    /// `jsonExt` [key, jxs, url] / `jsonExtMix` [key, name, flag, jxs, url]; the parser's JSON text.
    func parse(jar: String, method: String, args: [Any]) throws -> String {
        try call(siteKey: "", api: "", ext: "", jar: jar, method: method, args: args, timeout: 30, tag: nil)
    }

    func call(siteKey: String, api: String, ext: String, jar: String, method: String, args: [Any], timeout: TimeInterval = 60, tag: AnyObject?) throws -> String {
        guard let p = pairing else { throw TVBoxError("还没有配对桥接设备") }
        let body = Data(RT.json(["siteKey": siteKey, "api": api, "ext": ext, "jar": jar, "method": method, "args": args.map(JSONObject.unwrap)] as [String: Any]).utf8)
        return try request(p, "/bridge/call", body, timeout, tag)
    }

    /// One JAR site; the spider itself lives on the paired device.
    private final class BridgeSpider: Spider {
        private let client: BridgeClient
        private let site: TVBoxSite
        private let jar: String
        private final class Tag {}
        private let tag = Tag()

        init(_ client: BridgeClient, _ site: TVBoxSite, _ jar: String) {
            self.client = client
            self.site = site
            self.jar = jar
        }

        private func run(_ method: String, _ args: [Any]) throws -> String {
            try client.call(siteKey: site.key, api: site.api, ext: site.ext, jar: jar, method: method, args: args, tag: tag)
        }

        func homeContent(filter: Bool) throws -> String { try run("homeContent", [filter]) }
        func homeVideoContent() throws -> String { try run("homeVideoContent", []) }
        func categoryContent(tid: String, pg: String, filter: Bool, extend: [String: String]) throws -> String { try run("categoryContent", [tid, pg, filter, extend]) }
        func detailContent(ids: [String]) throws -> String { try run("detailContent", [ids]) }
        func searchContent(key: String, quick: Bool, pg: String) throws -> String { try run("searchContent", [key, quick, pg]) }
        func playerContent(flag: String, id: String, vipFlags: [String]) throws -> String { try run("playerContent", [flag, id, vipFlags]) }
        func liveContent(url: String) throws -> String { try run("liveContent", [url]) }
        func action(_ action: String) throws -> String { try run("action", [action]) }
        func isVideoFormat(_ url: String) throws -> Bool { try run("isVideoFormat", [url]) == "true" }
        func manualVideoCheck() throws -> Bool { try run("manualVideoCheck", []) == "true" }
        func interrupt() { BridgeHTTP.cancel(tag) }
    }

    private enum Keychain {
        private static let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "stv.tvbox.bridge", kSecAttrAccount: "code"]

        static func get() -> String? {
            var q = base
            q[kSecReturnData] = true
            q[kSecMatchLimit] = kSecMatchLimitOne
            var r: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
            return String(decoding: d, as: UTF8.self)
        }

        static func set(_ v: String?) {
            SecItemDelete(base as CFDictionary)
            guard let v, !v.isEmpty else { return }
            var add = base
            add[kSecValueData] = Data(v.utf8)
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Blocking requests to the paired device, cancellable by tag. Redirects are refused: a signature is for one address.
private final class BridgeHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [Int: (tag: AnyObject, task: URLSessionTask)] = [:]
    nonisolated(unsafe) private static var serial = 0

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 8
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForResource = 90
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    static func cancel(_ tag: AnyObject) {
        lock.lock()
        let mine = running.values.filter { $0.tag === tag }.map(\.task)
        lock.unlock()
        mine.forEach { $0.cancel() }
    }

    func send(_ r: URLRequest, _ tag: AnyObject?) throws -> (Int, Data) {
        final class Box: @unchecked Sendable { var d: Data?; var r: URLResponse?; var e: Error? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let session = Self.lock.withLock { self.session }
        let task = session.dataTask(with: r) { d, resp, e in
            box.d = d; box.r = resp; box.e = e
            done.signal()
        }
        let id: Int = Self.lock.withLock {
            Self.serial += 1
            if let tag { Self.running[Self.serial] = (tag, task) }
            return Self.serial
        }
        task.resume()
        done.wait()
        Self.lock.withLock { Self.running[id] = nil }
        if let e = box.e { throw e }
        guard let h = box.r as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (h.statusCode, box.d ?? Data())
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
