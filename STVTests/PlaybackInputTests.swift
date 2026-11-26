import XCTest
@testable import STV

/// What sources may send to the player: odd numbers, byte ranges, upstream errors, addresses of the local network.
final class PlaybackInputTests: XCTestCase {
    private var upstreamProxy = LocalHLSProxy()

    /// Real HTTP upstream with Range/206.
    private func upstream(_ data: Data) throws -> String {
        let id = Int32.random(in: 100_000...9_000_000)
        return try XCTUnwrap(upstreamProxy.tdURL(TDFileRef(id: id), budget: 0, source: MockTDFileSource(data, block: 65_536), chunk: 262_144))
    }

    private func get(_ address: String, _ range: String? = nil) async throws -> (HTTPURLResponse, Data) {
        var r = URLRequest(url: try XCTUnwrap(URL(string: address)))
        r.timeoutInterval = 30
        if let range { r.setValue(range, forHTTPHeaderField: "Range") }
        let (d, resp) = try await URLSession(configuration: .ephemeral).data(for: r)
        return (try XCTUnwrap(resp as? HTTPURLResponse), d)
    }

    func testMalformedPlaylistNumbers() throws {
        let text = """
        #EXTM3U
        #EXT-X-BYTERANGE:
        #EXTINF:inf,
        a.ts
        #EXT-X-BYTERANGE:9223372036854775807@9223372036854775807
        #EXTINF:nan,
        b.ts
        #EXT-X-BYTERANGE:-5@3
        #EXTINF:6,
        c.ts
        #EXT-X-BYTERANGE:100@50
        #EXTINF:6,
        d.ts
        #EXT-X-BYTERANGE:10
        #EXTINF:6,
        d.ts
        """
        let units = try XCTUnwrap(HLSMedia.parse(text, base: URL(string: "https://h.example/x.m3u8")!))
        XCTAssertEqual(units.map(\.range), [nil, nil, nil, 50...149, 150...159])
        XCTAssertEqual(units.map(\.start), [0, 0, 0, 6, 12])
        // lengths nobody can have made count for nothing
        func segs(_ prefix: String, _ n: Int, _ duration: String) -> [String] { (0..<n).flatMap { ["#EXTINF:\(duration),", "\(prefix)\($0).ts"] } }
        var ads = ["#EXTM3U", "#EXT-X-TARGETDURATION:10"]
        ads += segs("main", 6, "6")
        ads.append("#EXT-X-DISCONTINUITY")
        ads += segs("https://bfzy.example/video/adjump/time/ad", 3, "1e300")
        ads.append("#EXT-X-DISCONTINUITY")
        ads += segs("main9", 6, "6")
        ads.append("#EXT-X-ENDLIST")
        XCTAssertEqual(HLSAdFilter.filter(ads.joined(separator: "\n"), base: URL(string: "https://v.example.com/a/index.m3u8")!).removed, 3)
    }

