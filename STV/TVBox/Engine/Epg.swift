import Foundation

/// Times are epoch milliseconds.
struct Programme: Hashable {
    var start: Int64
    var end: Int64
    var title: String
    var desc = ""
}

enum EpgParser {
    /// `{name}` / `{date}` templates (also `{id}`, `{epg}`).
    static func url(_ template: String, _ name: String, _ date: String, _ id: String = "") -> String {
        template.replacingOccurrences(of: "{name}", with: name).replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{id}", with: id.isEmpty ? name : id).replacingOccurrences(of: "{epg}", with: name)
    }

    static func isTemplate(_ u: String) -> Bool { u.contains("{name}") || u.contains("{date}") || u.contains("{epg}") || u.contains("{id}") }

    /// Guide names differ in spacing, dashes and case: `CCTV-1 综合` ~ `cctv1综合`.
    static func key(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        for u in name.lowercased().unicodeScalars {
            if u.value < 0x80 {
                if (u.value >= 0x30 && u.value <= 0x39) || (u.value >= 0x61 && u.value <= 0x7A) || u == "+" { out.append(u) }
                continue
            }
            switch u.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: out.append(u)
            default: break
            }
        }
        return String(out)
    }

    static func day(_ at: Int64, _ zone: TimeZone = .current) -> String { Catchup.format("yyyy-MM-dd", at, zone) }

    /// Midnight of the day `at` falls on.
    static func midnight(_ at: Int64, _ zone: TimeZone) -> Int64 {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return Int64(c.startOfDay(for: Date(timeIntervalSince1970: Double(at) / 1000)).timeIntervalSince1970 * 1000)
    }

    private static let clock = TVBoxRegex("(\\d{1,2}):(\\d{2})")
    private static let date = TVBoxRegex("(\\d{4})-(\\d{2})-(\\d{2})")

    /// DIYP-style `{"epg_data":[{"title","start":"08:00","end":"09:00"}]}`; end before start runs past midnight.
    static func json(_ text: String, _ day: String, _ zone: TimeZone = .current) -> [Programme] {
        let rows: [Any]
        switch try? LenientJson.parse(text) {
        case let o as JSONObject: rows = ["epg_data", "data", "list", "programs", "epg"].lazy.compactMap { o.optJSONArray($0) }.first ?? []
        case let a as [Any]: rows = a
        default: rows = []
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func at(_ raw: String) -> Int64? {
            let t = raw.trimmed
            // seconds or milliseconds; absurd numbers are no time at all
            if let n = Int64(t) { return n > 10_000_000_000_000 ? nil : n > 100_000_000_000 ? n : n > 1_000_000_000 ? n * 1000 : nil }
            guard let hm = clock.match(t), let h = Int(hm.groups[1]), let m = Int(hm.groups[2]),
                  let d = date.match(t) ?? date.match(day), let y = Int(d.groups[1]), let mo = Int(d.groups[2]), let dd = Int(d.groups[3]),
                  let at = calendar.date(from: DateComponents(year: y, month: mo, day: dd, hour: h, minute: m)) else { return nil }
            return Int64(at.timeIntervalSince1970 * 1000)
        }
        var out: [Programme] = []
        var seen = Set<Programme>()
        for case let p as JSONObject in rows {
            let title = J.firstNonEmpty(p.string("title"), p.string("name"))
            guard let start = at(J.firstNonEmpty(p.string("start"), p.string("start_time"), p.string("startTime"))),
                  var end = at(J.firstNonEmpty(p.string("end"), p.string("end_time"), p.string("endTime"))), !title.isEmpty else { continue }
            if end <= start { end += 86_400_000 }
            if seen.insert(Programme(start: start, end: 0, title: title.trimmed)).inserted { out.append(Programme(start: start, end: end, title: title.trimmed, desc: p.string("desc"))) }
        }
        return out.sorted { $0.start < $1.start }
    }

    private static let maxProgrammes = 300_000

    /// XMLTV, streamed from `next` (chunks of the decompressed document). `wanted` = guide keys to keep (nil = everything);
    /// returns key → programmes inside the window.
    static func xmltv(_ next: @escaping () throws -> Data?, wanted: Set<String>?, from: Int64, to: Int64, zone: TimeZone = .current) throws -> [String: [Programme]] {
        var names: [String: Set<String>] = [:]
        var out: [String: [Programme]] = [:]
        var count = 0
        var channel = ""
        var current: (keys: [String], start: Int64, stop: Int64)?
        var title = "", desc = ""
        var capture: String?
        // a document that breaks off counts as far as it goes
        _ = try? XmlScanner(next).run { event in
            switch event {
            case .start(let name, let attrs):
                switch name {
                case "channel":
                    channel = attrs["id"] ?? ""
                    if names[channel] == nil { names[channel] = [key(channel)] }
                case "display-name": capture = name
                case "programme":
                    let id = attrs["channel"] ?? ""
                    let keys = (names[id] ?? [key(id)]).filter { wanted?.contains($0) ?? true }
                    title = ""
                    desc = ""
                    current = nil
                    if !keys.isEmpty, let a = time(attrs["start"] ?? "", zone), let b = time(attrs["stop"] ?? "", zone), b >= from, a <= to { current = (Array(keys), a, b) }
                case "title", "desc": capture = current == nil ? nil : name
                default: break
                }
            case .text(let s):
                switch capture {
                case "display-name":
                    let n = key(s)
                    if !n.isEmpty { names[channel, default: []].insert(n) }
                case "title": if title.isEmpty { title = s.trimmed }
                case "desc": if desc.isEmpty { desc = String(s.trimmed.prefix(300)) }
                default: break
                }
                capture = nil
            case .end(let name):
                if name == capture { capture = nil }
                if name == "programme", let c = current {
                    if !title.isEmpty, count < maxProgrammes {
                        count += c.keys.count
                        for k in c.keys { out[k, default: []].append(Programme(start: c.start, end: c.stop, title: title, desc: desc)) }
                    }
                    current = nil
                }
            }
        }
        return out.mapValues { list in
            var seen = Set<Int64>()
            return list.filter { seen.insert($0.start).inserted }.sorted { $0.start < $1.start }
        }
    }

    /// `20261125080000 +0800`.
    static func time(_ raw: String, _ zone: TimeZone) -> Int64? {
        let b = Array(raw.trimmed.utf8)
        guard b.count >= 12 else { return nil }
        func num(_ from: Int, _ n: Int) -> Int? {
            var v = 0
            for i in from..<(from + n) {
                guard i < b.count, b[i] >= 0x30, b[i] <= 0x39 else { return nil }
                v = v * 10 + Int(b[i] - 0x30)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2), let h = num(8, 2), let m = num(10, 2) else { return nil }
        var i = 12
        var s = 0
        if let v = num(12, 2) { s = v; i = 14 }
        while i < b.count && b[i] == 0x20 { i += 1 }
        var offset = zone.secondsFromGMT()
        var fixed = false
        if i < b.count, b[i] == 0x5A { offset = 0; fixed = true }
        else if i < b.count, b[i] == 0x2B || b[i] == 0x2D, let zh = num(i + 1, 2) {
            let k = i + 3 < b.count && b[i + 3] == 0x3A ? i + 4 : i + 3
            if let zm = num(k, 2) { offset = (zh * 3600 + zm * 60) * (b[i] == 0x2D ? -1 : 1); fixed = true }
        }
        let utc = days(y, mo, d) * 86_400 + h * 3600 + m * 60 + s
        if !fixed { offset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(utc - offset))) }
        return Int64(utc - offset) * 1000
    }

    /// Days since 1970-01-01 (proleptic Gregorian).
    private static func days(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let shifted = month > 2 ? month - 3 : month + 9
        let doy = (153 * shifted + 2) / 5 + day - 1
        let leaps = yoe / 4 - yoe / 100
        let doe = yoe * 365 + leaps + doy
        return era * 146_097 + doe - 719_468
    }
}

