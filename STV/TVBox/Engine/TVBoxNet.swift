import Foundation
import Network
import Security

/// Address policy + rewrites of one config: hosts, extra headers, private-network permission.
struct NetRules: Equatable {
    var hosts: [String: String] = [:]
    var headers: [TVBoxHeaderRule] = []
    /// Private ranges are reachable only when the config itself lives there or the user allowed LAN access.
    var allowPrivate = false
}

/// Threads for the few blocking jobs (DNS guard, canned or blocking HTTP seams): own pool, so GCD is never starved.
enum TVBoxWorkers {
    private static let cond = NSCondition()
    private static var jobs: [() -> Void] = []
    private static var threads = 0
    private static var idle = 0
    private static let limit = 16

    static func run(_ job: @escaping () -> Void) {
        cond.lock()
        jobs.append(job)
        if idle < jobs.count, threads < limit {
            threads += 1
            let t = Thread { loop() }
            t.name = "tvbox-worker"
            t.qualityOfService = .userInitiated
            t.start()
        }
        cond.signal()
        cond.unlock()
    }

    private static func loop() {
        while true {
            cond.lock()
            idle += 1
            let until = Date().addingTimeInterval(20)
            while jobs.isEmpty && cond.wait(until: until) {}
            idle -= 1
            if jobs.isEmpty { threads -= 1; cond.unlock(); return }
            let job = jobs.removeFirst()
            cond.unlock()
            autoreleasepool { job() }
        }
    }
}

extension TVBoxHttp {
    /// `execute` off the caller's thread; cancelling the task aborts the request at once.
    func fetch(_ r: NetRequest) async throws -> NetResponse {
        if let scope = self as? TVBoxNet.Scope { return try await scope.fetchNative(r) }
        var req = r
        let tag = r.tag ?? NSObject()
        req.tag = tag
        let request = req
        let once = TVBoxOnce<NetResponse>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NetResponse, Error>) in
                once.deliver { cont.resume(with: $0) }
                TVBoxWorkers.run {
                    if once.resolved { return }
                    once.resolve(Result { try self.execute(request) })
                }
            }
        } onCancel: {
            self.cancel(tag)
            once.resolve(.failure(CancellationError()))
        }
    }
}

/// A result delivered exactly once, whichever comes first: the value or its consumer.
final class TVBoxOnce<T> {
    private let lock = NSLock()
    private var pending: Result<T, Error>?
    private var done = false
    private var sink: ((Result<T, Error>) -> Void)?

    var resolved: Bool { lock.lock(); defer { lock.unlock() }; return done }

    func deliver(_ f: @escaping (Result<T, Error>) -> Void) {
        lock.lock()
        let early = pending
        pending = nil
        if early == nil { sink = f }
        lock.unlock()
        if let early { f(early) }
    }

    @discardableResult
    func resolve(_ r: Result<T, Error>) -> Bool {
        lock.lock()
        if done { lock.unlock(); return false }
        done = true
        let f = sink
        sink = nil
        if f == nil { pending = r }
        lock.unlock()
        f?(r)
        return true
    }
}

/// The one URLSession stack behind every TVBox request (configs, CMS, scripts, live lists, parses): shared connection pool,
/// HTTP/2, manual redirects so each hop is checked before it is opened.
final class TVBoxNet {
    /// Many config hosts answer browsers with a landing page.
    static let userAgent = "okhttp/4.12.0"
    private static let redirects: Set<Int> = [301, 302, 303, 307, 308]

    private let localDir: URL?
    private let ownPort: () -> Int
    private let protocolClasses: [AnyClass]
    private let hub = Hub()
    private let trustingHub = Hub(trusting: true)
    /// Built on first use.
    private lazy var checkedSession = makeSession(hub)
    /// Only for requests where a script explicitly asked to skip certificate checks: a separate connection pool.
    private lazy var trustingSession = makeSession(trustingHub)
    private let lock = NSLock()
    private var active: [ObjectIdentifier: Exchange] = [:]
    private var admitted: [String: Date] = [:]

    /// `protocolClasses` lets unit tests stub the network below the address policy.
    init(_ localDir: URL? = nil, protocolClasses: [AnyClass] = [], ownPort: @escaping () -> Int = { 0 }) {
        self.localDir = localDir
        self.protocolClasses = protocolClasses
        self.ownPort = ownPort
    }

