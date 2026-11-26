import CommonCrypto
import Compression
import Foundation

/// Failure with a complete, readable sentence (no "上游错误：" style prefix).
struct TVBoxError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A request or file failure: shown behind the site's name.
struct TVBoxIOError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Kotlin-style cuts on literal separators.
extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func substringBefore(_ sep: String, _ missing: String? = nil) -> String {
        guard let r = range(of: sep, options: .literal) else { return missing ?? self }
        return String(self[..<r.lowerBound])
    }

    func substringAfter(_ sep: String, _ missing: String? = nil) -> String {
        guard let r = range(of: sep, options: .literal) else { return missing ?? self }
        return String(self[r.upperBound...])
    }

    func substringBeforeLast(_ sep: String, _ missing: String? = nil) -> String {
        guard let r = range(of: sep, options: [.literal, .backwards]) else { return missing ?? self }
        return String(self[..<r.lowerBound])
    }

    func substringAfterLast(_ sep: String, _ missing: String? = nil) -> String {
        guard let r = range(of: sep, options: [.literal, .backwards]) else { return missing ?? self }
        return String(self[r.upperBound...])
    }

    /// `split` that keeps empty pieces.
    func pieces(_ sep: String) -> [String] { components(separatedBy: sep) }

    func hasPrefixIgnoringCase(_ p: String) -> Bool {
        var a = utf8.makeIterator()
        for b in p.utf8 {
            guard let c = a.next() else { return false }
            let x = c >= 0x41 && c <= 0x5A ? c + 32 : c, y = b >= 0x41 && b <= 0x5A ? b + 32 : b
            if x != y { return false }
        }
        return true
    }

    func containsIgnoringCase(_ s: String) -> Bool { range(of: s, options: [.caseInsensitive, .literal]) != nil }

    /// Without the BOM and blanks a config text may start with.
    var withoutBOM: String {
        let cut = unicodeScalars.firstIndex { $0 != "\u{FEFF}" && $0 != " " && $0 != "\t" && $0 != "\r" && $0 != "\n" } ?? endIndex
        return String(self[cut...])
    }

    /// Lines without their terminators (`\n`, `\r\n`, `\r`).
    func eachLine(_ body: (String) -> Void) {
        for l in utf8.split(omittingEmptySubsequences: true, whereSeparator: { $0 == 0x0A || $0 == 0x0D }) { body(String(Substring(l))) }
    }
}

/// Compiled expression with group access by value.
struct TVBoxRegex {
    let re: NSRegularExpression
    /// Literal patterns of the app.
    init(_ p: String, _ o: NSRegularExpression.Options = []) { re = try! NSRegularExpression(pattern: p, options: o) }
    /// Patterns that come from a config.
    init?(user p: String, whole: Bool = false) {
        let pattern = whole ? "^(?:" + p + ")$" : p
        if let known = Self.compiled.object(forKey: pattern as NSString) { re = known; return }
        guard let r = try? NSRegularExpression(pattern: pattern) else { return nil }
        Self.compiled.setObject(r, forKey: pattern as NSString)
        re = r
    }
    private static let compiled = NSCache<NSString, NSRegularExpression>()

    private func full(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }

    func test(_ s: String) -> Bool { re.firstMatch(in: s, range: full(s)) != nil }

    func match(_ s: String) -> Match? { re.firstMatch(in: s, range: full(s)).map { Match($0, s) } }
    func all(_ s: String) -> [Match] { re.matches(in: s, range: full(s)).map { Match($0, s) } }

    func replace(_ s: String, _ f: (Match) -> String) -> String {
        var out = ""
        var last = s.startIndex
        for m in all(s) {
            out += s[last..<m.range.lowerBound]
            out += f(m)
            last = m.range.upperBound
        }
        return out + s[last...]
    }

    struct Match {
        let range: Range<String.Index>
        let groups: [String]
        init(_ m: NSTextCheckingResult, _ s: String) {
            range = Range(m.range, in: s) ?? s.startIndex..<s.startIndex
            groups = (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
        }
    }
}

/// Address helpers shared by configs, sites and live lists. Strings stay raw: no re-encoding of what the config author wrote.
enum TVBoxUrl {
    static func isHttp(_ u: String) -> Bool { u.hasPrefixIgnoringCase("http://") || u.hasPrefixIgnoringCase("https://") }
    static func isLocal(_ u: String) -> Bool { u.hasPrefixIgnoringCase("clan://") || u.hasPrefixIgnoringCase("file://") }