/// Forward-only XML tokenizer for big guide files: constant memory, no DTD processing.
final class XmlScanner {
    enum Event { case start(String, [String: String]), text(String), end(String) }

    private let next: () throws -> Data?
    private var buf: [UInt8] = []
    private var pos = 0
    private var eof = false
    private var encoding: String.Encoding = .utf8

    init(_ next: @escaping () throws -> Data?) { self.next = next }

    /// Text runs are delivered once per run of character data (CDATA joined to its neighbours), blank runs skipped.
    func run(_ emit: (Event) -> Void) throws {
        var text: [UInt8] = []
        func flush() {
            guard text.contains(where: { $0 > 0x20 }) else { text.removeAll(keepingCapacity: true); return }
            emit(.text(string(text)))
            text.removeAll(keepingCapacity: true)
        }
        while true {
            guard let lt = try find([0x3C]) else { break }
            if lt > pos { text.append(contentsOf: entities(buf[pos..<lt])) }
            pos = lt
            if try starts("<![CDATA[") {
                pos += 9
                guard let e = try find(Array("]]>".utf8)) else { break }
                text.append(contentsOf: buf[pos..<e])
                pos = e + 3
                continue
            }
            if try starts("<!--") {
                guard let e = try find(Array("-->".utf8)) else { break }
                pos = e + 3
                continue
            }
            flush()
            if try starts("<!") {
                // a DOCTYPE may carry an internal subset in brackets
                guard let e = try find([0x3E]) else { break }
                if buf[pos..<e].contains(0x5B), let close = try find(Array("]>".utf8)) { pos = close + 2 } else { pos = e + 1 }
                continue
            }
            guard let gt = try tagEnd() else { break }
            let tag = Array(buf[(pos + 1)..<gt])
            pos = gt + 1
            guard let c = tag.first else { continue }
            if c == 0x3F {
                let s = String(decoding: tag, as: UTF8.self)
                if s.hasPrefix("?xml"), let e = TextDecode.charset(Self.attributes(Array(s.utf8), 4) { String(decoding: $0, as: UTF8.self) }["encoding"]) { encoding = e }
            } else if c == 0x2F {
                emit(.end(String(decoding: tag.dropFirst(), as: UTF8.self).trimmed))
            } else {
                var n = 0
                while n < tag.count, tag[n] > 0x20, tag[n] != 0x2F { n += 1 }
                let name = String(decoding: tag[0..<n], as: UTF8.self)
                emit(.start(name, Self.attributes(tag, n) { string(entities($0)) }))
                if tag.last == 0x2F { emit(.end(name)) }
            }
        }
        flush()
    }