    private func makeSession(_ hub: Hub) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 8
        c.timeoutIntervalForRequest = 60
        c.waitsForConnectivity = false
        if !protocolClasses.isEmpty { c.protocolClasses = protocolClasses }
        let q = OperationQueue()
        q.name = "tvbox.net"
        q.maxConcurrentOperationCount = 1
        return URLSession(configuration: c, delegate: hub, delegateQueue: q)
    }

    private func pool(verify: Bool) -> (URLSession, Hub) {
        lock.lock()
        defer { lock.unlock() }
        return verify ? (checkedSession, hub) : (trustingSession, trustingHub)
    }

    /// Ends the sessions (tests).
    func close() {
        lock.lock()
        defer { lock.unlock() }
        checkedSession.invalidateAndCancel()
        trustingSession.invalidateAndCancel()
    }

    // MARK: Policy

    /// True when a config address itself sits in a private network (then its relative resources may too). Imported files
    /// (`clan://localhost/…`) and this device are no network.
    static func isPrivateAddress(_ url: String) -> Bool {
        guard TVBoxUrl.isHttp(url), case let h = TVBoxUrl.host(url), !h.isEmpty else { return false }
        if h.hasSuffix(".local") || h.hasSuffix(".lan") { return true }
        return NetGuard.isIPLiteral(h) && NetGuard.isBlockedIP(h) && !isDeviceLocal(h)
    }

    /// An address of this device.
    static func isLoopback(_ url: String) -> Bool {
        let h = TVBoxUrl.host(url)
        return h == "localhost" || h.hasSuffix(".localhost") || isDeviceLocal(h)
    }

    /// Never reachable, LAN access or not: loopback, unspecified, multicast, broadcast.
    static func isDeviceLocal(_ ip: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return b[0] == 0 || b[0] == 127 || b[0] >= 224
        }
        var v6 = in6_addr()
        let plain = ip.substringBefore("%")
        if inet_pton(AF_INET6, plain, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            if b[0] == 0xFF || b.allSatisfy({ $0 == 0 }) { return true }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { return isDeviceLocal("\(b[12]).\(b[13]).\(b[14]).\(b[15])") }
        }
        return false
    }

    private static func allowed(_ ip: String, _ lan: Bool) -> Bool { lan ? !isDeviceLocal(ip) : !NetGuard.isBlockedIP(ip) }

    /// Literal addresses, checked before every hop. True = our own loopback proxy.
    private func checkLiteral(_ host: String, _ port: Int?, _ lan: Bool) throws -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") || h == "::1" || h.hasPrefix("127.") {
            let p = port ?? 80
            if p == 0 || p != ownPort() { throw TVBoxIOError("不允许访问本机端口 \(p)") }
            return true
        }
        if NetGuard.isIPLiteral(h), !Self.allowed(h, lan) { throw TVBoxIOError(Self.refusal("\(h) 是", lan)) }
        return false
    }

    private static func refusal(_ what: String, _ lan: Bool) -> String { lan ? "\(what)本机地址，已拦截" : "\(what)局域网地址，已拦截：可在 TVBox 设置里打开「允许访问局域网」" }

    /// Blocking.
    private static func checkNames(_ host: String, _ lan: Bool) throws {
        let blocked: Bool
        if lan { blocked = (NetGuard.resolverOverride?(host) ?? NetGuard.resolve(host)).contains { isDeviceLocal($0) } }
        else { blocked = NetGuard.resolvesToBlocked(host) }
        if blocked { throw TVBoxIOError(refusal("\(host) 指向", lan)) }
    }

    /// DNS guard, off the caller's thread unless the answer is known.
    private func admit(_ host: String, _ lan: Bool, _ done: @escaping (Error?) -> Void) {
        let key = (lan ? "l|" : "p|") + host
        lock.lock()
        let known = admitted[key].map { Date().timeIntervalSince($0) < 300 } ?? false
        lock.unlock()
        if known { done(nil); return }
        TVBoxWorkers.run { [weak self] in
            do {
                try Self.checkNames(host, lan)
                if let self {
                    self.lock.lock()
                    if self.admitted.count > 2000 { self.admitted.removeAll() }
                    self.admitted[key] = Date()
                    self.lock.unlock()
                }
                done(nil)
            } catch { done(error) }
        }
    }

    // MARK: Scope

    final class Scope: TVBoxHttp {
        let rules: NetRules
        private let net: TVBoxNet

        init(_ net: TVBoxNet, _ rules: NetRules) { self.net = net; self.rules = rules }

        /// The address policy on its own (literal addresses only).
        func check(_ raw: String) throws {
            guard let t = TVBoxUrl.target(raw) else { throw TVBoxIOError("地址无效：\(raw.prefix(120))") }
            _ = try net.checkLiteral(t.host, t.url.port ?? (t.url.scheme == "https" ? 443 : 80), rules.allowPrivate)
        }

        func cancel(_ tag: AnyObject) { net.cancel(tag) }

        func execute(_ r: NetRequest) throws -> NetResponse {
            let gate = DispatchSemaphore(value: 0)
            var out: Result<NetResponse, Error> = .failure(URLError(.unknown))
            net.start(r, rules) { out = $0; gate.signal() }
            gate.wait()
            return try out.get()
        }

        func fetchNative(_ r: NetRequest) async throws -> NetResponse {
            let once = TVBoxOnce<NetResponse>()
            let exchange = TVBoxOnce<Exchange>()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NetResponse, Error>) in
                    once.deliver { cont.resume(with: $0) }
                    if once.resolved { return }
                    exchange.resolve(.success(net.start(r, rules) { once.resolve($0) }))
                }
            } onCancel: {
                once.resolve(.failure(CancellationError()))
                exchange.deliver { if case .success(let x) = $0 { x.abort(URLError(.cancelled)) } }
            }
        }
    }

    @discardableResult
    private func start(_ r: NetRequest, _ rules: NetRules, _ done: @escaping (Result<NetResponse, Error>) -> Void) -> Exchange {
        let x = Exchange(self, r, rules, done)
        lock.lock()
        active[ObjectIdentifier(x)] = x
        lock.unlock()
        x.start()
        return x
    }

    private func finished(_ x: Exchange) {
        lock.lock()
        active[ObjectIdentifier(x)] = nil
        lock.unlock()
    }

    /// Aborts everything a spider session or a screen still has in flight.
    func cancel(_ tag: AnyObject) {
        lock.lock()
        let mine = active.values.filter { $0.request.tag === tag }
        lock.unlock()
        mine.forEach { $0.abort(URLError(.cancelled)) }
    }

    // MARK: Local files

    /// Files imported by the user: `clan://localhost/x`, `file:///x` — only inside the import folder.
    func local(_ url: String) throws -> Data {
        guard let f = localFile(url) else { throw TVBoxIOError("本地文件不存在：\(TVBoxUrl.fileName(url))（请先导入该文件）") }
        return try Data(contentsOf: f)
    }

    func localFile(_ url: String) -> URL? {
        guard let dir = localDir?.standardizedFileURL.resolvingSymlinksInPath() else { return nil }
        var path = TVBoxUrl.decode(url.substringAfter("://").substringBefore("?").substringBefore(";md5;"))
        if path.hasPrefix("localhost") { path.removeFirst(9) }
        while path.hasPrefix("/") { path.removeFirst() }
        for p in [path, path.substringAfterLast("/")] where !p.isEmpty {
            let f = dir.appendingPathComponent(p).standardizedFileURL.resolvingSymlinksInPath()
            var folder: ObjCBool = false
            if f.path.hasPrefix(dir.path + "/"), FileManager.default.fileExists(atPath: f.path, isDirectory: &folder), !folder.boolValue { return f }
        }
        return nil
    }

    // MARK: Encrypted DNS

    /// DoH covers every lookup of the process (URLSession and the guard's `getaddrinfo` share one resolver), so it is only
    /// switched on after the server has answered. False = the system resolver stays in use.
    static func applyDoh(_ d: TVBoxDoh?) async -> Bool {
        guard let d, let url = URL(string: d.url), url.scheme == "https" else {
            NWParameters.PrivacyContext.default.requireEncryptedNameResolution(false, fallbackResolver: nil)
            return true
        }
        // RFC 8484 example query: A www.example.com
        guard let probe = URL(string: d.url + (d.url.contains("?") ? "&" : "?") + "dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB") else { return false }
        var q = URLRequest(url: probe, timeoutInterval: 6)
        q.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: q), (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 12 else { return false }
        let servers = d.ips.compactMap { ip -> NWEndpoint? in
            if let a = IPv4Address(ip) { return .hostPort(host: .ipv4(a), port: 443) }
            if let a = IPv6Address(ip) { return .hostPort(host: .ipv6(a), port: 443) }
            return nil
        }
        NWParameters.PrivacyContext.default.requireEncryptedNameResolution(true, fallbackResolver: .https(url, serverAddresses: servers))
        return true
    }

    // MARK: Exchange

    /// One request with its redirects. `done` runs exactly once, on any thread.
    final class Exchange {
        let request: NetRequest
        private weak var net: TVBoxNet?
        private let rules: NetRules
        private let done: (Result<NetResponse, Error>) -> Void
        private let lock = NSLock()
        private var over = false
        private var task: URLSessionTask?
        private var hub: Hub?
        private var deadline: DispatchWorkItem?
        private var method: String
        private var body: Data?
        private var hops = 0
        // the hop in flight; touched on the session's delegate queue only
        private var address = ""
        private var response: HTTPURLResponse?
        private var data = Data()
        private var redirect: String?
        /// Certificate name when the config maps the host elsewhere.
        fileprivate private(set) var certificateName: String?

        init(_ net: TVBoxNet, _ r: NetRequest, _ rules: NetRules, _ done: @escaping (Result<NetResponse, Error>) -> Void) {
            self.net = net
            request = r
            self.rules = rules
            self.done = done
            method = r.method.uppercased()
            body = r.body
        }

        func start() {
            if TVBoxUrl.isLocal(request.url) {
                TVBoxWorkers.run { [self] in
                    guard let net else { abort(URLError(.cancelled)); return }
                    finish(Result { try net.local(request.url) }.map { NetResponse(code: 200, url: request.url, headers: [:], body: $0) })
                }
                return
            }
            let timer = SpiderClock.after(request.timeoutMs) { [weak self] in self?.abort(URLError(.timedOut)) }
            lock.lock()
            deadline = timer
            lock.unlock()
            open(request.url)
        }

        func abort(_ e: Error) { finish(.failure(e)) }

        private func finish(_ r: Result<NetResponse, Error>) {
            lock.lock()
            if over { lock.unlock(); return }
            over = true
            let t = task, d = deadline
            task = nil
            deadline = nil
            lock.unlock()
            d?.cancel()
            if let t {
                hub?.forget(t)
                t.cancel()
            }
            net?.finished(self)
            done(r)
        }

        private var isOver: Bool { lock.lock(); defer { lock.unlock() }; return over }

        private func open(_ raw: String) {
            guard let net else { abort(URLError(.cancelled)); return }
            guard let t = TVBoxUrl.target(raw) else { abort(TVBoxIOError("地址无效：\(raw.prefix(120))")); return }
            let port = t.url.port ?? (t.url.scheme == "https" ? 443 : 80)
            let own: Bool
            var name = t.host
            do {
                own = try net.checkLiteral(t.host, port, rules.allowPrivate)
                if own, !request.loopback { throw TVBoxIOError("不允许访问本机地址") }
                if !own, let mapped = rules.hosts[t.host] {
                    name = mapped
                    // a hosts entry may not be used to reach this device
                    if NetGuard.isIPLiteral(name) ? !TVBoxNet.allowed(name, rules.allowPrivate) : name == "localhost" { throw TVBoxIOError("\(t.host) 指向本机或内网地址，已拦截") }
                }
            } catch { abort(error); return }
            let host = name
            if own || NetGuard.isIPLiteral(host) { send(t, host); return }
            net.admit(host, rules.allowPrivate) { [self] e in
                if let e { abort(e) } else { send(t, host) }
            }
        }

        private func send(_ t: TVBoxUrl.Target, _ host: String) {
            guard let net else { abort(URLError(.cancelled)); return }
            if isOver { return }
            address = t.url.absoluteString
            response = nil
            data = Data()
            redirect = nil
            certificateName = nil
            var url = t.url
            if host != t.host, var c = URLComponents(url: t.url, resolvingAgainstBaseURL: false) {
                c.host = host.contains(":") ? "[\(host)]" : host
                if let mapped = c.url {
                    url = mapped
                    certificateName = t.host
                }
            }
            var q = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(1, Double(request.timeoutMs) / 1000))
            q.httpMethod = method
            q.httpShouldHandleCookies = false
            var agent = false, authorized = false
            for (k, v) in request.headers {
                let name = k.trimmed, l = name.lowercased()
                if name.isEmpty || v.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" }) { continue }
                if l == "accept-encoding" || l == "content-length" { continue } // transparent gzip
                if l == "user-agent" { agent = true }
                if l == "authorization" { authorized = true }
                q.setValue(Self.headerSafe(v.trimmed), forHTTPHeaderField: name)
            }
            if !agent { q.setValue(TVBoxNet.userAgent, forHTTPHeaderField: "User-Agent") }
            if let u = t.user, !u.isEmpty, !authorized { q.setValue("Basic " + Data("\(u):\(t.password ?? "")".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
            for rule in rules.headers where rule.matches(t.host) { for (k, v) in rule.headers { q.setValue(Self.headerSafe(v), forHTTPHeaderField: k) } }
            if certificateName != nil { q.setValue(t.host + (t.url.port.map { ":\($0)" } ?? ""), forHTTPHeaderField: "Host") }
            if method != "GET" && method != "HEAD" { q.httpBody = body ?? Data() }
            let (session, hub) = net.pool(verify: request.verify)
            let task = session.dataTask(with: q)
            hub.remember(task, self)
            lock.lock()
            let late = over
            if !late { self.task = task; self.hub = hub }
            lock.unlock()
            if late { hub.forget(task); task.cancel() } else { task.resume() }
        }

        /// Values outside ASCII (Chinese Referer paths) are percent-encoded instead of mangled.
        private static func headerSafe(_ v: String) -> String {
            if v.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F || $0 == 0x09 }) { return v }
            return v.unicodeScalars.map { $0.value >= 0x20 && $0.value < 0x7F ? String($0) : TVBoxUrl.encode(String($0)) }.joined()
        }

        // MARK: Delegate queue

        fileprivate func received(_ r: HTTPURLResponse) -> URLSession.ResponseDisposition {
            response = r
            if request.redirect, TVBoxNet.redirects.contains(r.statusCode), let location = r.value(forHTTPHeaderField: "Location"), !location.isEmpty {
                redirect = location
                return .cancel
            }
            if r.expectedContentLength > Int64(request.maxBytes), method != "HEAD" {
                abort(tooBig)
                return .cancel
            }
            return .allow
        }

        private var tooBig: Error { TVBoxIOError("内容超过 \(request.maxBytes >> 20) MB") }

        fileprivate func received(_ d: Data) {
            if data.count + d.count > request.maxBytes { abort(tooBig); return }
            data.append(d)
        }

        fileprivate func completed(_ e: Error?) {
            if let location = redirect, let r = response {
                hops += 1
                if hops > 8 { abort(TVBoxIOError("跳转次数过多")); return }
                if r.statusCode == 303 || ((r.statusCode == 301 || r.statusCode == 302) && method == "POST") { method = "GET"; body = nil }
                open(TVBoxUrl.join(address, location))
                return
            }
            if let e { abort(e); return }
            guard let r = response else { abort(URLError(.badServerResponse)); return }
            var headers: [String: [String]] = [:]
            for (k, v) in r.allHeaderFields {
                guard let name = (k as? String)?.lowercased() else { continue }
                let value = v as? String ?? "\(v)"
                headers[name, default: []] += name == "set-cookie" ? Self.splitCookies(value) : [value]
            }
            finish(.success(NetResponse(code: r.statusCode, url: address, headers: headers, body: data)))
        }

        private static let cookieGap = TVBoxRegex(",\\s*(?=[^;,=\\s]+=)")

        /// URLSession joins repeated `Set-Cookie` headers with commas.
        static func splitCookies(_ v: String) -> [String] { cookieGap.replace(v) { _ in "\n" }.pieces("\n").map(\.trimmed).filter { !$0.isEmpty } }
    }

    /// Delegate of one session: routes callbacks to the exchange of a task.
    fileprivate final class Hub: NSObject, URLSessionDataDelegate {
        private let lock = NSLock()
        private var exchanges: [Int: Exchange] = [:]
        private let isTrusting: Bool

        init(trusting: Bool = false) { isTrusting = trusting }

        func remember(_ t: URLSessionTask, _ x: Exchange) { lock.lock(); exchanges[t.taskIdentifier] = x; lock.unlock() }
        func forget(_ t: URLSessionTask) { lock.lock(); exchanges[t.taskIdentifier] = nil; lock.unlock() }
        private func exchange(_ t: URLSessionTask) -> Exchange? { lock.lock(); defer { lock.unlock() }; return exchanges[t.taskIdentifier] }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let x = exchange(dataTask), let r = response as? HTTPURLResponse else { completionHandler(.cancel); return }
            completionHandler(x.received(r))
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { exchange(dataTask)?.received(data) }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let x = exchange(task)
            forget(task)
            x?.completed(error)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust else {
                // no interactive logins: the 401 itself is the answer
                completionHandler(.performDefaultHandling, nil)
                return
            }
            if isTrusting { completionHandler(.useCredential, URLCredential(trust: trust)); return }
            guard let name = exchange(task)?.certificateName else { completionHandler(.performDefaultHandling, nil); return }
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, name as CFString))
            if SecTrustEvaluateWithError(trust, nil) { completionHandler(.useCredential, URLCredential(trust: trust)) } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }
}
