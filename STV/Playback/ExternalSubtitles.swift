import Foundation

/// Subtitles delivered next to a stream (TVBox `subs`): fetched on demand, parsed here and drawn by the player page, so
/// they look the same whichever core plays the video.
@MainActor final class ExternalSubtitles {
    struct Cue: Equatable { var start: Double; var end: Double; var text: String }

    /// Track ids far above anything a demuxer hands out.
    static let idBase = 100_000
    private(set) var tracks: [MediaTrack] = []
    private(set) var selected: Int?
    private var sources: [HGSubtitle] = []
    private var lan: Bool?
    private var cues: [Cue] = []
    private var loading: Task<Void, Never>?
    private var cursor = 0

    func attach(_ list: [HGSubtitle], lan: Bool? = nil) {
        self.lan = lan
        guard list != sources else { return }
        clear()
        sources = list
        tracks = list.enumerated().map { i, s in
            MediaTrack(id: Self.idBase + i, title: s.name.isEmpty ? "外挂字幕 \(i + 1)" : s.name, language: s.language)
        }
    }

    func clear() {
        loading?.cancel(); loading = nil
        sources = []; tracks = []; cues = []; selected = nil; cursor = 0
    }

    func owns(_ id: Int) -> Bool { id >= Self.idBase && id - Self.idBase < sources.count }

    func select(_ id: Int?, onError: @escaping (String) -> Void = { _ in }) {
        loading?.cancel()
        cues = []; cursor = 0
        guard let id, owns(id), let url = URL(string: sources[id - Self.idBase].url) else { selected = nil; return }
        selected = id
        let format = sources[id - Self.idBase].format, lan = lan
        loading = Task { [weak self] in
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 15
                let data = try await SegmentFeed.fetch(req, limit: 8 << 20, lan: lan).data
                let parsed = await Task.detached(priority: .userInitiated) { Self.parse(data, format: format, name: url.lastPathComponent) }.value
                guard let self, !Task.isCancelled, self.selected == id else { return }
                self.cues = parsed
                if parsed.isEmpty { onError("字幕内容为空或格式不支持") }
            } catch {
                guard let self, !Task.isCancelled, self.selected == id else { return }
                self.selected = nil
                onError((error as? TVBoxError)?.message ?? "字幕加载失败")
            }
        }
    }

    /// Cue text at `t` (cues are sorted; the cursor makes sequential playback O(1)).
    func text(at t: Double) -> String? {
        guard !cues.isEmpty else { return nil }
        if cursor >= cues.count || cues[cursor].start > t { cursor = 0 }
        while cursor + 1 < cues.count, cues[cursor].end < t { cursor += 1 }
        var lines: [String] = []
        var i = cursor
        while i < cues.count, cues[i].start <= t {
            if cues[i].end >= t { lines.append(cues[i].text) }
            i += 1
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Parsing

    nonisolated static func parse(_ data: Data, format: String?, name: String) -> [Cue] {
        let text = decode(data).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let hint = ((format ?? "") + " " + name).lowercased()
        let out: [Cue]
        if hint.contains("ssa") || hint.contains(".ass") || hint.contains("/ass") || text.contains("[Events]") { out = ass(text) } else { out = srt(text) }
        return out.sorted { $0.start < $1.start }
    }

    nonisolated private static func decode(_ d: Data) -> String {
        if d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF]), let s = String(data: d, encoding: .utf16) { return s }
        if let s = String(data: d, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: d, encoding: gb) ?? String(decoding: d, as: UTF8.self)
    }

    /// `00:01:02,500`, `01:02.500`, `1:02:03.50`
    nonisolated static func seconds(_ raw: Substring) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; total = total * 60 + v }
        return total
    }

    /// SRT and WebVTT share the `start --> end` block shape.
    nonisolated private static func srt(_ text: String) -> [Cue] {
        var out: [Cue] = [], lines: [String] = [], span: (Double, Double)?
        func flush() {
            if let s = span, !lines.isEmpty {
                let body = strip(lines.joined(separator: "\n"))
                if !body.isEmpty { out.append(Cue(start: s.0, end: s.1, text: body)) }
            }
            lines = []; span = nil
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let arrow = line.range(of: "-->") {
                flush()
                let endToken = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? ""
                if let a = seconds(line[..<arrow.lowerBound]), let b = seconds(endToken) { span = (a, b) }
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if span != nil {
                lines.append(String(line))
            }
        }
        flush()
        return out
    }

    nonisolated private static func ass(_ text: String) -> [Cue] {
        var order = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var inEvents = false, out: [Cue] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inEvents = line.lowercased() == "[events]"; continue }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                order = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if line.lowercased().hasPrefix("dialogue:") {
                let f = line.dropFirst(9).split(separator: ",", maxSplits: order.count - 1, omittingEmptySubsequences: false)
                guard let si = order.firstIndex(of: "start"), let ei = order.firstIndex(of: "end"), let ti = order.firstIndex(of: "text"),
                      f.count > max(si, max(ei, ti)), let a = seconds(f[si]), let b = seconds(f[ei]) else { continue }
                let body = strip(String(f[ti]).replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n"))
                if !body.isEmpty { out.append(Cue(start: a, end: b, text: body)) }
            }
        }
        return out
    }

    nonisolated private static func strip(_ s: String) -> String {
        s.replacingOccurrences(of: #"\{[^}]*\}|<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Which 线路 a title plays on: picked on the detail page or in the player, remembered across launches.
@MainActor enum PlayLinePrefs {
    private static let key = "stv.player.lines"
    private static var map: [String: String] = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]

    static func preferred(_ s: HGSeries) -> String? { map[s.id] }

    static func set(_ line: String, for s: HGSeries) {
        guard map[s.id] != line else { return }
        if map.count > 300 { map.removeAll() }
        map[s.id] = line
        UserDefaults.standard.set(map, forKey: key)
    }
}