    private func string(_ b: [UInt8]) -> String {
        encoding == .utf8 ? String(decoding: b, as: UTF8.self) : TextDecode.lossy(Data(b), encoding)
    }

    private func fill() throws -> Bool {
        if eof { return false }
        guard let d = try next(), !d.isEmpty else { eof = true; return false }
        if pos > 0 { buf.removeFirst(pos); pos = 0 }
        buf.append(contentsOf: d)
        return true
    }

    private func starts(_ s: String) throws -> Bool {
        let p = Array(s.utf8)
        while buf.count - pos < p.count { if try !fill() { return false } }
        for i in 0..<p.count where buf[pos + i] != p[i] { return false }
        return true
    }

    /// Index of the next occurrence at or behind `pos` (which may move to the front of the buffer).
    private func find(_ p: [UInt8]) throws -> Int? {
        var rel = 0
        while true {
            let from = pos + rel
            let (hit, i) = buf.withUnsafeBufferPointer { b -> (Bool, Int) in
                var i = from
                let last = b.count - p.count
                while i <= last {
                    if b[i] == p[0] {
                        var k = 1
                        while k < p.count && b[i + k] == p[k] { k += 1 }
                        if k == p.count { return (true, i) }
                    }
                    i += 1
                }
                return (false, i)
            }
            if hit { return i }
            rel = max(0, i - pos)
            if buf.count - pos > 8 << 20 { throw LenientJson.Malformed("节目单格式异常") }
            if try !fill() { return nil }
        }
    }

    /// `>` of the tag at `pos`, outside quotes.
    private func tagEnd() throws -> Int? {
        var rel = 1
        var quote: UInt8 = 0
        while true {
            let from = pos + rel, open = quote
            let (hit, i, q) = buf.withUnsafeBufferPointer { b -> (Bool, Int, UInt8) in
                var i = from, q = open
                while i < b.count {
                    let c = b[i]
                    if q != 0 { if c == q { q = 0 } }
                    else if c == 0x22 || c == 0x27 { q = c }
                    else if c == 0x3E { return (true, i, q) }
                    i += 1
                }
                return (false, i, q)
            }
            if hit { return i }
            rel = i - pos
            quote = q
            if rel > 8 << 20 { throw LenientJson.Malformed("节目单格式异常") }
            if try !fill() { return nil }
        }
    }

    private static func attributes(_ tag: [UInt8], _ from: Int, _ value: ([UInt8]) -> String) -> [String: String] {
        var out: [String: String] = [:]
        var i = from
        while i < tag.count {
            while i < tag.count, tag[i] <= 0x20 || tag[i] == 0x2F || tag[i] == 0x3F { i += 1 }
            let a = i
            while i < tag.count, tag[i] > 0x20, tag[i] != 0x3D { i += 1 }
            let name = String(decoding: tag[a..<i], as: UTF8.self)
            while i < tag.count, tag[i] <= 0x20 { i += 1 }
            guard i < tag.count, tag[i] == 0x3D else { continue }
            i += 1
            while i < tag.count, tag[i] <= 0x20 { i += 1 }
            guard i < tag.count, tag[i] == 0x22 || tag[i] == 0x27 else { continue }
            let q = tag[i]
            i += 1
            let b = i
            while i < tag.count, tag[i] != q { i += 1 }
            out[name] = value(Array(tag[b..<i]))
            i += 1
        }
        return out
    }