    /// `scheme:` in front of an address.
    static func scheme(_ u: String) -> String? {
        var n = 0
        for c in u.utf8 {
            switch c {
            case 0x41...0x5A, 0x61...0x7A: n += 1
            case 0x30...0x39, 0x2B, 0x2E, 0x2D: if n == 0 { return nil }; n += 1
            case 0x3A: return n == 0 ? nil : String(u[..<u.utf8.index(u.startIndex, offsetBy: n + 1)])
            default: return nil
            }
        }
        return nil
    }

    /// `./x` and `../x` against `base`; every other string is returned unchanged.
    static func resolve(_ base: String, _ ref: String) -> String {
        let r = ref.trimmed
        if r.hasPrefix("img+./") || r.hasPrefix("img+../") { return "img+" + resolve(base, String(r.dropFirst(4))) }
        if base.isEmpty || !(r.hasPrefix("./") || r.hasPrefix("../")) { return ref }
        return join(base, r)
    }

    /// Browser-style join (used by scripts, parses and playlists).
    static func join(_ base: String, _ ref: String) -> String {
        let r = ref.trimmed
        if r.isEmpty { return base }
        if base.isEmpty || scheme(r) != nil { return r }
        guard let sch = scheme(base) else { return r }
        if r.hasPrefix("//") { return sch + r }
        let clean = base.substringBefore("#").substringBefore("?")
        let from = clean.range(of: "://", options: .literal)?.upperBound ?? clean.index(clean.startIndex, offsetBy: sch.count)
        let rootEnd = clean[from...].firstIndex(of: "/")
        let root = rootEnd.map { String(clean[..<$0]) } ?? clean
        let path = rootEnd.map { String(clean[$0...]) } ?? "/"
        if r.hasPrefix("?") { return clean + r }
        if r.hasPrefix("#") { return base.substringBefore("#") + r }
        let cut = r.firstIndex { $0 == "?" || $0 == "#" } ?? r.endIndex
        let tail = String(r[cut...]), rel = String(r[..<cut])
        var segs: [String] = []
        if !rel.hasPrefix("/") { segs = path.substringBeforeLast("/").pieces("/").filter { !$0.isEmpty } }
        let parts = rel.pieces("/")
        for (i, p) in parts.enumerated() {
            if p == ".." { _ = segs.popLast() }
            else if p == "." || (p.isEmpty && i < parts.count - 1) { continue }
            else { segs.append(p) }
        }
        let dir = (parts.last == "." || parts.last == "..") && !segs.isEmpty
        return root + "/" + segs.joined(separator: "/") + (dir ? "/" : "") + tail
    }

    /// Resolves `./` and `../` strings inside a parsed config (nested `ext` objects included). Objects change in place.
    @discardableResult
    static func resolveTree(_ v: Any, _ base: String) -> Any {
        switch v {
        case let s as String: return resolve(base, s)
        case let o as JSONObject:
            for k in o.keys {
                guard let x = o[k] else { continue }
                if let s = x as? String {
                    let r = resolve(base, s)
                    if r != s { o.put(k, r) }
                } else if x is [Any] { o.put(k, resolveTree(x, base)) }
                else if x is JSONObject { resolveTree(x, base) }
            }
            return o
        case let a as [Any]: return a.map { resolveTree($0, base) }
        default: return v
        }
    }

    static func host(_ u: String) -> String {
        let h = u.substringAfter("://", "").substringBefore("/").substringBefore("?").substringBefore("#").substringAfterLast("@")
        if h.hasPrefix("[") { return String(h.substringBefore("]").dropFirst()).lowercased() }
        return h.substringBefore(":").lowercased()
    }

    /// File name of an address without query, e.g. `live.txt`.
    static func fileName(_ u: String) -> String {
        var t = u.substringBefore("?").substringBefore("#")
        while t.hasSuffix("/") { t.removeLast() }
        return t.substringAfterLast("/")
    }

