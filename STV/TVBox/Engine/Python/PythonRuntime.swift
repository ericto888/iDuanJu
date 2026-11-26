import Foundation
import CPythonHost

/// Why a Python script call failed. `errorDescription` is meant for the user.
enum PythonError: LocalizedError, Equatable {
    case missing
    case start(String)
    case notLoaded
    case unloaded
    case timeout
    /// "Type: message" of the Python exception. The full traceback goes to the host `log` function.
    case script(String)

    var errorDescription: String? {
        switch self {
        case .missing: return PythonRuntime.missingMessage
        case .start(let m): return "Python 运行时启动失败：\(m)"
        case .notLoaded: return "Python 脚本未加载"
        case .unloaded: return "Python 脚本已卸载"
        case .timeout: return "Python 脚本执行超时"
        case .script(let m): return m
        }
    }
}

/// The embedded CPython: one interpreter per process, started on first use, one native thread per spider.
///
/// The runtime files are optional (scripts/fetch-ios-python.sh, scripts/embed-ios-python.sh); without them `isAvailable` is
/// false and every call throws `PythonError.missing`.
final class PythonRuntime: @unchecked Sendable {
    typealias Host = @Sendable (_ key: String, _ name: String, _ args: String) -> String

    static let shared = PythonRuntime()
    static let missingMessage = "此版本未包含 Python 运行时"
    static let runner = "idj_runner"
    /// Runtime files are inside this build (file check only, does not start the interpreter).
    static var isAvailable: Bool { files != nil }
    private static let files = PythonFiles(app: Bundle.main)

    private let lock = NSLock()
    private var spiders: [String: PythonSpider] = [:]
    /// Unloaded spiders whose thread has not ended yet.
    private var closing: [String: PythonWorker] = [:]
    private var serial: UInt64 = 0

    private let hostLock = NSLock()
    private var hostFunction: Host?

    private enum StartState { case idle, starting, running, failed(String) }
    private let startCond = NSCondition()
    private var startState = StartState.idle
    /// The interpreter's main thread; after start-up it delivers interrupts (which wait for the GIL).
    private let mainThread = PythonMainThread()
    private let timers = DispatchQueue(label: "python.timers", qos: .userInitiated)

    private init() {}

    // MARK: API

    var host: Host? {
        hostLock.lock(); defer { hostLock.unlock() }
        return hostFunction
    }

    /// Host ABI (shared/tvbox/HOST_ABI.md): (spider key, function name, args JSON) -> result JSON. Called on the thread that
    /// runs the script, without the GIL.
    func setHost(_ f: @escaping Host) {
        hostLock.lock(); hostFunction = f; hostLock.unlock()
    }

    /// Runs `idj_runner.load(key, source, ext)` on the spider's thread, starting the interpreter and the thread if needed.
    /// Loading an already loaded key replaces its script.
    func load(key: String, source: String, ext: String, siteKey: String = "", url: String = "", timeout: TimeInterval) async throws {
        try await load(key: key, source: source, ext: ext, siteKey: siteKey, url: url, timeout: timeout, runner: Self.runner)
    }

    func load(key: String, source: String, ext: String, siteKey: String = "", url: String = "", timeout: TimeInterval, runner: String) async throws {
        guard Self.isAvailable else { throw PythonError.missing }
        let spider = spiderForLoading(key)
        let job = PythonJob(.load(PythonScript(source: source, ext: ext, siteKey: siteKey, url: url, runner: runner)), timeout: timeout)
        do {
            _ = try await submit(job, to: spider)
        } catch {
            remove(key, only: spider)
            throw error
        }
    }

    /// Runs `idj_runner.call(key, method, args_json)` and returns its JSON. Calls to one key are serial; the timeout starts
    /// when the call starts. After a timeout the script is interrupted; if it does not react, the next call reloads it on a
    /// new thread.
    func call(key: String, method: String, argsJSON: String, timeout: TimeInterval) async throws -> String {
        guard Self.isAvailable else { throw PythonError.missing }
        guard let spider = existingSpider(key) else { throw PythonError.notLoaded }
        return try await submit(PythonJob(.call(method: method, args: argsJSON), timeout: timeout), to: spider)
    }

