import Foundation

/// What a media address carries, decided from the source's MIME hint, the URL, or (last) its first bytes.
/// This picks the playback core: AVFoundation for what it can open, MPV for everything else.
enum MediaContainer: String, Sendable {
    case hls, dash, mp4, audio
    /// Formats and protocols only MPV (FFmpeg) opens: FLV, MKV, MPEG-TS, WebM, AVI, RTMP, RTSP…
    case ffmpeg
    case unknown

    /// AVFoundation opens it (HLS, MP4 family, plain audio).
    var native: Bool { self == .hls || self == .mp4 || self == .audio }

    /// MIME type to hand to AVFoundation when the URL does not say what it is.
    var mime: String? {
        switch self {
        case .hls: return "application/x-mpegURL"
        case .mp4: return "video/mp4"
        default: return nil
        }
    }

    static func from(mime raw: String?) -> MediaContainer {
        guard let first = raw?.lowercased().split(separator: ";").first else { return .unknown }
        let m = first.trimmingCharacters(in: .whitespaces)
        if m.isEmpty { return .unknown }
        if m.contains("mpegurl") || m == "hls" || m == "m3u8" { return .hls }
        if m.contains("dash+xml") || m == "dash" || m == "mpd" { return .dash }
        if ["video/mp4", "video/quicktime", "video/x-m4v", "mp4"].contains(m) { return .mp4 }
        if ["flv", "matroska", "webm", "mp2t", "x-msvideo", "rmvb", "x-ms-wmv", "rtmp", "rtsp"].contains(where: { m.contains($0) }) { return .ffmpeg }
        if m.hasPrefix("audio/") { return ["ogg", "opus", "x-ape"].contains(where: { m.contains($0) }) ? .ffmpeg : .audio }
        return .unknown
    }

    private static let mp4Ext: Set<String> = ["mp4", "m4v", "mov", "3gp"]
    private static let audioExt: Set<String> = ["mp3", "m4a", "aac", "wav", "flac"]
    private static let ffmpegExt: Set<String> = ["flv", "mkv", "ts", "m2ts", "mts", "webm", "avi", "wmv", "asf", "rm", "rmvb", "mpg", "mpeg",
                                                 "vob", "ogv", "ogg", "opus", "ape", "f4v", "divx"]
    private static let ffmpegScheme: Set<String> = ["rtmp", "rtmps", "rtmpt", "rtsp", "rtsps", "rtp", "udp", "mms", "mmsh", "srt", "ftp"]

    static func from(url: URL) -> MediaContainer {
        if let s = url.scheme?.lowercased(), ffmpegScheme.contains(s) { return .ffmpeg }
        let path = url.path.lowercased()
        if path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") || path.contains("/m3u8/") { return .hls }
        if path.hasSuffix(".mpd") { return .dash }
        let ext = (path as NSString).pathExtension
        if mp4Ext.contains(ext) { return .mp4 }
        if audioExt.contains(ext) { return .audio }
        if ffmpegExt.contains(ext) { return .ffmpeg }
        // `play.php?url=…/index.m3u8`, `?type=m3u8`
        let q = (url.query ?? "").lowercased()
        if q.contains(".m3u8") || q.contains("type=m3u8") || q.contains("format=m3u8") { return .hls }
        if q.contains(".mp4") { return .mp4 }
        if q.contains(".flv") || q.contains("type=flv") { return .ffmpeg }
        return .unknown
    }

    static func of(_ url: URL, stream: HGStream?) -> MediaContainer {
        let hinted = from(mime: stream?.format)
        if hinted != .unknown { return hinted }
        let byURL = from(url: url)
        if byURL != .unknown { return byURL }
        switch stream?.kind {
        case .hls?, .hlsAES?: return .hls
        case .mp4Cenc?: return .mp4
        // `.mp4Clear` is also what extensionless direct links are tagged with: not proof of an MP4.
        case .mp4Clear?, nil: return .unknown
        }
    }

    /// Container of a byte prefix (first KB of a response).
    static func sniff(_ head: Data) -> MediaContainer {
        let b = [UInt8](head.prefix(1024))
        guard b.count >= 4 else { return .unknown }
        let text = String(decoding: b.prefix(256), as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF} \r\n\t"))
        if text.hasPrefix("#EXTM3U") { return .hls }
        if text.hasPrefix("<?xml") || text.hasPrefix("<MPD") { return text.contains("MPD") ? .dash : .unknown }
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return .mp4 }   // ftyp
        if b[0] == 0x46, b[1] == 0x4C, b[2] == 0x56 { return .ffmpeg }                              // FLV
        if b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 { return .ffmpeg }                // Matroska / WebM
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 { return .ffmpeg }                // RIFF (AVI)
        if b[0] == 0x47, b.count < 189 || b[188] == 0x47 { return .ffmpeg }                         // MPEG-TS
        if b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return .audio }                               // ID3
        return .unknown
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.timeoutIntervalForResource = 3
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    /// Reads the first bytes of an address that says nothing about itself. Bounded (3 s, 1 KB); `.unknown` on any failure.
    static func probe(_ url: URL, headers: [String: String], lan: Bool? = nil) async -> MediaContainer {
        guard url.scheme == "http" || url.scheme == "https" else { return .unknown }
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        do {
            let (bytes, resp) = try await session.bytes(for: req, delegate: lan == nil ? nil : LanPolicy.Redirects(lan))
            defer { bytes.task.cancel() }
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return .unknown }
            let byType = from(mime: http.value(forHTTPHeaderField: "Content-Type"))
            if byType == .hls || byType == .dash { return byType }
            if let final = resp.url, final != url {
                let redirected = from(url: final)
                if redirected != .unknown { return redirected }
            }
            var head = Data()
            for try await b in bytes {
                head.append(b)
                if head.count >= 1024 { break }
            }
            let byBytes = sniff(head)
            return byBytes == .unknown ? byType : byBytes
        } catch { return .unknown }
    }
}
