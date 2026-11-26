import Foundation

struct LiveChannel: Hashable {
    var name: String
    var urls: [String]
    var logo = ""
    var tvgId = ""
    var tvgName = ""
    var headers: [String: String] = [:]
    var epg = ""
    var catchup: Catchup? = nil
    var format = ""
    /// Web page addresses that need the sniffer (`parse=1`), plus the script it runs.
    var parse = false
    var click = ""
    /// `inputstream.adaptive` DRM hints, passed through untouched.
    var drm: [String: String] = [:]

    /// Name programme guides are matched by.
    var guideName: String { tvgName.isEmpty ? name : tvgName }

    func mediaJSON(_ defaults: [String: String] = [:], _ epgUrl: String = "", _ fallbackCatchup: Catchup? = nil) -> String {
        let o = JSONObject()
        o.put("urls", urls)
        o.put("headers", JSONObject(defaults.merging(headers) { $1 }))
        o.put("logo", logo).put("tvgId", tvgId).put("tvgName", tvgName)
        o.put("epg", epg.isEmpty ? epgUrl : epg)
        o.put("catchup", (catchup ?? fallbackCatchup)?.toJSON() ?? JSONObject())
        if !format.isEmpty { o.put("format", format) }
        if parse { o.put("parse", 1) }
        if !click.isEmpty { o.put("click", click) }
        if !drm.isEmpty { o.put("drm", JSONObject(drm)) }
        return o.toString()
    }
}

struct LiveGroup: Hashable {
    var name: String
    var pass: String
    var channels: [LiveChannel]
}

struct LiveList: Equatable {
    var groups: [LiveGroup]
    var epg = ""
    var catchup: Catchup? = nil

    var channels: [LiveChannel] { groups.flatMap(\.channels) }
}

/// A channel independent of its place: lists are downloaded again and reordered.
struct ChannelKey: Hashable {
    let group: String
    let name: String
    /// First address, "" when unknown.
    let url: String

    init(group: String, name: String, url: String) { self.group = group; self.name = name; self.url = url }
    init(_ e: HGEpisode) { self.init(group: e.page ?? "", name: e.title, url: Self.address(e)) }

    private static func address(_ e: HGEpisode) -> String {
        guard let o = e.media.flatMap({ LenientJson.objectOrNull($0) }) else { return "" }
        return J.arr(o["urls"]).first.map { J.str($0) } ?? ""
    }

    /// Group and name (the name alone when the group is gone); among several the address, then the place `near`. nil = gone.
    func index(in list: [HGEpisode], near: Int? = nil) -> Int? {
        if name.isEmpty { return nil }
        let named = list.indices.filter { list[$0].title == name }
        let same = group.isEmpty ? named : named.filter { list[$0].page == group }
        let best = same.isEmpty ? named : same
        if best.count > 1, !url.isEmpty, let i = best.first(where: { Self.address(list[$0]) == url }) { return i }
        return near.flatMap { best.contains($0) ? $0 : nil } ?? best.first
    }
}

/// TXT / M3U / JSON channel lists → groups of channels with merged lines. Nothing is fetched here.
enum LiveParser {
    private static let entry = TVBoxRegex("^[^\\r\\n,\\{\\[\"<]{1,100},\\s*[A-Za-z0-9]{2,12}://", .anchorsMatchLines)
    private static let configKey = TVBoxRegex("[\"'](sites|lives|spider|urls|storeHouse)[\"']\\s*:")
    private static let defaultGroup = "默认分组"

