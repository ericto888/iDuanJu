import Foundation

/// 弹幕 files delivered by a source (TVBox `danmaku`): Bilibili XML (`<d p="time,mode,size,color,…">text</d>`) or the
/// `[[time, mode, color, uid, text], …]` / `{"danmuku": […]}` JSON shape used by parsers.
enum DanmakuFile {
    static let limit = 12_000

    static func fetch(_ raw: String, lan: Bool? = nil) async -> HGDanmakuResult {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") else {
            return HGDanmakuResult(items: [], error: "弹幕地址无效")
        }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            let data = try await SegmentFeed.fetch(req, limit: 16 << 20, lan: lan).data
            let all = await Task.detached(priority: .userInitiated) { parse(data) }.value
            return HGDanmakuResult(items: Array(all.prefix(limit)), truncated: all.count > limit)
        } catch let e as SegmentFeed.Status {
            return HGDanmakuResult(items: [], error: "弹幕加载失败（HTTP \(e.code)）")
        } catch let e as TVBoxError {
            return HGDanmakuResult(items: [], error: e.message)
        } catch {
            return HGDanmakuResult(items: [], error: (error as? URLError)?.code == .dataLengthExceedsMaximum ? "弹幕文件过大" : "弹幕加载失败")
        }
    }

    static func parse(_ data: Data) -> [HGDanmaku] {
        let head = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let items = head.hasPrefix("{") || head.hasPrefix("[") ? json(data) : xml(data)
        return items.filter { !$0.text.isEmpty && $0.time.isFinite && $0.time >= 0 }.sorted { $0.time < $1.time }
    }

    private static func hex(_ v: Int) -> String { String(format: "#%06X", max(0, min(0xFFFFFF, v))) }
    /// Colour number of a file; anything that is none is white.
    private static func color(_ v: Any?) -> String { hex(v.flatMap(num).flatMap { Int(exactly: $0.rounded(.towardZero)) } ?? 0xFFFFFF) }

    private static func json(_ data: Data) -> [HGDanmaku] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows = root as? [Any] ?? (root as? [String: Any]).flatMap { ($0["danmuku"] ?? $0["danmaku"] ?? $0["data"] ?? $0["comments"]) as? [Any] } ?? []
        return rows.compactMap { row in
            if let a = row as? [Any], a.count >= 5, let t = num(a[0]) {
                return HGDanmaku(time: t, text: text("\(a[4])"), color: (a[2] as? String).map { $0.hasPrefix("#") ? $0 : "#FFFFFF" } ?? color(a[2]))
            }
            if let o = row as? [String: Any] {
                if let p = o["p"] as? String, let m = (o["m"] ?? o["text"] ?? o["c"]) as? String { return item(p: p, text: m) }
                if let t = num(o["time"] ?? o["progress"] ?? 0), let m = (o["text"] ?? o["content"]) as? String {
                    return HGDanmaku(time: o["progress"] != nil ? t / 1000 : t, text: text(m), color: (o["color"] as? String) ?? color(o["color"]))
                }
            }
            return nil
        }
    }

    private static func num(_ v: Any) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
    private static func text(_ s: String) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }

    private static func item(p: String, text raw: String) -> HGDanmaku? {
        let f = p.split(separator: ",", omittingEmptySubsequences: false)
        guard let first = f.first, let t = Double(first) else { return nil }
        let mode: HGDanmaku.Mode = f.count > 1 && f[1] == "5" ? .top : f.count > 1 && f[1] == "4" ? .bottom : .scroll
        // Bilibili: time,mode,size,color,…  DanDanPlay: time,mode,color,uid
        let color = f.count >= 5 ? Int(f[3]) : (f.count > 2 ? Int(f[2]) : nil)
        return HGDanmaku(time: t, text: text(raw), color: hex(color ?? 0xFFFFFF), mode: mode)
    }

    private static func xml(_ data: Data) -> [HGDanmaku] {
        let d = XMLHandler()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = d
        parser.parse()
        return d.items
    }

    private final class XMLHandler: NSObject, XMLParserDelegate {
        var items: [HGDanmaku] = []
        private var p: String?
        private var buffer = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            guard name == "d" else { return }
            p = attributes["p"]
            buffer = ""
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) { if p != nil { buffer += s } }
        func parser(_ parser: XMLParser, foundCDATA block: Data) { if p != nil { buffer += String(decoding: block, as: UTF8.self) } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name == "d", let p else { return }
            if let i = DanmakuFile.item(p: p, text: buffer) { items.append(i) }
            self.p = nil
            if items.count > DanmakuFile.limit * 2 { parser.abortParsing() }
        }
    }
}