    func isLoaded(key: String) -> Bool { existingSpider(key) != nil }

    /// Stops what the spider is doing right now, as a timeout does.
    func interrupt(key: String) { existingSpider(key)?.interrupt() }

    /// Returns at once. Pending and running calls fail with `unloaded`; the script is interrupted, `idj_runner.unload(key)`
    /// runs and the thread ends.
    func unload(key: String) { remove(key) }

    /// "3.13.18", nil until the interpreter has started.
    var version: String? { idjpy_version().map { String(cString: $0) } }

    /// Starts the interpreter without loading anything.
    func start() async throws {
        guard Self.isAvailable else { throw PythonError.missing }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            Thread.detachNewThread {
                do { try self.ensureStarted(); c.resume() } catch { c.resume(throwing: error) }
            }
        }
    }

    /// Appends a directory to sys.path.
    func addSearchPath(_ path: String) async throws {
        try await start()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread { _ = idjpy_add_path(path); c.resume() }
        }
    }

    /// Spider threads that have not ended, including those of unloaded or unresponsive scripts.
    static var liveThreads: Int { PythonWorker.live }

    // MARK: Spiders

    private func existingSpider(_ key: String) -> PythonSpider? {
        lock.lock(); defer { lock.unlock() }
        return spiders[key]
    }

    private func spiderForLoading(_ key: String) -> PythonSpider {
        lock.lock(); defer { lock.unlock() }
        if let s = spiders[key] { return s }
        let s = PythonSpider(key: key, runtime: self, predecessor: closing[key])
        spiders[key] = s
        return s
    }

    /// Lock order: PythonRuntime.lock, then PythonSpider.cond.
    private func remove(_ key: String, only: PythonSpider? = nil) {
        lock.lock()
        guard let spider = spiders[key], only == nil || spider === only else { return lock.unlock() }
        spiders[key] = nil
        let (worker, finish) = spider.close()
        if let worker, !worker.hasExited { closing[key] = worker }
        lock.unlock()
        finish()
    }

    fileprivate func exited(_ worker: PythonWorker) {
        lock.lock()
        worker.hasExited = true
        if closing[worker.spider.key] === worker { closing[worker.spider.key] = nil }
        lock.unlock()
    }

    private func submit(_ job: PythonJob, to spider: PythonSpider) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                job.attach(c)
                spider.enqueue(job)
            }
        } onCancel: {
            // A running script is left alone (its state stays consistent) until it returns or times out.
            job.finish(.failure(CancellationError()))
        }
    }

    fileprivate func nextSerial() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        serial += 1
        return serial
    }

    // MARK: Services for spider threads

    /// Blocks until the interpreter runs.
    fileprivate func ensureStarted() throws {
        startCond.lock()
        defer { startCond.unlock() }
        if case .idle = startState {
            startState = .starting
            mainThread.start()
            mainThread.enqueue { [self] in
                let failure = Self.startInterpreter()
                startCond.lock()
                startState = failure.map { .failed($0) } ?? .running
                startCond.broadcast()
                startCond.unlock()
            }
        }
        while case .starting = startState { startCond.wait() }
        if case .failed(let m) = startState { throw PythonError.start(m) }
    }

    private static func startInterpreter() -> String? {
        guard let files else { return missingMessage }
        var err: UnsafeMutablePointer<CChar>?
        let rc = idjpy_start(files.library, files.home, files.searchPath.joined(separator: ":"), files.executable, pythonHostCall, &err)
        defer { idjpy_free(err) }
        return rc == 0 ? nil : err.map { String(cString: $0) } ?? "unknown"
    }

    @discardableResult
    fileprivate func after(_ seconds: TimeInterval, _ f: @escaping () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: timers)
        t.setEventHandler {   // keeps the source alive until it fires or is cancelled
            t.cancel()
            f()
        }
        t.schedule(deadline: .now() + max(seconds, 0.01))
        t.resume()
        return t
    }

    fileprivate func interrupt(_ worker: PythonWorker, serial: UInt64) {
        mainThread.enqueue { worker.interrupt(serial) }
    }

    fileprivate func hostCall(_ key: String, _ name: String, _ args: String) -> String {
        host?(key, name, args) ?? #"{"e":"host not ready"}"#
    }

    fileprivate func log(_ key: String, _ text: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["m": text]) else { return }
        _ = hostCall(key, "log", String(decoding: data, as: UTF8.self))
    }
}

