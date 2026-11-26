import Foundation

/// 回看: builds the replay address of a programme from a live address and a `catchup` template. Times are epoch milliseconds.
struct Catchup: Hashable {
    var type: String
    var source: String
    var days = 0
    var replace = ""

    func toJSON() -> JSONObject { JSONObject().put("type", type).put("source", source).put("days", days).put("replace", replace) }

    static func fromJSON(_ o: JSONObject) -> Catchup? {
        let c = Catchup(type: o.string("type").lowercased(), source: o.string("source"), days: J.int(o["days"]), replace: o.string("replace"))
        return c.usable ? c : nil
    }

    var usable: Bool { !type.isEmpty || !source.isEmpty }

    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// nil when the type is unknown or has nothing to expand.
    func url(_ stream: String, _ start: Int64, _ end: Int64, now: Int64 = Catchup.nowMs, zone: TimeZone = .current) -> String? {
        var base = stream
        if let comma = replace.firstIndex(of: ","), comma > replace.startIndex {
            base = stream.replacingOccurrences(of: String(replace[..<comma]), with: String(replace[replace.index(after: comma)...]), options: .literal)
        }
        let text = Self.expand(source, start, end, now, zone)
        switch type.isEmpty ? (source.hasPrefixIgnoringCase("http") ? "default" : "append") : type {
        case "default":
            if text.isEmpty { return nil }
            return text.contains("://") ? text : Self.append(base, text)
        case "append":
            return text.isEmpty ? nil : Self.append(base, text)
        case "shift", "timeshift":
            let t = text.nonEmptyOr("utc=\(start / 1000)&lutc=\(now / 1000)")
            return Self.append(base, t.hasPrefix("?") || t.hasPrefix("&") ? t : "?" + t)
        case "flussonic", "flussonic-hls", "fs", "flussonic-ts":
            return Self.flussonic(base, start, end, type == "flussonic-ts")
        case "xc":
            return Self.xtream(base, start, end, zone)
        default:
            if text.isEmpty { return nil }
            return text.contains("://") ? text : Self.append(base, text)
        }
    }

    private static func append(_ base: String, _ tail: String) -> String {
        if tail.hasPrefix("?") && base.contains("?") { return base + "&" + tail.dropFirst() }
        if tail.hasPrefix("&") && !base.contains("?") { return base + "?" + tail.dropFirst() }
        return base + tail
    }

    private static func flussonic(_ base: String, _ start: Int64, _ end: Int64, _ ts: Bool) -> String {
        let q = base.substringAfter("?", "")
        let query = q.isEmpty ? "" : "?" + q
        let path = base.substringBefore("?")
        let dir = path.substringBeforeLast("/"), file = path.substringAfterLast("/")
        let from = start / 1000
        if ts || file == "mpegts" { return "\(dir)/timeshift_abs-\(from).ts\(query)" }
        return "\(dir)/\(file.substringBeforeLast("."))-\(from)-\((end - start) / 1000).\(file.substringAfterLast(".", "m3u8"))\(query)"
    }

    private static let xc = TVBoxRegex("^(https?://[^/]+)/(?:live/)?([^/]+)/([^/]+)/([^/]+?)(\\.[^/.]+)?$")
    private static func xtream(_ base: String, _ start: Int64, _ end: Int64, _ zone: TimeZone) -> String? {
        guard let g = xc.match(base)?.groups else { return nil }
        let at = format("yyyy-MM-dd:HH-mm", start, zone)
        return "\(g[1])/timeshift/\(g[2])/\(g[3])/\((end - start) / 60_000)/\(at)/\(g[4])\(g[5].nonEmptyOr(".ts"))"
    }

    /// Carrier IPTV lists without any template: `/PLTV/` streams replay through `/TVOD/`.
    static func implied(_ stream: String) -> Catchup? {
        stream.contains("/PLTV/") ? Catchup(type: "append", source: "?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}", days: 7, replace: "/PLTV/,/TVOD/") : nil
    }

    private static let tokenRe = TVBoxRegex("\\$?\\{([^{}]+)\\}")

    static func expand(_ template: String, _ start: Int64, _ end: Int64, _ now: Int64, _ zone: TimeZone) -> String {
        guard template.contains("{") else { return template }
        return tokenRe.replace(template) { m in token(m.groups[1].trimmed, start, end, now, zone) ?? m.groups[0] }
    }

    private static func token(_ t: String, _ start: Int64, _ end: Int64, _ now: Int64, _ zone: TimeZone) -> String? {
        if t.hasPrefix("(b)") { return stamp(String(t.dropFirst(3)), start, zone) }
        if t.hasPrefix("(e)") { return stamp(String(t.dropFirst(3)), end, zone) }
        let name = t.substringBefore(":"), arg = t.substringAfter(":", "")
        func scaled(_ seconds: Int64) -> String {
            let by = Int64(arg) ?? 1
            return String(seconds / (by > 0 ? by : 1))
        }
        func point(_ at: Int64) -> String { arg.isEmpty ? String(at / 1000) : kodi(arg, at, zone) }
        switch name {
        case "utc", "start", "timestamp", "utcstart": return point(start)
        case "utcend", "end": return point(end)
        case "lutc", "now": return point(now)
        case "duration": return scaled((end - start) / 1000)
        case "offset": return scaled((now - start) / 1000)
        case "Y", "m", "d", "H", "M", "S": return kodi(name, start, zone)
        default: return nil
        }
    }

    /// `yyyyMMddHHmmss`, `yyyyMMddHHmmss|UTC`, `timestamp`, `unix`.
    private static func stamp(_ spec: String, _ at: Int64, _ zone: TimeZone) -> String {
        var f = spec
        let l = spec.lowercased()
        let utc = l.hasSuffix("|utc") || l.hasSuffix(":utc")
        if utc { f = String(f.dropLast(4)) }
        if f == "timestamp" || f == "unix" || f == "utc" { return String(at / 1000) }
        return format(f, at, utc ? TimeZone(secondsFromGMT: 0) ?? zone : zone)
    }

    private static func kodi(_ spec: String, _ at: Int64, _ zone: TimeZone) -> String {
        let map: [Character: String] = ["Y": "yyyy", "m": "MM", "d": "dd", "H": "HH", "M": "mm", "S": "ss"]
        return spec.map { c in map[c].map { format($0, at, zone) } ?? String(c) }.joined()
    }

    static func format(_ pattern: String, _ at: Int64, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = pattern
        return f.string(from: Date(timeIntervalSince1970: Double(at) / 1000))
    }
}