    private func entities(_ s: ArraySlice<UInt8>) -> [UInt8] { entities(Array(s)) }

    private func entities(_ s: [UInt8]) -> [UInt8] {
        guard s.contains(0x26) else { return s }
        var out: [UInt8] = []
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            guard s[i] == 0x26 else { out.append(s[i]); i += 1; continue }
            var e = i + 1
            while e < s.count, e - i < 12, s[e] != 0x3B { e += 1 }
            guard e < s.count, s[e] == 0x3B else { out.append(0x26); i += 1; continue }
            let name = String(decoding: s[(i + 1)..<e], as: UTF8.self)
            var known: String?
            switch name {
            case "amp": known = "&"
            case "lt": known = "<"
            case "gt": known = ">"
            case "quot": known = "\""
            case "apos": known = "'"
            case "nbsp": known = " "
            default:
                if name.hasPrefix("#x") || name.hasPrefix("#X") { known = UInt32(name.dropFirst(2), radix: 16).flatMap { UnicodeScalar($0) }.map { String(Character($0)) } }
                else if name.hasPrefix("#") { known = UInt32(name.dropFirst()).flatMap { UnicodeScalar($0) }.map { String(Character($0)) } }
            }
            if let k = known {
                out.append(contentsOf: encoding == .utf8 ? Array(k.utf8) : Array(k.data(using: encoding) ?? Data(k.utf8)))
                i = e + 1
            } else {
                out.append(0x26)
                i += 1
            }
        }
        return out
    }
}

/// Programme guides with a disk cache: template JSON per channel and day, XMLTV files per address.
final class EpgService {
    /// Unpacked size a guide file may have.
    private static let maxGuide = 512 << 20
    private static let keep: TimeInterval = 3 * 3600
    private static let retry: TimeInterval = 5 * 60
    private let dir: URL
    private let lock = NSLock()
    private var days: [String: [Programme]] = [:]
    private var guides: [String: (at: Date, map: [String: [Programme]])] = [:]
    private var running: [String: Task<[Programme], Error>] = [:]
    private var building: [String: Task<[String: [Programme]], Error>] = [:]

    init(_ dir: URL) { self.dir = dir }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    func programmes(_ http: TVBoxHttp, _ epg: String, _ ch: LiveChannel, _ channels: Set<String>, _ at: Int64, _ zone: TimeZone) async throws -> [Programme] {
        for source in epg.pieces(",").map(\.trimmed) where source.contains("://") {
            do {
                let list = try await EpgParser.isTemplate(source) ? day(http, source, ch, at, zone) : xml(http, source, ch, channels, at, zone)
                if !list.isEmpty { return list }
            } catch {
                try Task.checkCancellation()
            }
        }
        return []
    }

    private func day(_ http: TVBoxHttp, _ template: String, _ ch: LiveChannel, _ at: Int64, _ zone: TimeZone) async throws -> [Programme] {
        let date = EpgParser.day(at, zone)
        let url = EpgParser.url(template, ch.guideName, date, ch.tvgId)
        let task = locked { () -> Task<[Programme], Error> in
            if let known = days[url] { return Task { known } }
            if let t = running[url] { return t }
            let t = Task.detached(priority: .utility) { [self] in
                defer { locked { running[url] = nil } }
                let list = try await loadDay(http, url, date, zone)
                locked {
                    if days.count > 600 { days.removeAll() }
                    days[url] = list
                }
                return list
            }
            running[url] = t
            return t
        }
        return try await task.value
    }

    private func loadDay(_ http: TVBoxHttp, _ url: String, _ date: String, _ zone: TimeZone) async throws -> [Programme] {
        let file = dir.appendingPathComponent("d-" + Bytes.hex(Bytes.md5(url)))
        let today = date == EpgParser.day(Catchup.nowMs, zone)
        if isFresh(file, today ? 2 * 3600 : 24 * 3600), let d = try? Data(contentsOf: file) {
            let list = EpgParser.json(String(decoding: d, as: UTF8.self), date, zone)
            if !list.isEmpty { return list }
        }
        let r = try await http.fetch(NetRequest(url: url, timeoutMs: 8_000))
        if !r.ok { throw TVBoxIOError("HTTP \(r.code)") }
        let text = r.text()
        let list = EpgParser.json(text, date, zone)
        if !list.isEmpty { write(file, Data(text.utf8)) }
        return list
    }