private let pythonHostCall: idjpy_host_fn = { key, name, args in
    autoreleasepool {
        strdup(PythonRuntime.shared.hostCall(String(cString: key), String(cString: name), String(cString: args)))
    }
}

/// Where scripts/embed-ios-python.sh puts the runtime.
private struct PythonFiles {
    let library: String, home: String, executable: String, searchPath: [String]

    init?(app: Bundle) {
        let root = app.bundlePath
        library = root + "/Frameworks/Python.framework/Python"
        home = root + "/python"
        executable = app.executablePath ?? root + "/python"
        let stdlib = home + "/lib/stdlib.pyz", dynload = home + "/lib/python3.13/lib-dynload"
        guard [library, stdlib, dynload].allSatisfy(FileManager.default.fileExists(atPath:)) else { return nil }
        searchPath = [stdlib, dynload, root + "/tvbox/py", root + "/tvbox/py/ios_site"]
    }
}

private struct PythonScript {
    let source: String, ext: String, siteKey: String, url: String, runner: String
}

/// One pending load or call. Finishes exactly once (result, timeout, cancellation or unload).
private final class PythonJob: @unchecked Sendable {
    enum Kind { case load(PythonScript), call(method: String, args: String) }
    let kind: Kind
    let timeout: TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    init(_ kind: Kind, timeout: TimeInterval) {
        self.kind = kind
        self.timeout = timeout
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return result != nil
    }

    func attach(_ c: CheckedContinuation<String, Error>) {
        lock.lock()
        let r = result
        if r == nil { continuation = c }
        lock.unlock()
        if let r { c.resume(with: r) }
    }

    func finish(_ r: Result<String, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: r)
    }
}

/// One loaded script: a serial job queue and the thread that works on it. The thread is replaced when a script does not
/// react to an interrupt.
private final class PythonSpider: @unchecked Sendable {
    let key: String
    let runtime: PythonRuntime
    private let cond = NSCondition()
    private var jobs: [PythonJob] = []
    private var worker: PythonWorker?
    private var running: (job: PythonJob, serial: UInt64)?
    /// What the last load ran (also what a replacement thread loads again).
    private var script: PythonScript?
    private var closed = false
    private var predecessor: PythonWorker?

    init(key: String, runtime: PythonRuntime, predecessor: PythonWorker?) {
        self.key = key
        self.runtime = runtime
        self.predecessor = predecessor
    }

    func enqueue(_ job: PythonJob) {
        cond.lock()
        guard !closed else {
            cond.unlock()
            return job.finish(.failure(PythonError.unloaded))
        }
        jobs.append(job)
        if worker == nil { startWorker() }
        cond.broadcast()
        cond.unlock()
    }

    private func startWorker() {
        let w = PythonWorker(spider: self)
        worker = w
        running = nil
        w.start()
    }

    /// The thread that is still winding down, and what to do once no lock is held.
    func close() -> (PythonWorker?, () -> Void) {
        cond.lock(); defer { cond.unlock() }
        guard !closed else { return (nil, {}) }
        closed = true
        if worker == nil, script != nil { startWorker() }   // given up earlier: a new thread runs the unload
        let pending = jobs, current = running, w = worker
        jobs = []
        cond.broadcast()
        return (w, { [self] in
            for j in pending { j.finish(.failure(PythonError.unloaded)) }
            if let current, let w {
                current.job.finish(.failure(PythonError.unloaded))
                stop(w, current.serial)
            }
        })
    }

    // MARK: On the worker thread

