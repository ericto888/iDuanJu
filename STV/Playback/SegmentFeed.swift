import Foundation

/// One upstream segment download that any number of readers can follow while it is still running.
/// The player gets its first bytes as soon as the CDN sends them, not after the whole segment has arrived, and a
/// prefetch that is already under way is joined instead of started twice.
final class SegmentFeed: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// An upstream answer outside 2xx.
    struct Status: LocalizedError {
        let code: Int
        var errorDescription: String? { "upstream \(code)" }
    }

    /// Largest segment that is held in memory as a whole.
    static let limit = 96 << 20
    /// Bytes a pass-through download may be ahead of its reader.
    private static let window = 8 << 20

    private let limit: Int
    /// False: a pass-through for one reader, bytes it has taken are dropped.
    private let keep: Bool
    private let lan: Bool?
    private let lock = NSLock()
    private var buffer = Data()
    /// Bytes dropped in front of `buffer`.
    private var base = 0
    private var held = false
    private var response: HTTPURLResponse?
    private var finished = false
    private var failure: Error?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var readers = 0
    private var task: URLSessionDataTask?

    init(session: URLSession, request: URLRequest, limit: Int = SegmentFeed.limit, keep: Bool = true, lan: Bool? = nil) {
        self.limit = limit
        self.keep = keep
        self.lan = lan
        super.init()
        let t = session.dataTask(with: request)
        t.delegate = self
        task = t
        t.resume()
    }

    /// One bounded GET of something a source points at (playlist, key, subtitle, 弹幕).
    static func fetch(_ request: URLRequest, session: URLSession = .shared, limit: Int, lan: Bool? = nil) async throws -> (data: Data, response: HTTPURLResponse) {
        if let u = request.url?.absoluteString { try await LanPolicy.check(u, lan: lan) }
        let feed = SegmentFeed(session: session, request: request, limit: limit, lan: lan)
        return try await withTaskCancellationHandler {
            let head = try await feed.head()
            return (try await feed.data(), head)
        } onCancel: { feed.cancel() }
    }

    func beginRead() { lock.lock(); readers += 1; lock.unlock() }
    func endRead() { lock.lock(); readers -= 1; lock.unlock() }

    /// Seek moved away: stop unless the player is reading this very segment.
    func cancelIfUnread() {
        lock.lock(); let idle = readers == 0 && !finished; lock.unlock()
        if idle { task?.cancel() }
    }

    func cancel() { task?.cancel() }

    /// Response head, as soon as it is in. Throws for transport errors and non-2xx answers.
    func head() async throws -> HTTPURLResponse {
        while true {
            let (r, f, done) = snapshot { (response, failure, finished) }
            if let f { throw f }
            if let r { return r }
            if done { throw URLError(.badServerResponse) }
            await changed(since: 0, needsHead: true)
        }
    }

    /// Bytes from `offset` that have arrived so far; waits for more. Empty = the download is complete.
    func bytes(from offset: Int) async throws -> Data {
        while true {
            let (chunk, f, done) = snapshot { () -> (Data, Error?, Bool) in
                if !keep { drop(to: offset) }
                let at = offset - base
                return (at >= 0 && buffer.count > at ? buffer.subdata(in: at..<buffer.count) : Data(), failure, finished)
            }
            if !chunk.isEmpty { return chunk }
            if let f { throw f }
            if done { return Data() }
            await changed(since: offset, needsHead: false)
        }
    }

    /// The complete segment.
    func data() async throws -> Data {
        while true {
            let (all, f, done) = snapshot { (buffer, failure, finished) }
            if let f { throw f }
            if done { return all }
            try Task.checkCancellation()
            await changed(since: all.count, needsHead: false)
        }
    }

    /// `lock` is held.
    private func drop(to offset: Int) {
        let n = min(buffer.count, offset - base)
        if n > 0 {
            buffer = n == buffer.count ? Data() : Data(buffer.dropFirst(n))
            base += n
        }
        if held, buffer.count < Self.window / 2 {
            held = false
            task?.resume()
        }
    }

    private func snapshot<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    private func changed(since offset: Int, needsHead: Bool) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            let ready = finished || failure != nil || (needsHead ? response != nil : base + buffer.count > offset)
            if !ready { waiters.append(c) }
            lock.unlock()
            if ready { c.resume() }
        }
    }

    private func notify(_ change: () -> Void) {
        lock.lock()
        change()
        let w = waiters
        waiters = []
        lock.unlock()
        w.forEach { $0.resume() }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive resp: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = resp as? HTTPURLResponse
        let ok = http.map { (200..<300).contains($0.statusCode) } ?? false
        notify {
            if ok { response = http } else { failure = http.map { Status(code: $0.statusCode) } ?? URLError(.badServerResponse) }
        }
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var full = false
        notify {
            buffer.append(data)
            if keep, buffer.count > limit, failure == nil {
                failure = URLError(.dataLengthExceedsMaximum)
                buffer = Data()
                full = true
            } else if !keep, !held, buffer.count > Self.window {
                held = true
                dataTask.suspend()
            }
        }
        if full { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        LanPolicy.redirect(request, lan: lan, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        notify {
            if let error, failure == nil { failure = error }
            finished = true
        }
    }
}
