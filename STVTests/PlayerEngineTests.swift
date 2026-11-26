import XCTest
@testable import STV

final class PlayerEngineTests: XCTestCase {
    func testMPVInputRouting() throws {
        let file = URL(fileURLWithPath: "/tmp/a.mp4")
        guard case .url(let u, _, false)? = MPVPlayerEngine.input(for: .file(file)) else { return XCTFail() }
        XCTAssertEqual(u, file)
        let remote = URL(string: "https://cdn.example.com/v.mp4")!
        guard case .url(_, let h, false)? = MPVPlayerEngine.input(for: .remote(remote, ["Referer": "https://x/"])) else { return XCTFail() }
        XCTAssertEqual(h["Referer"], "https://x/")
        // Loopback HLS (ad-stripped playlist) → HLS path.
        let pl = URL(string: "http://127.0.0.1:5000/abcd/p.m3u8")!
        guard case .url(_, _, true)? = MPVPlayerEngine.input(for: .direct(pl)) else { return XCTFail() }
        // TDLib route → loopback proxy HTTP URL directly consumed by libmpv.
        let tg = URL(string: "http://127.0.0.1:5000/tok1/tg/v.mp4")!
        guard case .url(let tgURL, _, false)? = MPVPlayerEngine.input(for: .direct(tg)) else { return XCTFail() }
        XCTAssertEqual(tgURL, tg)
        // Resource-loader AES / custom playlists stay on AVPlayer.
        XCTAssertNil(MPVPlayerEngine.input(for: .stream(HLSPlayback(headers: [:], keyHex: "00ff"), "https://x/v.mp4")))
        XCTAssertNil(MPVPlayerEngine.input(for: .stream(HLSPlayback(headers: [:], keyHex: ""), "https://x/index.m3u8")))
        guard case .url? = MPVPlayerEngine.input(for: .stream(HLSPlayback(headers: ["Referer": "r"], keyHex: ""), "https://x/v.mp4")) else { return XCTFail() }
    }

    func testHeadersAddUserAgentNotForLoopback() {
        let h = MPVPlayerEngine.headers(["Referer": "r"], for: URL(string: "https://cdn.example.com/a.mp4")!)
        XCTAssertEqual(h["Referer"], "r")
        XCTAssertNotNil(h["User-Agent"])
        let l = MPVPlayerEngine.headers([:], for: URL(string: "http://127.0.0.1:1/a.mp4")!)
        XCTAssertNil(l["Cookie"])
    }

    func testLabels() {
        XCTAssertEqual(MPVPlayerEngine.codecLabel("hevc"), "HEVC")
        XCTAssertEqual(MPVPlayerEngine.codecLabel("h264"), "H.264")
        XCTAssertEqual(MPVPlayerEngine.codecLabel("av1"), "AV1")
        XCTAssertEqual(MPVPlayerEngine.codecLabel(nil), "")
        XCTAssertEqual(PlayerTech.audioName(codec: "eac3", channels: 6), "E-AC3 5.1")
        XCTAssertEqual(PlayerTech.channelLabel(2), "2.0")
        XCTAssertEqual(MediaTrack.title(name: "UND (aac)", language: "und", codec: "aac", channels: 2, index: 0), "轨道 1 · AAC 2.0")
        XCTAssertEqual(MediaTrack.title(name: "Director Commentary", language: "und", codec: "", channels: 0, index: 1), "Director Commentary")
        XCTAssertTrue(MediaTrack.title(name: "", language: "jpn", codec: "aac", channels: 6, index: 1).hasSuffix("AAC 5.1"))
    }

    func testEngineSettingDefaultsToAuto() {
        let d = UserDefaults.standard
        let old = d.object(forKey: PlayerEngineSettings.key)
        defer { d.set(old, forKey: PlayerEngineSettings.key) }
        d.removeObject(forKey: PlayerEngineSettings.key)
        switch ProcessInfo.processInfo.environment["STV_ENGINE"] {
        case "avplayer": XCTAssertEqual(PlayerEngineSettings.preferred, .avplayer)
        case "mpv", "aether": XCTAssertEqual(PlayerEngineSettings.preferred, .mpv)
        default: XCTAssertEqual(PlayerEngineSettings.preferred, .auto)
        }
        d.set("avplayer", forKey: PlayerEngineSettings.key)
        if ProcessInfo.processInfo.environment["STV_ENGINE"] == nil { XCTAssertEqual(PlayerEngineSettings.preferred, .avplayer) }
    }

    func testEngineOrderFollowsTheContainer() {
        for c in [MediaContainer.hls, .mp4, .audio, .unknown] {
            XCTAssertEqual(PlayerEngineSettings.order(c, preferred: .auto), [.avplayer, .mpv], c.rawValue)
        }
        for c in [MediaContainer.ffmpeg, .dash] {
            XCTAssertEqual(PlayerEngineSettings.order(c, preferred: .auto), [.mpv, .avplayer], c.rawValue)
            // AVFoundation cannot open these at all, whatever the preference.
            XCTAssertEqual(PlayerEngineSettings.order(c, preferred: .avplayer), [.mpv, .avplayer], c.rawValue)
        }
        XCTAssertEqual(PlayerEngineSettings.order(.hls, preferred: .mpv), [.mpv, .avplayer])
    }