    struct Picture: Equatable { let url: String; let headers: [String: String] }

    private static let picMark = TVBoxRegex("@(Referer|User-Agent|Cookie|Headers|Origin)=", .caseInsensitive)

    /// `url@Referer=…@User-Agent=…@Cookie=…@Headers={json}` → address + request headers.
    static func picture(_ raw: String) -> Picture {
        guard raw.contains("@") else {
            let t = raw.trimmed
            return Picture(url: t.hasPrefix("//") ? "https:" + t : t, headers: [:])
        }
        let marks = picMark.all(raw)
        var headers: [String: String] = [:]
        for (i, m) in marks.enumerated() {
            let value = String(raw[m.range.upperBound..<(i + 1 < marks.count ? marks[i + 1].range.lowerBound : raw.endIndex)]).trimmed
            switch m.groups[1].lowercased() {
            case "headers": if let o = LenientJson.objectOrNull(value) { headers.merge(o.strings()) { $1 } }
            case "referer": headers["Referer"] = value
            case "user-agent": headers["User-Agent"] = value
            case "cookie": headers["Cookie"] = value
            default: headers["Origin"] = value
            }
        }
        let u = (marks.first.map { String(raw[..<$0.range.lowerBound]) } ?? raw).trimmed
        return Picture(url: u.hasPrefix("//") ? "https:" + u : u, headers: headers)
    }

    struct Stream: Equatable { let url: String; let headers: [String: String]; let label: String }

    /// `url|User-Agent=…&Referer=…$线路名`
    static func stream(_ raw: String) -> Stream {
        let t = raw.trimmed
        let label = t.contains("$") ? t.substringAfter("$").substringBefore("$").trimmed : ""
        let body = t.substringBefore("$").trimmed
        guard let bar = body.firstIndex(of: "|") else { return Stream(url: body, headers: [:], label: label) }
        return Stream(url: String(body[..<bar]).trimmed, headers: headerQuery(String(body[body.index(after: bar)...])), label: label)
    }

    private static let headerField = TVBoxRegex("^(?:user-?agent|ua|refer+er|origin|cookie|host|authorization|accept[\\w-]*|range|x-[\\w-]+|sec-[\\w-]+|http-[\\w-]+)=", .caseInsensitive)

    /// A play address of a site: `url|User-Agent=…` like in lists, but `$` and other `|` are part of it.
    static func vod(_ raw: String) -> Stream {
        let t = raw.trimmed
        var from = t.startIndex
        while let bar = t[from...].firstIndex(of: "|") {
            from = t.index(after: bar)
            let rest = String(t[from...])
            if headerField.test(rest) { return Stream(url: String(t[..<bar]).trimmed, headers: headerQuery(rest), label: "") }
        }
        return Stream(url: t, headers: [:], label: "")
    }

    static func headerQuery(_ q: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in q.pieces("&") {
            guard let i = pair.firstIndex(of: "="), i > pair.startIndex else { continue }
            out[headerName(String(pair[..<i]))] = decode(String(pair[pair.index(after: i)...]))
        }
        return out
    }

    static func decode(_ s: String) -> String { s.contains("%") ? s.removingPercentEncoding ?? s : s }

    /// Percent-encodes everything but unreserved characters.
    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `base` with the given query parameters set (existing ones of the same name are replaced), fragment dropped.
    static func withQuery(_ base: String, _ q: [(String, String)]) -> String {
        let whole = base.substringBefore("#")
        let names = Set(q.map { $0.0 })
        var parts = whole.substringAfter("?", "").pieces("&").filter { !$0.isEmpty && !names.contains(decode($0.substringBefore("="))) }
        parts += q.map { encode($0.0) + "=" + encode($0.1) }
        return whole.substringBefore("?") + (parts.isEmpty ? "" : "?" + parts.joined(separator: "&"))
    }

    static func headerName(_ raw: String) -> String {
        let k = raw.trimmed.lowercased()
        switch k {
        case "ua", "useragent", "user-agent", "http-user-agent": return "User-Agent"
        case "referer", "referrer", "http-referrer", "http-referer": return "Referer"
        case "origin", "http-origin": return "Origin"
        case "cookie", "http-cookie": return "Cookie"
        case "host": return "Host"
        case "authorization": return "Authorization"
        default: return raw.trimmed
        }
    }