    static func looksLikeList(_ text: String) -> Bool {
        let t = text.withoutBOM
        if t.hasPrefixIgnoringCase("#EXTM3U") || t.hasPrefixIgnoringCase("#EXTINF") { return true }
        if t.hasPrefix("{") || t.hasPrefix("[") || t.hasPrefix("<") { return false }
        // a config may open with comment lines that look like `name,address` rows
        for raw in t.utf8.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }) {
            let l = String(Substring(raw)).trimmed
            if l.isEmpty || l.hasPrefix("//") || l.hasPrefix("/*") || (l.hasPrefix("#") && !l.hasPrefixIgnoringCase("#EXT")) { continue }
            if l.hasPrefix("{") || l.hasPrefix("[") { return false }
            break
        }
        if t.contains("{"), configKey.test(t) { return false }
        return t.containsIgnoringCase("#genre#") || entry.test(String(t.prefix(20_000)))
    }

    static func isJsonGroups(_ a: [Any]) -> Bool { a.contains { ($0 as? JSONObject).map { $0.has("channel") || $0.has("channels") } ?? false } }

    static func parse(_ raw: String, skipPass: Bool = false) -> LiveList {
        let t = raw.withoutBOM
        if t.hasPrefix("[") || t.hasPrefix("{") {
            let v = try? LenientJson.parse(t)
            let o = v as? JSONObject
            if let arr = v as? [Any] ?? o?.optJSONArray("groups") ?? o?.optJSONArray("lives") ?? o?.optJSONArray("data") {
                var groups = json(arr)
                if skipPass { for i in groups.indices { groups[i].pass = "" } }
                return LiveList(groups: groups)
            }
        }
        let m3u8 = t.hasPrefixIgnoringCase("#EXTM3U")
        // an HLS media / master playlist pasted as a "list" is a single channel
        if m3u8, t.contains("#EXT-X-STREAM-INF") || t.contains("#EXT-X-TARGETDURATION") { return LiveList(groups: []) }
        return m3u8 || t.containsIgnoringCase("#EXTINF") ? m3u(t) : LiveList(groups: text(t, skipPass))
    }

    /// Insertion-ordered (group, channel) accumulator that merges lines of the same channel.
    private struct Builder {
        private struct Group {
            var name: String
            var pass = ""
            var channels: [LiveChannel] = []
            var index: [String: Int] = [:]
        }
        private var groups: [Group] = []
        private var index: [String: Int] = [:]

        private mutating func slot(_ name: String) -> Int {
            if let i = index[name] { return i }
            groups.append(Group(name: name))
            index[name] = groups.count - 1
            return groups.count - 1
        }

        mutating func group(_ name: String, _ password: String = "") {
            let i = slot(name)
            if !password.isEmpty { groups[i].pass = password }
        }

        mutating func add(_ group: String, _ ch: LiveChannel) {
            let g = slot(group)
            guard let i = groups[g].index[ch.name] else {
                groups[g].index[ch.name] = groups[g].channels.count
                groups[g].channels.append(ch)
                return
            }
            let old = groups[g].channels[i]
            let own = !ch.headers.isEmpty && ch.headers != old.headers
            for u in ch.urls {
                var line = u
                if own, !u.contains("|") {
                    let h = ch.headers.sorted { $0.key < $1.key }.map { $0.key + "=" + TVBoxUrl.encode($0.value) }.joined(separator: "&")
                    line = u.substringBefore("$") + "|" + h + (u.contains("$") ? "$" + u.substringAfter("$") : "")
                }
                if !groups[g].channels[i].urls.contains(line) { groups[g].channels[i].urls.append(line) }
            }
            if old.logo.isEmpty { groups[g].channels[i].logo = ch.logo }
            if old.tvgId.isEmpty { groups[g].channels[i].tvgId = ch.tvgId }
            if old.tvgName.isEmpty { groups[g].channels[i].tvgName = ch.tvgName }
            if old.catchup == nil { groups[g].channels[i].catchup = ch.catchup }
        }

        func build() -> [LiveGroup] { groups.filter { !$0.channels.isEmpty }.map { LiveGroup(name: $0.name, pass: $0.pass, channels: $0.channels) } }
    }

    /// `url#url2` — a '#' only separates when an address follows it.
    private static func splitUrls(_ s: String) -> [String] {
        if !s.contains("#") {
            let t = s.trimmed
            return t.contains("://") ? [t] : []
        }
        var out: [String] = []
        for p in s.pieces("#") {
            if p.contains("://") || out.isEmpty { out.append(p.trimmed) } else { out[out.count - 1] += "#" + p }
        }
        return out.filter { $0.contains("://") }
    }

    private struct Setting {
        var headers: [String: String] = [:]
        var drm: [String: String] = [:]
        var parse = false
        var click = ""
        var format = ""

        /// Directive line (`ua=…`, `#EXTVLCOPT:`, `#KODIPROP:`, `#EXTHTTP:` …).
        mutating func take(_ line: String) -> Bool {
            func value() -> String { line.substringAfter("=").trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            func key(_ prefix: Int) -> String { String(line.dropFirst(prefix)).substringBefore("=").trimmed.lowercased() }
            guard let c = line.unicodeScalars.first else { return false }
            if c == "#" {
                if line.hasPrefixIgnoringCase("#extvlcopt:") {
                    let k = key(11)
                    if ["http-user-agent", "http-referrer", "http-referer", "http-origin", "http-cookie"].contains(k) { headers[TVBoxUrl.headerName(k)] = value() }
                } else if line.hasPrefixIgnoringCase("#exthttp:") {
                    if let o = LenientJson.objectOrNull(String(line.dropFirst(9)).trimmed) { for k in o.keys { headers[TVBoxUrl.headerName(k)] = o.string(k) } }
                } else if line.hasPrefixIgnoringCase("#kodiprop:") {
                    let k = key(10)
                    if k.hasSuffix("stream_headers") || k.hasSuffix("common_headers") || k.hasSuffix("manifest_headers") { headers.merge(TVBoxUrl.headerQuery(value())) { $1 } }
                    else if k.hasSuffix("manifest_type") { format = LiveParser.mime(value()) }
                    else if k.hasSuffix("license_type") { drm["type"] = value() }
                    else if k.hasSuffix("license_key") { drm["key"] = value() }
                    else if k.hasSuffix("drm_legacy") {
                        let p = value().pieces("|")
                        drm["type"] = p[0]
                        if p.count > 1 { drm["key"] = p[1] }
                    }
                } else { return false }
                return true
            }
            if line.hasPrefixIgnoringCase("ua=") { headers["User-Agent"] = value() }
            else if line.hasPrefixIgnoringCase("referer=") { headers["Referer"] = value() }
            else if line.hasPrefixIgnoringCase("origin=") { headers["Origin"] = value() }
            else if line.hasPrefixIgnoringCase("header=") { headers.merge(TVBoxConfig.headerMap(line.substringAfter("="))) { $1 } }
            else if line.hasPrefixIgnoringCase("parse=") { parse = value() == "1" }
            else if line.hasPrefixIgnoringCase("click=") { click = value() }
            else if line.hasPrefixIgnoringCase("format=") { format = LiveParser.mime(value()) }
            else { return false }
            return true
        }
    }

    static func mime(_ f: String) -> String {
        switch f.lowercased() {
        case "hls", "m3u8": return "application/x-mpegURL"
        case "dash", "mpd": return "application/dash+xml"
        case "flv": return "video/x-flv"
        case "ts", "mpegts": return "video/mp2t"
        default: return f
        }
    }

    private static func text(_ t: String, _ skipPass: Bool) -> [LiveGroup] {
        var b = Builder()
        var setting = Setting()
        var group = defaultGroup
        t.eachLine { raw in
            let line = raw.trimmed
            if line.isEmpty || setting.take(line) { return }
            guard let comma = line.firstIndex(of: ",") else { return }
            let left = String(line[..<comma]).trimmed, right = String(line[line.index(after: comma)...]).trimmed
            if right.containsIgnoringCase("#genre#") {
                setting = Setting()
                let cut = left.range(of: "_", options: [.literal, .backwards])
                if let cut, cut.lowerBound > left.startIndex {
                    group = String(left[..<cut.lowerBound])
                    b.group(group, skipPass ? "" : String(left[cut.upperBound...]).trimmed)
                } else {
                    group = left.nonEmptyOr(defaultGroup)
                    b.group(group)
                }
                return
            }
            let urls = splitUrls(right)
            if left.isEmpty || urls.isEmpty { return }
            var c = LiveChannel(name: left, urls: urls)
            c.headers = setting.headers
            c.parse = setting.parse
            c.click = setting.click
            c.format = setting.format
            c.drm = setting.drm
            b.add(group, c)
        }
        return b.build()
    }

    /// `key="value"` / `key=value` pairs of an `#EXTM3U` / `#EXTINF` line.
    private static func attrs(_ line: String) -> [String: String] {
        let s = Array(line.utf8)
        var out: [String: String] = [:]
        func letter(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        func word(_ c: UInt8) -> Bool { letter(c) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F }
        var i = 0
        while i < s.count {
            guard letter(s[i]) else { i += 1; continue }
            let start = i
            while i < s.count && word(s[i]) { i += 1 }
            guard i + 1 < s.count, s[i] == 0x3D else { continue }
            let key = String(decoding: s[start..<i], as: UTF8.self).lowercased()
            if s[i + 1] == 0x22 {
                let from = i + 2
                var e = from
                while e < s.count && s[e] != 0x22 { e += 1 }
                if e >= s.count { i += 1; continue }
                out[key] = String(decoding: s[from..<e], as: UTF8.self)
                i = e + 1
            } else {
                let from = i + 1
                var e = from
                while e < s.count && s[e] > 0x20 && s[e] != 0x2C && s[e] != 0x22 { e += 1 }
                if e > from { out[key] = String(decoding: s[from..<e], as: UTF8.self) }
                i = max(e, i + 1)
            }
        }
        return out
    }

    /// Title after the first comma outside quotes.
    private static func splitInf(_ line: String) -> (String, String) {
        var quoted = false
        for i in line.utf8.indices {
            let c = line.utf8[i]
            if c == 0x22 { quoted.toggle() }
            else if c == 0x2C && !quoted { return (String(line[..<i]), String(line[line.utf8.index(after: i)...]).trimmed) }
        }
        guard let r = line.range(of: ",", options: [.literal, .backwards]) else { return (line, "") }
        return (String(line[..<r.lowerBound]), String(line[r.upperBound...]).trimmed)
    }

    private static func catchup(_ a: [String: String]) -> Catchup? {
        let type: String = a["catchup"] ?? a["catchup-type"] ?? ""
        let source: String = a["catchup-source"] ?? ""
        if type.isEmpty && source.isEmpty { return nil }
        var days = 0
        let span: String? = a["catchup-days"] ?? a["tvg-rec"] ?? a["timeshift"]
        if let s = span, let d = Double(s), d.isFinite, abs(d) < 10_000 { days = Int(d) }
        return Catchup(type: type.lowercased(), source: source, days: days, replace: a["catchup-replace"] ?? "")
    }

    private static func m3u(_ t: String) -> LiveList {
        var b = Builder()
        var setting = Setting()
        var epg = "", name = "", extGroup = ""
        var defaults: Catchup?
        var inf: [String: String]?
        t.eachLine { raw in
            let line = raw.trimmed
            if line.isEmpty { return }
            if line.hasPrefix("#") {
                if line.hasPrefixIgnoringCase("#EXTM3U") {
                    let a = attrs(line)
                    for k in ["tvg-url", "url-tvg", "x-tvg-url"] {
                        if let u = a[k], !u.isEmpty { epg = u }
                    }
                    defaults = catchup(a) ?? defaults
                } else if line.hasPrefixIgnoringCase("#EXTINF") {
                    let (head, title) = splitInf(line)
                    inf = attrs(head)
                    name = title
                } else if line.hasPrefixIgnoringCase("#EXTGRP:") { extGroup = String(line.dropFirst(8)).trimmed }
                else { _ = setting.take(line) }
                return
            }
            defer { inf = nil; name = ""; setting = Setting() }
            guard let a = inf else {
                // plain `name,url` rows mixed into an M3U
                if let comma = line.firstIndex(of: ","), comma > line.startIndex, let r = line.range(of: "://", options: .literal), r.lowerBound > comma {
                    b.add(extGroup.nonEmptyOr(defaultGroup), LiveChannel(name: String(line[..<comma]).trimmed, urls: splitUrls(String(line[line.index(after: comma)...]).trimmed)))
                }
                return
            }
            guard line.contains("://") || line.hasPrefix("/") else { return }
            let urls = splitUrls(line)
            let names: [String] = [name, a["tvg-name"] ?? "", a["tvg-id"] ?? ""]
            let title = names.first { !$0.isEmpty } ?? TVBoxUrl.host(line)
            var c = LiveChannel(name: title, urls: urls.isEmpty ? [line] : urls)
            c.headers = setting.headers
            if let ua = a["http-user-agent"] ?? a["user-agent"], c.headers["User-Agent"] == nil { c.headers["User-Agent"] = ua }
            if let ref = a["http-referrer"] ?? a["http-referer"] ?? a["referer"], c.headers["Referer"] == nil { c.headers["Referer"] = ref }
            c.logo = a["tvg-logo"] ?? ""
            c.tvgId = a["tvg-id"] ?? ""
            c.tvgName = a["tvg-name"] ?? ""
            c.epg = a["tvg-url"] ?? ""
            c.catchup = catchup(a) ?? defaults
            c.format = setting.format
            c.parse = setting.parse
            c.click = setting.click
            c.drm = setting.drm
            b.add((a["group-title"] ?? extGroup).substringBefore(";").trimmed.nonEmptyOr(defaultGroup), c)
        }
        return LiveList(groups: b.build(), epg: epg, catchup: defaults)
    }

    static func json(_ a: [Any]) -> [LiveGroup] {
        var b = Builder()
        for case let g as JSONObject in a {
            guard let channels = g.optJSONArray("channel") ?? g.optJSONArray("channels") else { continue }
            let name = J.firstNonEmpty(g.string("group"), g.string("name")).nonEmptyOr(defaultGroup)
            b.group(name, g.string("pass").trimmed)
            for case let o as JSONObject in channels {
                let raw: [String]
                if let list = o.optJSONArray("urls") { raw = list.map { J.str($0).trimmed } }
                else { raw = splitUrls(J.firstNonEmpty(o.string("urls"), o.string("url"))) }
                let urls = raw.map(TVBoxConfig.proxyLive).filter { !$0.isEmpty }
                let title = o.string("name").trimmed
                if title.isEmpty || urls.isEmpty { continue }
                var c = LiveChannel(name: title, urls: urls)
                c.headers = TVBoxConfig.headerMap(o["header"] ?? o["headers"])
                for (k, h) in [("ua", "User-Agent"), ("referer", "Referer"), ("origin", "Origin")] {
                    let v = o.string(k)
                    if !v.isEmpty { c.headers[h] = v }
                }
                c.logo = o.string("logo")
                c.tvgId = o.string("tvgId")
                c.tvgName = o.string("tvgName")
                let epg = o.string("epg")
                c.epg = epg.contains("://") ? epg : ""
                c.catchup = o.optJSONObject("catchup").flatMap(Catchup.fromJSON)
                c.format = mime(o.string("format"))
                c.parse = J.int(o["parse"]) == 1
                c.click = o.string("click")
                b.add(name, c)
            }
        }
        return b.build()
    }
}