    func testContainerDetection() throws {
        func c(_ s: String, _ stream: HGStream? = nil) throws -> MediaContainer { MediaContainer.of(try XCTUnwrap(URL(string: s)), stream: stream) }
        XCTAssertEqual(try c("https://v.example/a/index.m3u8?x=1"), .hls)
        XCTAssertEqual(try c("http://127.0.0.1:1/abcd/p.m3u8?u=x"), .hls)
        XCTAssertEqual(try c("https://v.example/play.php?url=https://x/a.m3u8"), .hls)
        XCTAssertEqual(try c("https://v.example/a.mp4"), .mp4)
        XCTAssertEqual(try c("https://v.example/a.flv?auth=1"), .ffmpeg)
        XCTAssertEqual(try c("https://v.example/a.mkv"), .ffmpeg)
        XCTAssertEqual(try c("rtmp://l.example/app/s"), .ffmpeg)
        XCTAssertEqual(try c("rtsp://l.example/s"), .ffmpeg)
        XCTAssertEqual(try c("https://v.example/a.mpd"), .dash)
        XCTAssertEqual(try c("https://v.example/live/1"), .unknown)
        // The source's MIME hint wins over the URL; a plain "mp4" tag on an extensionless link proves nothing.
        let hinted = HGStream(url: "https://v.example/live/1", key: "", kind: .mp4Clear, format: "application/x-mpegURL")
        XCTAssertEqual(try c(hinted.url, hinted), .hls)
        XCTAssertEqual(try c("https://v.example/live/1", HGStream(url: "https://v.example/live/1", key: "", kind: .mp4Clear)), .unknown)
        XCTAssertEqual(try c("https://v.example/x", HGStream(url: "https://v.example/x", key: "", kind: .hls)), .hls)
    }

    func testContainerSniffing() {
        XCTAssertEqual(MediaContainer.sniff(Data("\u{FEFF}#EXTM3U\n#EXTINF:1,\n".utf8)), .hls)
        XCTAssertEqual(MediaContainer.sniff(Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8)), .mp4)
        XCTAssertEqual(MediaContainer.sniff(Data("FLV".utf8) + Data([1, 5, 0, 0])), .ffmpeg)
        XCTAssertEqual(MediaContainer.sniff(Data([0x1A, 0x45, 0xDF, 0xA3, 0])), .ffmpeg)
        var ts = Data(count: 376); ts[0] = 0x47; ts[188] = 0x47
        XCTAssertEqual(MediaContainer.sniff(ts), .ffmpeg)
        XCTAssertEqual(MediaContainer.sniff(Data("<html><body>".utf8)), .unknown)
        XCTAssertEqual(MediaContainer.sniff(Data()), .unknown)
    }

    func testDeadSourcesSkipTheOtherCore() {
        XCTAssertTrue(PlaybackCoordinator.sourceIsDead(URLError(.cannotFindHost)))
        XCTAssertTrue(PlaybackCoordinator.sourceIsDead(NSError(domain: "AVFoundationErrorDomain", code: -11800,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: -12938)])))
        XCTAssertFalse(PlaybackCoordinator.sourceIsDead(NSError(domain: "AVFoundationErrorDomain", code: -11828)))
        XCTAssertFalse(PlaybackCoordinator.sourceIsDead(nil))
    }

    func testExternalSubtitleParsing() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\n<i>第一句</i>\r\n第二行\r\n\r\n2\r\n00:01:00,000 --> 00:01:01,000\r\n第二句\r\n"
        let a = ExternalSubtitles.parse(Data(srt.utf8), format: "application/x-subrip", name: "a.srt")
        XCTAssertEqual(a.map(\.text), ["第一句\n第二行", "第二句"])
        XCTAssertEqual(a[0].start, 1, accuracy: 0.001); XCTAssertEqual(a[0].end, 2.5, accuracy: 0.001); XCTAssertEqual(a[1].start, 60, accuracy: 0.001)
        let vtt = "WEBVTT\n\n00:01.000 --> 00:02.000 align:start\nhello\n"
        XCTAssertEqual(ExternalSubtitles.parse(Data(vtt.utf8), format: nil, name: "a.vtt"), [.init(start: 1, end: 2, text: "hello")])
        let ass = "[Script Info]\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:03.00,0:00:04.50,Default,,0,0,0,,{\\an8}一\\N二,三\n"
        XCTAssertEqual(ExternalSubtitles.parse(Data(ass.utf8), format: nil, name: "a.ass"), [.init(start: 3, end: 4.5, text: "一\n二,三")])
    }

    func testDanmakuFileParsing() {
        let xml = "<?xml version=\"1.0\"?><i><d p=\"2.5,1,25,16711680,0,0,0,0\">红</d><d p=\"1,5,25,16777215\">顶 &amp; 部</d><d p=\"x\">坏</d></i>"
        let a = DanmakuFile.parse(Data(xml.utf8))
        XCTAssertEqual(a.map(\.text), ["顶 & 部", "红"])
        XCTAssertEqual(a[0].mode, .top); XCTAssertEqual(a[1].color, "#FF0000")
        let json = "{\"danmuku\":[[3,\"right\",\"#00FF00\",\"u\",\"绿\"]]}"
        XCTAssertEqual(DanmakuFile.parse(Data(json.utf8)).first?.color, "#00FF00")
    }
}