    private static let media = TVBoxRegex("^https?://\\S{8,}?\\.(?:m3u8|mp4|mkv|flv|mp3|m4a|aac|mpd|avi|mov|wmv|webm|rmvb|m4v)(?:[?#&/]\\S*)?$", .caseInsensitive)
    private static let tos = TVBoxRegex("^https?://\\S*?(?:video|obj)/tos\\S*", .caseInsensitive)
    private static let page = ["url=http", "v=http", "url=https%3a", "url=http%3a", ".css", ".html", ".js?", ".htm?"]

    /// Media address by shape only (no request): the sniffer's base rule and the direct-play check.
    static func isVideo(_ u: String) -> Bool {
        let l = u.lowercased()
        if l.hasPrefix("rtmp:") || l.hasPrefix("rtsp:") || l.hasPrefix("rtp:") || l.hasPrefix("udp:") || l.hasPrefix("mms:") { return true }
        if page.contains(where: { l.contains($0) }) || l.hasSuffix(".js") || l.hasSuffix(".htm") { return false }
        return media.test(u) || tos.test(u)
    }

    private static let p2pSchemes: Set<String> = ["thunder", "ed2k", "magnet", "tvbus", "jianpian", "force", "p2p", "mitv", "p3p", "p5p", "p6p", "p7p", "p8p", "p9p", "flashget", "qqdl"]
    /// P2P schemes need closed-source native libraries; neither platform supports them.
    static func p2p(_ u: String) -> String? {
        let s = u.substringBefore(":").lowercased()
        return p2pSchemes.contains(s) ? s : nil
    }

    // MARK: Request URLs

    struct Target { let url: URL; let host: String; let user: String?; let password: String? }

    /// A raw http(s) address as browsers read it: IDN hosts in punycode, illegal characters percent-encoded, credentials apart.
    static func target(_ raw: String) -> Target? {
        let t = raw.trimmed
        guard isHttp(t), let sep = t.range(of: "://", options: .literal) else { return nil }
        let rest = t[sep.upperBound...]
        let cut = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" || $0 == "\\" } ?? rest.endIndex
        var authority = String(rest[..<cut])
        var tail = String(rest[cut...]).substringBefore("#")
        var user: String?, password: String?
        if let at = authority.lastIndex(of: "@") {
            let info = String(authority[..<at])
            authority = String(authority[authority.index(after: at)...])
            user = decode(info.substringBefore(":"))
            password = decode(info.substringAfter(":", ""))
        }
        var port = ""
        if let colon = authority.lastIndex(of: ":"), !authority[colon...].contains("]") {
            port = String(authority[authority.index(after: colon)...])
            authority = String(authority[..<colon])
            guard port.isEmpty || (Int(port).map { $0 > 0 && $0 < 65_536 } ?? false) else { return nil }
        }
        guard let host = asciiHost(authority) else { return nil }
        if tail.hasPrefix("\\") { tail = "/" + tail.dropFirst() }
        if !tail.hasPrefix("/") { tail = "/" + tail }
        let scheme = t[..<sep.lowerBound].lowercased()
        guard let url = URL(string: scheme + "://" + host + (port.isEmpty ? "" : ":" + port) + legal(tail)) else { return nil }
        return Target(url: url, host: host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host, user: user, password: password)
    }

    static func url(_ raw: String) -> URL? { target(raw)?.url }