    private func xml(_ http: TVBoxHttp, _ url: String, _ ch: LiveChannel, _ channels: Set<String>, _ at: Int64, _ zone: TimeZone) async throws -> [Programme] {
        let map = try await guide(http, url, channels, zone)
        for k in [ch.tvgId, ch.tvgName, ch.name].map(EpgParser.key) where !k.isEmpty {
            guard let all = map[k], !all.isEmpty else { continue }
            let from = EpgParser.midnight(at, zone)
            return all.filter { $0.end > from && $0.start < from + 86_400_000 }
        }
        return []
    }

    private func guide(_ http: TVBoxHttp, _ url: String, _ channels: Set<String>, _ zone: TimeZone) async throws -> [String: [Programme]] {
        let id = "\(url)|\(channels.count)|\(channels.hashValue)"
        let task = locked { () -> Task<[String: [Programme]], Error> in
            if let g = guides[id], Date().timeIntervalSince(g.at) < Self.keep { return Task { g.map } }
            if let t = building[id] { return t }
            let t = Task<[String: [Programme]], Error>.detached(priority: .utility) { [self] in
                defer { locked { building[id] = nil } }
                let map = (try? await loadGuide(http, url, channels, zone)) ?? [:]
                locked {
                    if guides.count > 3 { guides.removeAll() }
                    // nothing usable: asked for again soon, but not once per channel
                    guides[id] = (map.isEmpty ? Date().addingTimeInterval(Self.retry - Self.keep) : Date(), map)
                }
                return map
            }
            building[id] = t
            return t
        }
        return try await task.value
    }

    private func loadGuide(_ http: TVBoxHttp, _ url: String, _ channels: Set<String>, _ zone: TimeZone) async throws -> [String: [Programme]] {
        let file = dir.appendingPathComponent("x-" + Bytes.hex(Bytes.md5(url)))
        if !isFresh(file, 6 * 3600) {
            do {
                let r = try await http.fetch(NetRequest(url: url, timeoutMs: 45_000, maxBytes: 60 << 20))
                guard r.ok, Self.isGuide(r.body) else { throw TVBoxIOError("节目单 HTTP \(r.code)") }
                write(file, r.body)
            } catch {
                if !FileManager.default.fileExists(atPath: file.path) { throw error }
            }
        }
        guard let source = try Self.open(file) else { return [:] }
        let now = Catchup.nowMs
        return try EpgParser.xmltv(source, wanted: channels, from: now - 7 * 86_400_000, to: now + 2 * 86_400_000, zone: zone)
    }

    /// gzip or XML, not the web page of an overloaded host.
    static func isGuide(_ d: Data) -> Bool {
        if d.starts(with: [0x1F, 0x8B]) { return true }
        let head = String(decoding: d.prefix(1024), as: UTF8.self).lowercased()
        return (head.contains("<?xml") || head.contains("<tv")) && !head.contains("<html")
    }

    /// Chunks of a (possibly gzipped) file.
    private static func open(_ file: URL) throws -> (() throws -> Data?)? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        let head = try h.read(upToCount: 2) ?? Data()
        try h.seek(toOffset: 0)
        let raw: () throws -> Data? = { try autoreleasepool { try h.read(upToCount: 64 * 1024) } }
        if head.elementsEqual([0x1F, 0x8B]) { return try TVBoxGzip.source(raw, max: maxGuide) }
        return raw
    }

    private func isFresh(_ file: URL, _ maxAge: TimeInterval) -> Bool {
        guard let at = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(at) < maxAge
    }

    private func write(_ file: URL, _ d: Data) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let all = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]), all.count > 800 {
            let aged = all.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            for (f, _) in aged.sorted(by: { $0.1 < $1.1 }).prefix(300) { try? fm.removeItem(at: f) }
        }
        try? d.write(to: file, options: .atomic)
    }

    /// (now, next) at `at`.
    static func nowNext(_ list: [Programme], _ at: Int64) -> (now: Programme?, next: Programme?) {
        if let i = list.firstIndex(where: { at >= $0.start && at < $0.end }) { return (list[i], i + 1 < list.count ? list[i + 1] : nil) }
        return (nil, list.first { $0.start > at })
    }
}