    func testDanmakuColoursOutOfRange() {
        let rows = DanmakuFile.parse(Data(##"{"danmuku":[[1,0,1e30,"x","甲"],[2,0,16711680,"x","乙"],[3,0,"#00FF00","x","丙"],[4,0,-1e30,"x","丁"]]}"##.utf8))
        XCTAssertEqual(rows.map(\.text), ["甲", "乙", "丙", "丁"])
        XCTAssertEqual(rows.map(\.color), ["#FFFFFF", "#FF0000", "#00FF00", "#FFFFFF"])
        XCTAssertEqual(DanmakuFile.parse(Data(#"[{"time":1,"text":"a","color":1e300},{"time":2,"text":"b","color":255}]"#.utf8)).map(\.color), ["#FFFFFF", "#0000FF"])
    }

    func testDanmakuOnlyComesFromTheWeb() async {
        let f = await DanmakuFile.fetch("file:///etc/hosts")
        XCTAssertEqual(f.error, "弹幕地址无效")
        let lan = await DanmakuFile.fetch("http://192.168.1.1/d.xml", lan: false)
        XCTAssertEqual(lan.error, LanPolicy.message)
    }

    func testHeaderFieldsKeepTheirCommas() {
        XCTAssertEqual(MPVPlayerEngine.headerFields(["Cookie": "a=1, b=2", "X": "y", "Referer": "r", "User-Agent": "u"]), "Cookie: a=1\\, b=2,X: y")
        XCTAssertEqual(MPVPlayerEngine.headerFields([:]), "")
    }

    func testEndsThatComeTooEarly() {
        XCTAssertTrue(PlaybackCoordinator.endsEarly(at: 100, of: 3000))
        XCTAssertFalse(PlaybackCoordinator.endsEarly(at: 2950, of: 3000))
        XCTAssertFalse(PlaybackCoordinator.endsEarly(at: 5, of: 12))
        XCTAssertFalse(PlaybackCoordinator.endsEarly(at: 0, of: 0))
        XCTAssertFalse(PlaybackCoordinator.endsEarly(at: .nan, of: 3000))
    }

    func testSlicesOfABiggerFilePassThrough() async throws {
        XCTAssertEqual(LocalHLSProxy.slice("bytes=0-99"), LocalHLSProxy.Slice(from: 0, to: 99))
        XCTAssertEqual(LocalHLSProxy.slice("Bytes=100-"), LocalHLSProxy.Slice(from: 100, to: nil))
        for whole in [nil, "bytes=0-", "bytes=-5", "bytes=5-2", "bytes=0-1,5-6", "bytes=0-9223372036854775807", "items=0-1", "bytes=a-b"] { XCTAssertNil(LocalHLSProxy.slice(whole), whole ?? "nil") }

        let data = Data((0..<(2 * 1_048_576 + 33)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
        let up = try upstream(data), proxy = LocalHLSProxy()
        let list = try XCTUnwrap(proxy.playlistURL(up, headers: [:], strip: false))
        for kind in ["s.ts", "r"] {
            let address = list.replacingOccurrences(of: "/p.m3u8?", with: "/\(kind)?")
            let (h, d) = try await get(address, "bytes=1000-1099")
            XCTAssertEqual(h.statusCode, 206, kind)
            XCTAssertEqual(h.value(forHTTPHeaderField: "Content-Range"), "bytes 1000-1099/\(data.count)", kind)
            XCTAssertEqual(h.value(forHTTPHeaderField: "Content-Length"), "100", kind)
            XCTAssertEqual(d, data.subdata(in: 1000..<1100), kind)
            let (_, all) = try await get(address, "bytes=0-")
            XCTAssertEqual(all, data, kind)
            let (h3, tail) = try await get(address, "bytes=\(data.count - 10)-")
            XCTAssertEqual(h3.statusCode, 206, kind)
            XCTAssertEqual(tail, data.suffix(10), kind)
        }
    }

    func testUpstreamErrorsAndForbiddenAddresses() async throws {
        let up = try upstream(Data("#EXTM3U\n".utf8)), proxy = LocalHLSProxy()
        let gone = String(up[..<(try XCTUnwrap(up.range(of: "/tg/"))).upperBound]) + "1.mp4"
        for kind in ["p.m3u8", "s.ts", "r"] {
            let address = try XCTUnwrap(proxy.playlistURL(gone, headers: [:], strip: false)).replacingOccurrences(of: "/p.m3u8?", with: "/\(kind)?")
            let (h, _) = try await get(address)
            XCTAssertEqual(h.statusCode, 404, kind)
        }
        let dead = try XCTUnwrap(proxy.playlistURL("http://127.0.0.1:9/x.m3u8", headers: [:], strip: false))
        let (h, _) = try await get(dead)
        XCTAssertEqual(h.statusCode, 502)
        // a TVBox source may not reach another server of this device
        let own = try XCTUnwrap(proxy.playlistURL(up, headers: [:], strip: false, lan: true))
        let (h2, d2) = try await get(own)
        XCTAssertEqual(h2.statusCode, 403)
        XCTAssertEqual(String(decoding: d2, as: UTF8.self), LanPolicy.device)
        XCTAssertEqual(LocalHLSProxy.status(URLError(.timedOut)), 502)
        XCTAssertEqual(LocalHLSProxy.status(SegmentFeed.Status(code: 302)), 403)
        XCTAssertEqual(LocalHLSProxy.status(SegmentFeed.Status(code: 410)), 410)
    }

    func testFetchesAreBounded() async throws {
        let up = try upstream(Data(count: 300_000))
        let ok = try await SegmentFeed.fetch(URLRequest(url: URL(string: up)!), limit: 400_000)
        XCTAssertEqual(ok.data.count, 300_000)
        do { _ = try await SegmentFeed.fetch(URLRequest(url: URL(string: up)!), limit: 100_000); XCTFail("no limit") } catch { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
    }
}