    private static func legal(_ tail: String) -> String {
        let b = Array(tail.utf8)
        var out = ""
        out.reserveCapacity(b.count)
        var path = true
        var i = 0
        func hex(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
        while i < b.count {
            let c = b[i]
            let keep: Bool
            switch c {
            case 0x25: keep = i + 2 < b.count && hex(b[i + 1]) && hex(b[i + 2])
            case 0x3F: keep = true; path = false
            case 0x5C: keep = false
            case 0x21, 0x24, 0x26...0x3B, 0x3D, 0x40...0x5A, 0x5F, 0x61...0x7A, 0x7E: keep = true
            default: keep = false
            }
            if keep { out.unicodeScalars.append(UnicodeScalar(c)) }
            else if c == 0x5C && path { out += "/" }
            else { out += String(format: "%%%02X", c) }
            i += 1
        }
        return out
    }

    private static let forbidden = Set("/?#@\\%[]:<>^|\u{7F}".utf8)

    private static func asciiHost(_ raw: String) -> String? {
        let h = decode(raw)
        if h.isEmpty { return nil }
        if h.hasPrefix("[") { return h.hasSuffix("]") && h.utf8.allSatisfy({ $0 < 0x80 }) ? h.lowercased() : nil }
        let labels = h.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "\u{3002}", with: ".").replacingOccurrences(of: "\u{FF0E}", with: ".").replacingOccurrences(of: "\u{FF61}", with: ".").pieces(".")
        var out: [String] = []
        for l in labels {
            if l.utf8.allSatisfy({ $0 < 0x80 }) {
                guard !l.utf8.contains(where: { $0 <= 0x20 || forbidden.contains($0) }) else { return nil }
                out.append(l)
            } else {
                guard let p = Punycode.encode(l) else { return nil }
                out.append("xn--" + p)
            }
        }
        return out.joined(separator: ".")
    }
}

/// RFC 3492 (Foundation only encodes IDN hosts from iOS 17 on).
enum Punycode {
    static func encode(_ label: String) -> String? {
        let input = label.unicodeScalars.map { $0.value }
        var out = input.filter { $0 < 0x80 }
        let basic = out.count
        var handled = basic
        if basic > 0 { out.append(0x2D) }
        var n: UInt32 = 128, delta: UInt32 = 0, bias: UInt32 = 72
        while handled < input.count {
            guard let m = input.filter({ $0 >= n }).min() else { return nil }
            let (d, over) = (m - n).multipliedReportingOverflow(by: UInt32(handled + 1))
            if over || delta &+ d < delta { return nil }
            delta += d
            n = m
            for c in input {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta, k: UInt32 = 36
                    while true {
                        let t = k <= bias ? 1 : min(26, k - bias)
                        if q < t { break }
                        out.append(digit(t + (q - t) % (36 - t)))
                        q = (q - t) / (36 - t)
                        k += 36
                    }
                    out.append(digit(q))
                    delta = handled == basic ? delta / 700 : delta / 2
                    delta += delta / UInt32(handled + 1)
                    var b: UInt32 = 0
                    while delta > 455 { delta /= 35; b += 36 }
                    bias = b + 36 * delta / (delta + 38)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(String.UnicodeScalarView(out.compactMap { UnicodeScalar($0) }))
    }

    private static func digit(_ d: UInt32) -> UInt32 { d < 26 ? d + 0x61 : d - 26 + 0x30 }
}

/// `spider` / `jar` value: `url;md5;hash`, `img+url`.
struct SpiderRef: Hashable {
    let url: String
    let md5: String
    let image: Bool
    var isEmpty: Bool { url.isEmpty }
    /// Identity of the downloaded file.
    var id: String { Bytes.hex(Bytes.md5("\(url);\(md5);\(image)")) }

    static func parse(_ raw: String) -> SpiderRef {
        let t = raw.trimmed
        let image = t.hasPrefixIgnoringCase("img+")
        let body = image ? String(t.dropFirst(4)) : t
        let sum = body.substringAfter(";md5;", "").trimmed.substringBefore(";")
        return SpiderRef(url: body.substringBefore(";md5;").trimmed, md5: sum.hasPrefixIgnoringCase("http") ? sum : sum.lowercased(), image: image)
    }
}

/// Config text as delivered: plain, Base64 behind `xxxxxxxx**` (also inside images), AES-CBC hex (`2423…`), AES-ECB with a key.
enum TVBoxDecoder {
    /// Splits `address;pk;key`.
    static func splitKey(_ url: String) -> (String, String) {
        guard let r = url.range(of: ";pk;", options: .literal) else { return (url.trimmed, "") }
        return (String(url[..<r.lowerBound]).trimmed, String(url[r.upperBound...]).trimmed)
    }

    static func decode(_ data: Data, _ key: String = "") throws -> String {
        var raw = [UInt8](data)
        if raw.count > 2 && raw[0] == 0x1F && raw[1] == 0x8B { raw = [UInt8](try TVBoxGzip.decompress(data)) }
        let t = text(raw)
        if looksPlain(t) { return t }
        // an image carrier is not valid UTF-8: the marker is searched byte for byte
        return try decode(markEnd(raw) != nil ? raw : Array(t.utf8), t, key)
    }

    static func decode(_ text: String, _ key: String = "") throws -> String {
        looksPlain(text) ? text : try decode(Array(text.utf8), text, key)
    }

    private static func decode(_ bytes: [UInt8], _ whole: String, _ key: String) throws -> String {
        var data = whole
        if let end = markEnd(bytes), let b = base64(bytes[end...]) {
            if looksImage(b) { return try decode(Data(b), key) }
            data = text(b)
        }
        let compact = data.trimmed
        if compact.hasPrefix("2423"), isHex(compact) { return try cbc(compact.filter { !$0.isWhitespace }) }
        if !key.isEmpty && !looksPlain(data) { return try ecb(compact, key) }
        return data
    }

    /// Bytes hidden in an image (`img+` spiders): Base64 behind the marker, or appended after the image data.
    static func carried(_ data: Data) -> Data? {
        let b = [UInt8](data)
        return markEnd(b).flatMap { base64(b[$0...]) }.map { Data($0) }
    }

    /// Index behind the first `[A-Za-z0-9]{8}\*\*`.
    private static func markEnd(_ b: [UInt8]) -> Int? {
        var run = 0, i = 0
        while i < b.count {
            let c = b[i]
            if (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) { run += 1 }
            else {
                if c == 0x2A, run >= 8, i + 1 < b.count, b[i + 1] == 0x2A { return i + 2 }
                run = 0
            }
            i += 1
        }
        return nil
    }

    private static func looksPlain(_ t: String) -> Bool {
        let c = t.withoutBOM
        return c.hasPrefix("{") || c.hasPrefix("[") || c.hasPrefix("//") || c.hasPrefix("/*") || c.hasPrefix("#") || c.hasPrefix("<")
    }

    private static func looksImage(_ b: [UInt8]) -> Bool { b.count > 3 && ((b[0] == 0xFF && b[1] == 0xD8) || (b[0] == 0x89 && b[1] == 0x50)) }

    static func text(_ b: [UInt8]) -> String {
        let d = Data(b)
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: TextDecode.gb18030) ?? String(decoding: b, as: UTF8.self)
    }

    /// Tolerant Base64: foreign characters skipped, URL-safe alphabet, padding optional.
    static func base64<S: Sequence>(_ s: S) -> [UInt8]? where S.Element == UInt8 {
        var out: [UInt8] = []
        var acc: UInt32 = 0, bits = 0
        for c in s {
            let v: UInt32
            switch c {
            case 0x41...0x5A: v = UInt32(c - 0x41)
            case 0x61...0x7A: v = UInt32(c - 0x47)
            case 0x30...0x39: v = UInt32(c) + 4
            case 0x2B, 0x2D: v = 62
            case 0x2F, 0x5F: v = 63
            case 0x3D: return out.isEmpty ? nil : out
            default: continue
            }
            acc = acc << 6 | v
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(acc >> UInt32(bits) & 0xFF))
            }
        }
        return out.isEmpty ? nil : out
    }