    func run(on w: PythonWorker) {
        waitForPredecessor()
        while let job = next(for: w) {
            autoreleasepool { execute(job, on: w) }
        }
        // A thread that was replaced must not unload the script its successor has loaded.
        cond.lock()
        let runner = worker === w && closed ? script?.runner : nil
        cond.unlock()
        guard let runner, !w.isSuperseded else { return }
        w.attach()
        let serial = runtime.nextSerial()
        let timer = runtime.after(5) { [self] in stop(w, serial) }
        _ = w.invoke(runner, "unload", [key], serial: serial, log: false)
        timer.cancel()
        w.end()
    }

    /// The thread has ended.
    func ended(_ w: PythonWorker) {
        cond.lock()
        if worker === w { worker = nil }
        cond.unlock()
    }

    private func waitForPredecessor() {
        cond.lock()
        let p = predecessor
        predecessor = nil
        cond.unlock()
        p?.waitUntilExit(3)
    }

    private func next(for w: PythonWorker) -> PythonJob? {
        cond.lock(); defer { cond.unlock() }
        while worker === w, !closed {
            while !jobs.isEmpty {
                let job = jobs.removeFirst()
                if !job.isFinished { return job }
            }
            cond.wait()
        }
        return nil
    }

    private func execute(_ job: PythonJob, on w: PythonWorker) {
        do { try runtime.ensureStarted() } catch { return job.finish(.failure(error)) }
        w.attach()
        let serial = runtime.nextSerial()
        cond.lock()
        guard !closed, worker === w else {
            cond.unlock()
            return job.finish(.failure(PythonError.unloaded))
        }
        running = (job, serial)
        w.begin(serial)
        cond.unlock()
        let timer = runtime.after(job.timeout) { [self] in
            job.finish(.failure(PythonError.timeout))
            stop(w, serial)
        }
        let result = perform(job, on: w, serial: serial)
        timer.cancel()
        w.end()
        cond.lock()
        if worker === w { running = nil }
        cond.unlock()
        job.finish(result.mapError { $0 as Error })
    }

    private func perform(_ job: PythonJob, on w: PythonWorker, serial: UInt64) -> Result<String, PythonError> {
        switch job.kind {
        case .load(let s):
            return load(s, on: w, serial: serial)
        case .call(let method, let args):
            cond.lock()
            let s = script
            cond.unlock()
            guard let s else { return .failure(.notLoaded) }
            // This thread replaced one whose script would not stop.
            if !w.isLoaded, case .failure(let e) = load(s, on: w, serial: serial) { return .failure(e) }
            guard !job.isFinished else { return .failure(.timeout) }
            return w.invoke(s.runner, "call", [key, method, args], serial: serial)
        }
    }

    private func load(_ s: PythonScript, on w: PythonWorker, serial: UInt64) -> Result<String, PythonError> {
        w.isLoaded = false
        cond.lock()
        script = s
        cond.unlock()
        let site = s.siteKey.isEmpty && s.url.isEmpty ? [] : [s.siteKey, s.url]
        let r = w.invoke(s.runner, "load", [key, s.source, s.ext] + site, serial: serial)
        if case .success = r { w.isLoaded = true }
        return r
    }

    // MARK: Interrupts

    func interrupt() {
        cond.lock()
        let current = running, w = worker
        cond.unlock()
        guard let current, let w else { return }
        current.job.finish(.failure(PythonError.timeout))
        stop(w, current.serial)
    }

    /// Interrupts the script until it returns. After a second without reaction the thread is given up, so the next call
    /// starts over on a new one.
    private func stop(_ w: PythonWorker, _ serial: UInt64, attempt: Int = 0) {
        guard w.isRunning(serial) else { return }
        runtime.interrupt(w, serial: serial)
        if attempt == 2 { giveUp(w) }
        let delays: [TimeInterval] = [0.3, 0.7, 1, 2, 5]
        runtime.after(delays[min(attempt, delays.count - 1)]) { [self] in stop(w, serial, attempt: attempt + 1) }
    }

