import Foundation

struct SpiderTimeout: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The session was closed (config removed, evicted, stuck) before the call could start.
struct SpiderStopped: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One shared wake-up queue for call deadlines.
enum SpiderClock {
    private static let queue = DispatchQueue(label: "tvbox.deadline", qos: .utility)

    @discardableResult
    static func after(_ ms: Int, _ block: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: block)
        queue.asyncAfter(deadline: .now() + .milliseconds(max(0, ms)), execute: item)
        return item
    }
}

/// The thread a spider lives on: started with its first job, ends when closed.
private final class SpiderThread {
    private let cond = NSCondition()
    private let name: String
    private let stack: Int
    private var jobs: [(run: () -> Void, abort: () -> Void)] = []
    private var started = false
    private var closed = false

    init(name: String, stack: Int) { self.name = name; self.stack = stack }

    /// False once the thread is closed.
    func submit(_ run: @escaping () -> Void, abort: @escaping () -> Void) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        if closed { return false }
        jobs.append((run, abort))
        if !started {
            started = true
            let t = Thread { self.loop() }
            t.name = name
            t.stackSize = stack
            t.qualityOfService = .userInitiated
            t.start()
        }
        cond.signal()
        return true
    }

    /// Queued jobs still run.
    func close() {
        cond.lock()
        closed = true
        cond.signal()
        cond.unlock()
    }

    /// Queued jobs are aborted; `last` runs once the thread is free again.
    func drop(last: (() -> Void)? = nil) {
        cond.lock()
        closed = true
        let left = jobs
        jobs = []
        if let last, started { jobs.append((last, {})) }
        cond.signal()
        cond.unlock()
        left.forEach { $0.abort() }
    }

    private func loop() {
        while true {
            cond.lock()
            while jobs.isEmpty && !closed { cond.wait() }
            if jobs.isEmpty { cond.unlock(); return }
            let job = jobs.removeFirst()
            cond.unlock()
            autoreleasepool { job.run() }
        }
    }
}

/// A spider instance and the single thread it lives on. The instance is created and initialised lazily on that thread; every
/// call has a deadline measured from the moment it starts running (not from when it was queued). A call that ignores its
/// interrupt poisons the session (`dead`); the engine then starts a fresh one.
final class SpiderSession {
    let name: String
    let kind: SiteKind
    private let initTimeoutMs: Int
    private let graceMs: Int
    private let create: () throws -> Spider
    private let begin: (Spider) throws -> Void
    private let thread: SpiderThread

    private let lock = NSLock()
    private var spiderRef: Spider?
    /// Being initialised: not usable yet, but a timeout must be able to interrupt it.
    private var starting: Spider?
    private var isDead = false
    private var initError: Error?
    private var initErrorAt = Date.distantPast
    /// Calls that wait for the initialisation.
    private var waiting = 0
    /// The running job was interrupted.
    private var halted = false
    private var inFlight = 0
    private var used = Date()

    init(_ name: String, initTimeoutMs: Int = 45_000, kind: SiteKind = .unsupported, graceMs: Int = 3_000, create: @escaping () throws -> Spider, begin: @escaping (Spider) throws -> Void = { _ in }) {
        self.name = name
        self.initTimeoutMs = initTimeoutMs
        self.kind = kind
        self.graceMs = graceMs
        self.create = create
        self.begin = begin
        // scripts parse big documents recursively: they need more than the 512 KB default
        thread = SpiderThread(name: "tvbox-" + String(name.prefix(30)), stack: kind.isCode ? 8 << 20 : 1 << 20)
    }

    deinit { thread.close() }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var dead: Bool { locked { isDead } }
    var ready: Bool { locked { spiderRef != nil } }
    var busy: Bool { locked { inFlight > 0 } }
    var lastUsed: Date { locked { used } }
    private var spider: Spider? { locked { spiderRef } }

    /// Runs on the spider thread only.
    private func ensure() throws -> Spider {
        if let s = spider { return s }
        if dead { throw SpiderStopped("「\(name)」已停止") }
        // a failed initialisation is remembered briefly so a burst of queued calls does not repeat a slow download
        if let e = locked({ Date().timeIntervalSince(initErrorAt) < 5 ? initError : nil }) { throw e }
        do {
            let s = try create()
            locked { starting = s }
            defer { locked { starting = nil } }
            do { try begin(s) } catch {
                s.destroy()
                throw error
            }
            // closed meanwhile: nobody else knows this instance
            let late = locked { () -> Bool in
                if isDead { return true }
                spiderRef = s
                initError = nil
                return false
            }
            if late {
                s.destroy()
                throw SpiderStopped("「\(name)」已停止")
            }
            return s
        } catch {
            // an initialisation that somebody stopped says nothing about the site
            locked { if !halted, !(error is SpiderTimeout), !(error is SpiderStopped) { initError = error; initErrorAt = Date() } }
            throw error
        }
    }

    /// Creates / initialises the spider ahead of the first real call.
    func warm() async throws {
        locked { waiting += 1 }
        defer { locked { waiting -= 1 } }
        try await run(initTimeoutMs, "初始化", shared: true) { _ in }
    }

    func call<T>(_ timeoutMs: Int, _ what: String, _ block: @escaping (Spider) throws -> T) async throws -> T {
        locked { inFlight += 1 }
        defer { locked { used = Date(); inFlight -= 1 } }
        if !ready { try await warm() }
        return try await run(timeoutMs, what, block)
    }

    /// The same for callers that own a thread (the loopback server).
    func callBlocking<T>(_ timeoutMs: Int, _ what: String, _ block: @escaping (Spider) throws -> T) throws -> T {
        locked { inFlight += 1 }
        defer { locked { used = Date(); inFlight -= 1 } }
        if !ready {
            locked { waiting += 1 }
            defer { locked { waiting -= 1 } }
            try wait(initTimeoutMs, "初始化") { _ in }
        }
        return try wait(timeoutMs, what, block)
    }

