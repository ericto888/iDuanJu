import Foundation
import Network
import UIKit

/// Loopback HTTP server of the spiders (`/proxy?do=…`): one request per connection, streamed replies, one worker thread per
/// request. It only listens on 127.0.0.1, only answers requests addressed to it (no DNS rebinding through a web page) and
/// none that a web page sends: players and spiders send no foreign `Origin`.
final class LocalProxy: @unchecked Sendable {
    /// 9979 belongs to the JAR bridge of Android devices.
    static let ports: [UInt16] = [9978] + Array(9980...9998)

    /// Query and lower-cased request headers merged (the query wins).
    typealias Handler = ([String: String]) -> ProxyReply

    private let ports: [UInt16]
    private let queue = DispatchQueue(label: "tvbox.proxy")
    /// Serialises start / stop; never held while a request is served.
    private let gate = NSLock()
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    /// Where this server listened before.
    private var lastPort: UInt16 = 0
    private var wanted = false
    private var handler: Handler = { _ in .text("no handler", code: 404) }
    private let slots = DispatchSemaphore(value: 48)
    private var foreground: NSObjectProtocol?

    init(ports: [UInt16] = LocalProxy.ports) { self.ports = ports }

    deinit { if let foreground { NotificationCenter.default.removeObserver(foreground) } }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    /// 0 while the server is not running.
    var port: Int { locked { Int(boundPort) } }

    func setHandler(_ h: @escaping Handler) { locked { handler = h } }

    /// Starts on the first free port unless it runs already; returns the port (0 when every port is taken).
    @discardableResult func start() -> Int {
        gate.lock(); defer { gate.unlock() }
        locked { wanted = true }
        if let p = locked({ listener == nil ? nil : boundPort }) { return Int(p) }
        watchForeground()
        // after a restart the old address comes first: players may still hold it
        let last = locked { lastPort }
        for p in (last == 0 ? [] : [last]) + ports.filter({ $0 != last }) {
            var made = listen(p, again: p == last)
            // the socket of the previous listener closes asynchronously
            for _ in 0..<4 where made == nil && p == last {
                Thread.sleep(forTimeInterval: 0.15)
                made = listen(p, again: true)
            }
            if let l = made {
                locked { listener = l; boundPort = p; lastPort = p }
                return Int(p)
            }
        }
        locked { boundPort = 0 }
        return 0
    }

    func stop() {
        gate.lock(); defer { gate.unlock() }
        let l = locked { () -> NWListener? in
            wanted = false
            defer { listener = nil; boundPort = 0 }
            return listener
        }
        l?.stateUpdateHandler = nil
        l?.cancel()
    }

    /// `again`: connections of the previous listener may linger on the port.
    private func listen(_ port: UInt16, again: Bool) -> NWListener? {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = again
        guard let l = try? NWListener(using: params) else { return nil }
        let up = DispatchSemaphore(value: 0)
        final class Flag: @unchecked Sendable { var ok = false; var waiting = true }
        let flag = Flag()
        l.stateUpdateHandler = { [weak self, weak l] state in
            switch state {
            case .ready: if flag.waiting { flag.ok = true; flag.waiting = false; up.signal() }
            case .waiting, .failed, .cancelled:
                if flag.waiting { flag.waiting = false; up.signal() } else if let self, let l { self.lost(l) }
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return c.cancel() }
            c.start(queue: self.queue)
            self.accept(c)
        }
        l.start(queue: queue)
        _ = up.wait(timeout: .now() + 3)
        if queue.sync(execute: { flag.waiting = false; return flag.ok }) { return l }
        l.stateUpdateHandler = nil
        l.cancel()
        return nil
    }

    // MARK: Background