    static func base64(_ s: String) -> Data? { base64(s.utf8).map { Data($0) } }

    private static func isHex(_ s: String) -> Bool { !s.isEmpty && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) || $0 == 0x20 || ($0 >= 0x09 && $0 <= 0x0D) } }

    private static func pad16(_ s: String) -> String { s.utf8.count >= 16 ? s : s + String(repeating: "0", count: 16 - s.utf8.count) }

    private static func hex(_ s: String) throws -> [UInt8] {
        guard let b = Bytes.fromHex(s) else { throw LenientJson.Malformed("配置密文不是有效的十六进制") }
        return b
    }

    private static func cbc(_ data: String) throws -> String {
        // Latin-1 view of the bytes: key and iv are ASCII
        let raw = try hex(data)
        let plain = String(String.UnicodeScalarView(raw.map { UnicodeScalar($0) })).lowercased()
        let broken = LenientJson.Malformed("配置密文不完整")
        guard let a = plain.range(of: "$#", options: .literal), let b = plain.range(of: "#$", options: .literal), b.lowerBound >= a.upperBound,
              plain.count >= 13, let cut = data.range(of: "2324", options: .literal) else { throw broken }
        let from = data.utf8.distance(from: data.startIndex, to: cut.lowerBound)
        guard data.utf8.count >= from + 30 else { throw broken }
        let key = pad16(String(plain[a.upperBound..<b.lowerBound])), iv = pad16(String(plain.suffix(13)))
        let bytes = Array(data.utf8)
        let body = String(decoding: bytes[(from + 4)..<(bytes.count - 26)], as: UTF8.self)
        return try decrypt(key: key, iv: iv, try hex(body))
    }

    private static func ecb(_ data: String, _ key: String) throws -> String {
        let body: [UInt8]
        if isHex(data) { body = try hex(data.filter { !$0.isWhitespace }) }
        else if let b = base64(data.utf8) { body = b }
        else { throw LenientJson.Malformed("配置密文无法识别") }
        return try decrypt(key: pad16(key), iv: nil, body)
    }

    private static func decrypt(key: String, iv: String?, _ body: [UInt8]) throws -> String {
        let failed = LenientJson.Malformed("配置解密失败，请检查密钥")
        let k = Array(key.utf8), v = iv.map { Array($0.utf8) } ?? []
        guard k.count == 16 || k.count == 24 || k.count == 32, iv == nil || v.count == 16, !body.isEmpty, body.count % 16 == 0 else { throw failed }
        var out = [UInt8](repeating: 0, count: body.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(iv == nil ? kCCOptionECBMode : 0), k, k.count, v, body, body.count, &out, out.count, &moved)
        // CommonCrypto does not report broken PKCS#7 padding: checked here
        guard status == kCCSuccess, moved == body.count, let n = out.last, n >= 1, n <= 16, out.suffix(Int(n)).allSatisfy({ $0 == n }) else { throw failed }
        return String(decoding: out.dropLast(Int(n)), as: UTF8.self)
    }
}