    private func wait<T>(_ timeoutMs: Int, _ what: String, _ block: @escaping (Spider) throws -> T) throws -> T {
        let gate = DispatchSemaphore(value: 0)
        var out: Result<T, Error> = .failure(SpiderStopped("「\(name)」已停止"))
        let call = Call<T>()
        call.deliver { out = $0; gate.signal() }
        start(call, timeoutMs, what, block)
        gate.wait()
        return try out.get()
    }

    /// `shared`: the initialisation, which a cancelled caller leaves running while others wait for it.
    private func run<T>(_ timeoutMs: Int, _ what: String, shared: Bool = false, _ block: @escaping (Spider) throws -> T) async throws -> T {
        let call = Call<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                call.deliver { cont.resume(with: $0) }
                if Task.isCancelled { _ = call.resolve(.failure(CancellationError())) } else { start(call, timeoutMs, what, block) }
            }
        } onCancel: {
            let needed = shared && self.locked { self.waiting > 1 }
            if call.resolve(.failure(CancellationError())), !needed { self.stop(call) }
        }
    }

    /// One queued or running call; its result is delivered exactly once.
    private final class Call<T> {
        let lock = NSLock()
        private var pending: Result<T, Error>?
        private var done = false
        private var sink: ((Result<T, Error>) -> Void)?
        var running = false

        /// A result that arrived before the sink was set is delivered at once.
        func deliver(_ f: @escaping (Result<T, Error>) -> Void) {
            lock.lock()
            let early = pending
            pending = nil
            if early == nil { sink = f }
            lock.unlock()
            if let early { f(early) }
        }

        var resolved: Bool { lock.lock(); defer { lock.unlock() }; return done }

        /// True for the first result.
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

    private func stop<T>(_ call: Call<T>) {
        call.lock.lock()
        let running = call.running
        // a call that is still queued must not disturb the one that is running
        if running {
            locked { () -> Spider? in
                halted = true
                return spiderRef ?? starting
            }?.interrupt()
        }
        call.lock.unlock()
        guard running else { return }
        // the thread gets a grace period to unwind; a spider that keeps spinning is abandoned together with its session
        SpiderClock.after(graceMs) { [weak self] in
            call.lock.lock()
            let stuck = call.running
            call.lock.unlock()
            if stuck { self?.poison() }
        }
    }

    private func start<T>(_ call: Call<T>, _ timeoutMs: Int, _ what: String, _ block: @escaping (Spider) throws -> T) {
        if dead { _ = call.resolve(.failure(SpiderStopped("「\(name)」已停止"))); return }
        let name = self.name
        let body: () -> Void = { [self] in
            if call.resolved { return }
            locked { () -> Spider? in
                halted = false
                return spiderRef
            }?.resume()
            call.lock.lock(); call.running = true; call.lock.unlock()
            // also ends a call nobody waits for any more
            let deadline = SpiderClock.after(timeoutMs) {
                _ = call.resolve(.failure(SpiderTimeout("「\(name)」\(what) 超时（\(max(1, timeoutMs / 1000)) 秒）")))
                self.stop(call)
            }
            let result: Result<T, Error>
            do { result = .success(try block(try ensure())) } catch { result = .failure(Self.readable(name, error)) }
            deadline.cancel()
            call.lock.lock(); call.running = false; call.lock.unlock()
            _ = call.resolve(result)
        }
        let queued = thread.submit(body) { _ = call.resolve(.failure(SpiderStopped("「\(name)」已停止响应，请重试"))) }
        if !queued { _ = call.resolve(.failure(SpiderStopped("「\(name)」已停止"))) }
    }

    private static func readable(_ name: String, _ e: Error) -> Error {
        if e is CancellationError || e is SpiderTimeout || e is SpiderStopped || e is ProviderError || e is TVBoxError { return e }
        if (e as? URLError)?.code == .cancelled { return SpiderTimeout("「\(name)」请求被中断") }
        return SpiderErrors.wrap(name, e)
    }

    private func poison() {
        let s = locked { () -> Spider? in
            isDead = true
            return spiderRef
        }
        thread.drop(last: s.map { s in { s.destroy() } })
    }

    func close() {
        let (s, new) = locked { () -> (Spider?, Bool) in
            if isDead { return (nil, false) }
            isDead = true
            return (spiderRef ?? starting, spiderRef == nil)
        }
        s?.interrupt()
        // one that is still starting is destroyed where it starts
        if let s, !new { _ = thread.submit({ s.destroy() }, abort: {}) }
        thread.close()
        SpiderClock.after(5_000) { [thread] in thread.drop() }
    }
}

/// Failures as one readable Chinese line.
enum SpiderErrors {
    static func wrap(_ name: String, _ e: Error) -> Error { TVBoxError("「\(name)」\(text(e))") }

    static func text(_ e: Error) -> String {
        if let u = e as? URLError {
            switch u.code {
            case .cannotFindHost, .dnsLookupFailed: return "无法解析域名 " + (u.failingURL?.host ?? "")
            case .timedOut: return "网络超时"
            case .cannotConnectToHost: return "无法连接服务器"
            case .networkConnectionLost: return "连接中断"
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return "没有网络连接"
            case .cancelled: return "请求被中断"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
                return "安全连接失败"
            case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData: return "服务器返回的内容无法识别"
            default: break
            }
        }
        if e is CancellationError { return "已取消" }
        let m = e.localizedDescription.trimmed
        let first = m.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.isEmpty ? String(describing: type(of: e)) : String(first.prefix(160))
    }
}