    /// iOS takes the socket away from a suspended app: listen again on the same port.
    private func lost(_ l: NWListener) {
        let mine = locked { () -> Bool in
            guard listener === l else { return false }
            listener = nil
            return wanted
        }
        l.stateUpdateHandler = nil
        l.cancel()
        if mine { DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.start() } }
    }

    private func watchForeground() {
        guard foreground == nil else { return }
        foreground = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            DispatchQueue.global(qos: .userInitiated).async { self?.check() }
        }
    }

    /// A listener may look alive although its socket is gone: ask it.
    func check() {
        guard let l = locked({ listener }), let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let c = NWConnection(host: "127.0.0.1", port: p, using: .tcp)
        let answered = DispatchSemaphore(value: 0)
        c.stateUpdateHandler = { state in
            if case .ready = state {
                c.send(content: Data("GET /proxy?do=ck HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8), completion: .idempotent)
                c.receive(minimumIncompleteLength: 1, maximumLength: 64) { d, _, _, _ in if d?.isEmpty == false { answered.signal() } }
            }
        }
        c.start(queue: queue)
        let ok = answered.wait(timeout: .now() + 2) == .success
        c.cancel()
        if !ok { lost(l) }
    }

    // MARK: Requests

    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        /// Lower-case names.
        var headers: [String: String]
        /// Not from a player or a spider; its body was not read.
        var refused = false
    }

    private func accept(_ c: NWConnection) {
        guard slots.wait(timeout: .now()) == .success else { return c.cancel() }
        let t = Thread { [self] in
            autoreleasepool { serve(Wire(c)) }
            slots.signal()
        }
        t.name = "tvbox.proxy.worker"
        t.stackSize = 1 << 20
        t.qualityOfService = .userInitiated
        t.start()
    }

    private func serve(_ w: Wire) {
        defer { w.close() }
        guard let r = read(w) else { return }
        write(w, r, r.refused ? .text("forbidden", code: 403) : answer(r))
    }

    static func allowed(_ h: [String: String]) -> Bool {
        func loopback(_ host: String) -> Bool { host == "127.0.0.1" || host == "localhost" }
        if let host = h["host"]?.lowercased(), !host.isEmpty, !loopback(host.substringBeforeLast(":")) { return false }
        if let site = h["sec-fetch-site"]?.lowercased(), site == "cross-site" { return false }
        // `null` (opaque pages) is foreign as well
        if let origin = h["origin"]?.lowercased(), !loopback(TVBoxUrl.host(origin)) { return false }
        return true
    }

    private func answer(_ r: Request) -> ProxyReply {
        var params = r.query
        var path = r.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("/file/") {
            params = ["do": "file", "path": String(path.dropFirst(6))]
        } else if path != "/proxy" { return .text("not found", code: 404) }
        if params["do"] == "ck" { return .text("ok") }
        for (k, v) in r.headers where params[k] == nil { params[k] = v }
        let h = locked { handler }
        return Self.ranged(h(params), r.headers["range"])
    }

    /// Cuts a complete 200 reply down to the requested range; handlers that answer 206 themselves are left alone.
    static func ranged(_ reply: ProxyReply, _ range: String?) -> ProxyReply {
        let total = reply.stream == nil ? Int64(reply.body.count) : reply.length
        guard reply.code == 200, total > 0, let range, range.hasPrefix("bytes="), !range.contains(","),
              !reply.headers.keys.contains(where: { ["content-range", "content-encoding"].contains($0.lowercased()) }) else { return reply }
        let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return reply }
        var from = Int64(parts[0]) ?? -1, to = Int64(parts[1]) ?? (total - 1)
        if parts[0].isEmpty { guard let n = Int64(parts[1]), n > 0 else { return reply }; from = max(0, total - n); to = total - 1 }
        guard from >= 0 else { return reply }
        var out = reply
        out.headers = reply.headers.filter { $0.key.lowercased() != "content-length" }
        guard from < total, from <= to else {
            out.code = 416
            out.headers["Content-Range"] = "bytes */\(total)"
            out.body = Data(); out.stream = nil; out.length = 0
            return out
        }
        to = min(to, total - 1)
        let count = to - from + 1
        out.code = 206
        out.headers["Content-Range"] = "bytes \(from)-\(to)/\(total)"
        out.length = count
        guard let stream = reply.stream else {
            let b = reply.body
            out.body = b.subdata(in: (b.startIndex + Int(from))..<(b.startIndex + Int(to) + 1))
            return out
        }
        var skip = from, left = count
        out.stream = {
            while left > 0 {
                guard var d = try stream() else { return nil }
                if skip > 0 {
                    let n = min(skip, Int64(d.count))
                    d = Data(d.dropFirst(Int(n)))
                    skip -= n
                    if d.isEmpty { continue }
                }
                if Int64(d.count) > left { d = Data(d.prefix(Int(left))) }
                left -= Int64(d.count)
                return d
            }
            return nil
        }
        return out
    }

    private func read(_ w: Wire) -> Request? {
        let end = Data("\r\n\r\n".utf8)
        var buf = Data()
        var head = buf.startIndex
        while true {
            if let r = buf.range(of: end) { head = r.lowerBound; break }
            guard buf.count < 64 << 10, let d = w.receive() else { return nil }
            buf.append(d)
        }
        let lines = String(decoding: buf[..<head], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 3, lines.count <= 100 else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") { headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) }
        }
        guard Self.allowed(headers) else { return Request(method: first[0].uppercased(), path: "", query: [:], headers: headers, refused: true) }
        var body = Data(buf[(head + end.count)...])
        let length = Int(headers["content-length"] ?? "") ?? 0
        guard length >= 0, length <= 4 << 20 else { return nil }
        while body.count < length { guard let d = w.receive() else { return nil }; body.append(d) }
        var target = String(first[1])
        if target.hasPrefixIgnoringCase("http://") { target = "/" + target.substringAfter("://").substringAfter("/", "") }
        var query = RT.query(target.substringAfter("?", ""))
        if headers["content-type"]?.hasPrefix("application/x-www-form-urlencoded") == true { query.merge(RT.query(String(decoding: body.prefix(length), as: UTF8.self))) { a, _ in a } }
        return Request(method: first[0].uppercased(), path: TVBoxUrl.decode(target.substringBefore("?")), query: query, headers: headers)
    }

    private static let reasons = [200: "OK", 204: "No Content", 206: "Partial Content", 301: "Moved Permanently", 302: "Found", 304: "Not Modified", 307: "Temporary Redirect", 400: "Bad Request",
        401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable", 429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway"]

    private func write(_ w: Wire, _ r: Request, _ reply: ProxyReply) {
        var head = "HTTP/1.1 \(reply.code) \(Self.reasons[reply.code] ?? "OK")\r\n"
        var type = reply.type.isEmpty ? "application/octet-stream" : reply.type
        var length = reply.stream == nil ? Int64(reply.body.count) : reply.length
        for (k, v) in reply.headers {
            guard !k.isEmpty, k.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f && $0 != 0x3a }), !v.contains(where: \.isNewline), !v.contains("\r\n") else { continue }
            switch k.lowercased() {
            case "connection", "transfer-encoding", "keep-alive", "server", "date", "access-control-allow-origin": break
            case "content-type": type = v
            case "content-length": if length < 0 || (r.method == "HEAD" && reply.stream == nil && reply.body.isEmpty) { length = Int64(v) ?? length }
            default: head += "\(k): \(v)\r\n"
            }
        }
        head += "Content-Type: \(type)\r\nConnection: close\r\n"
        let empty = r.method == "HEAD" || reply.code == 204 || reply.code == 304
        if length >= 0 { head += "Content-Length: \(length)\r\n" } else if !empty { head += "Transfer-Encoding: chunked\r\n" }
        guard w.send(Data((head + "\r\n").utf8)), !empty else { return }
        guard let stream = reply.stream else {
            var at = reply.body.startIndex
            while at < reply.body.endIndex {
                let to = min(at + (256 << 10), reply.body.endIndex)
                guard w.send(reply.body.subdata(in: at..<to)) else { return }
                at = to
            }
            return
        }
        do {
            while let d = try stream() {
                if d.isEmpty { continue }
                let ok = length < 0 ? w.send(Data((String(d.count, radix: 16) + "\r\n").utf8) + d + Data("\r\n".utf8)) : w.send(d)
                if !ok { return }
            }
            if length < 0 { _ = w.send(Data("0\r\n\r\n".utf8)) }
        } catch {
            w.abort()   // the player must see a broken transfer, not a short file
        }
    }

    /// Blocking reads and writes on a connection, for the worker thread.
    private final class Wire: @unchecked Sendable {
        private let c: NWConnection
        private var aborted = false
        init(_ c: NWConnection) { self.c = c }

        private final class Box: @unchecked Sendable { var data: Data?; var ok = false }

        func receive() -> Data? {
            let box = Box(), sem = DispatchSemaphore(value: 0)
            c.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { d, _, _, _ in
                box.data = d?.isEmpty == false ? d : nil
                sem.signal()
            }
            guard sem.wait(timeout: .now() + 20) == .success else { abort(); return nil }
            return box.data
        }

        /// A paused player stops reading for a long time: waits for it, but not for ever.
        func send(_ d: Data) -> Bool {
            let box = Box(), sem = DispatchSemaphore(value: 0)
            c.send(content: d, completion: .contentProcessed { e in
                box.ok = e == nil
                sem.signal()
            })
            guard sem.wait(timeout: .now() + 600) == .success else { abort(); return false }
            return box.ok
        }

        func abort() { aborted = true; c.forceCancel() }

        func close() {
            guard !aborted else { return }
            c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [c] _ in c.cancel() })
        }
    }
}