/// gzip (RFC 1952) reading; `Gzip` writes.
enum TVBoxGzip {
    static func decompress(_ d: Data, max: Int = 48 << 20) throws -> Data {
        var at = 0
        let read = try source({ () -> Data? in
            guard at < d.count else { return nil }
            let n = min(64 * 1024, d.count - at)
            let chunk = d.subdata(in: (d.startIndex + at)..<(d.startIndex + at + n))
            at += n
            return chunk
        }, max: max)
        var out = Data()
        while let chunk = try read() { out.append(chunk) }
        return out
    }

    /// Streams the inflated content of `next` (chunks of a gzip file), `max` bytes at most.
    static func source(_ next: @escaping () throws -> Data?, max: Int = 512 << 20) throws -> () throws -> Data? {
        var head = Data()
        func need(_ n: Int) throws {
            while head.count < n {
                guard let c = try next(), !c.isEmpty else { throw TVBoxIOError("gzip 内容不完整") }
                head.append(c)
            }
        }
        try need(10)
        head = Data(head)
        guard head[0] == 0x1F, head[1] == 0x8B else { throw TVBoxIOError("不是 gzip 内容") }
        let flags = head[3]
        var at = 10
        if flags & 4 != 0 {
            try need(at + 2)
            at += 2 + Int(head[at]) + Int(head[at + 1]) << 8
        }
        for bit: UInt8 in [8, 16] where flags & bit != 0 {
            while true {
                try need(at + 1)
                at += 1
                if head[at - 1] == 0 { break }
            }
        }
        if flags & 2 != 0 { at += 2 }
        try need(at)
        var rest: Data? = head.count > at ? Data(head[at...]) : nil
        let filter = try InputFilter<Data>(.decompress, using: .zlib) { (_: Int) throws -> Data? in
            if let r = rest { rest = nil; return r }
            return try next()
        }
        var total = 0
        return {
            guard let chunk = try filter.readData(ofLength: 64 * 1024) else { return nil }
            total += chunk.count
            if total > max { throw TVBoxIOError("内容超过 \(max >> 20) MB") }
            return chunk
        }
    }
}