    private func giveUp(_ w: PythonWorker) {
        cond.lock()
        if worker === w, !closed {
            worker = nil
            running = nil
            if !jobs.isEmpty { startWorker() }
        }
        cond.unlock()
    }
}

/// A spider's native thread.
private final class PythonWorker: @unchecked Sendable {
    let spider: PythonSpider
    private let handle: OpaquePointer
    private let state = NSLock()
    private var serial: UInt64 = 0
    private var superseded = false
    private let done = DispatchSemaphore(value: 0)
    /// Guarded by PythonRuntime.lock.
    var hasExited = false
    /// Used on this thread only.
    var isLoaded = false

    private static let countLock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var live: Int { countLock.lock(); defer { countLock.unlock() }; return count }
    private static func add(_ n: Int) { countLock.lock(); count += n; countLock.unlock() }

    init(spider: PythonSpider) {
        self.spider = spider
        handle = idjpy_thread_new(spider.key)
    }

    deinit { idjpy_thread_free(handle) }

    /// The thread keeps this object alive until it ends.
    func start() {
        Self.add(1)
        pythonThread("python." + spider.key) { [self] in main() }
    }

    private func main() {
        spider.run(on: self)
        idjpy_thread_detach(handle)
        spider.ended(self)
        spider.runtime.exited(self)
        Self.add(-1)
        done.signal()
    }

    func attach() { idjpy_thread_attach(handle) }

    func begin(_ serial: UInt64) { state.lock(); self.serial = serial; state.unlock() }
    func end() { begin(0) }
    func isRunning(_ serial: UInt64) -> Bool { state.lock(); defer { state.unlock() }; return self.serial == serial }
    var isSuperseded: Bool { state.lock(); defer { state.unlock() }; return superseded }

    /// Waits for a thread of an unloaded spider with the same key; from then on it must not unload anything.
    func waitUntilExit(_ seconds: TimeInterval) {
        if done.wait(timeout: .now() + seconds) == .success { done.signal() }
        state.lock(); superseded = true; state.unlock()
    }

    /// On the runtime's main thread (waits for the GIL).
    func interrupt(_ serial: UInt64) { idjpy_interrupt(handle, serial) }

    func invoke(_ module: String, _ function: String, _ args: [String], serial: UInt64, log: Bool = true) -> Result<String, PythonError> {
        begin(serial)
        let strings = args.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var err: UnsafeMutablePointer<CChar>?, trace: UnsafeMutablePointer<CChar>?
        let out = strings.map { UnsafePointer($0) }.withUnsafeBufferPointer {
            idjpy_call(handle, serial, module, function, $0.baseAddress!, Int32($0.count), &err, &trace)
        }
        defer { idjpy_free(out); idjpy_free(err); idjpy_free(trace) }
        if let out { return .success(String(cString: out)) }
        let line = err.map { String(cString: $0) } ?? "Python error"
        if log, let trace { spider.runtime.log(spider.key, String(cString: trace)) }
        if line == "ModuleNotFoundError: No module named '\(module)'" { return .failure(.script("缺少 Python 脚本库 \(module)")) }
        return .failure(.script(line))
    }
}

/// Lives as long as the process: CPython ties its main thread to the thread that initialised it.
private final class PythonMainThread: @unchecked Sendable {
    private let cond = NSCondition()
    private var jobs: [() -> Void] = []

    func start() {
        pythonThread("python.main") { [self] in
            while true {
                cond.lock()
                while jobs.isEmpty { cond.wait() }
                let job = jobs.removeFirst()
                cond.unlock()
                autoreleasepool { job() }
            }
        }
    }

    func enqueue(_ job: @escaping () -> Void) {
        cond.lock(); jobs.append(job); cond.signal(); cond.unlock()
    }
}

/// CPython's recursion limits assume a stack like the main thread's on macOS; secondary threads only get 512 KB by default.
private func pythonThread(_ name: String, _ body: @escaping @Sendable () -> Void) {
    let t = Thread(block: body)
    t.name = name
    t.stackSize = 8 << 20
    t.qualityOfService = .userInitiated
    t.start()
}
