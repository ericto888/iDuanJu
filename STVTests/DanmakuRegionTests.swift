import XCTest
@testable import STV

/// Danmaku lanes are placed on the SCREEN (top, full width), never on the letterboxed video, and stay clear of the
/// subtitle guard (18 % of the height) unless the user turns it off.
final class DanmakuRegionTests: XCTestCase {
    let lane: CGFloat = 16 * 1.55
    let portrait = CGSize(width: 402, height: 874), landscape = CGSize(width: 874, height: 402)

    func testPortraitStartsUnderTopBarNotAtVideo() {
        let r = DanmakuRegion.compute(screen: portrait, safeTop: 62, safeBottom: 34, landscape: false, showTech: true,
                                      area: DanmakuSettings.Area.third.fraction, laneHeight: lane, maxRows: 4)
        XCTAssertEqual(r.top, 62 + 48, "lane 0 right under the top bar")
        XCTAssertLessThan(r.top, portrait.height * 0.2, "lanes start in the top part of the SCREEN")
        XCTAssertEqual(r.rows, 4, "user's row setting caps the default 1/3 area")
        XCTAssertLessThanOrEqual(r.top + CGFloat(r.rows) * lane, r.bottomLimit)
        // A 16:9 video in portrait sits around y≈280…500; the region must not depend on it (no video input at all)
        // and lane 0 must be above where that video starts.
        XCTAssertLessThan(r.top, 280)
        let noTech = DanmakuRegion.compute(screen: portrait, safeTop: 62, safeBottom: 34, landscape: false, showTech: false,
                                           area: 0.34, laneHeight: lane, maxRows: 4)
        XCTAssertEqual(noTech.top, 62 + 48, "the tech strip does not move the lanes")
    }

    func testPortraitAreaAndBottomControlsLimit() {
        let q = DanmakuRegion.compute(screen: portrait, safeTop: 62, safeBottom: 34, landscape: false, showTech: true,
                                      area: DanmakuSettings.Area.quarter.fraction, laneHeight: lane, maxRows: 8)
        XCTAssertEqual(q.rows, Int((portrait.height - q.top) * 0.25 / lane))
        let most = DanmakuRegion.compute(screen: portrait, safeTop: 62, safeBottom: 34, landscape: false, showTech: true,
                                         area: DanmakuSettings.Area.most.fraction, laneHeight: lane, maxRows: 99)
        XCTAssertLessThanOrEqual(most.top + CGFloat(most.rows) * lane, most.bottomLimit, "never into the subtitle guard")
        XCTAssertEqual(most.bottomLimit, portrait.height - portrait.height * 0.18, accuracy: 0.01)
        let free = DanmakuRegion.compute(screen: portrait, safeTop: 62, safeBottom: 34, landscape: false, showTech: true,
                                         area: DanmakuSettings.Area.most.fraction, laneHeight: lane, avoidSubtitle: false, maxRows: 99)
        XCTAssertGreaterThan(free.bottomLimit, most.bottomLimit)
    }

    func testLandscapeFullWidthFromTop() {
        let r = DanmakuRegion.compute(screen: landscape, safeTop: 0, safeBottom: 21, landscape: true, showTech: true,
                                      area: DanmakuSettings.Area.third.fraction, laneHeight: lane, maxRows: 8)
        XCTAssertEqual(r.top, 16)
        XCTAssertGreaterThanOrEqual(r.rows, 3)
        XCTAssertLessThanOrEqual(r.top + CGFloat(r.rows) * lane, r.bottomLimit)
        let most = DanmakuRegion.compute(screen: landscape, safeTop: 0, safeBottom: 21, landscape: true, showTech: true,
                                         area: 0.75, laneHeight: lane, maxRows: 99)
        XCTAssertLessThanOrEqual(most.top + CGFloat(most.rows) * lane, most.bottomLimit, "landscape: above the subtitle guard")
    }

    func testAtLeastOneLaneOnTinyScreens() {
        let r = DanmakuRegion.compute(screen: CGSize(width: 320, height: 150), safeTop: 20, safeBottom: 0, landscape: false, showTech: true,
                                      area: 0.25, laneHeight: lane, maxRows: 4)
        XCTAssertEqual(r.rows, 1)
    }

    func testPluginDanmakuSupportsHongguoXmlAndTupleFormats() {
        let hg = PluginDanmaku.parseAnyPayload([
            "items": [
                ["time": 12.5, "text": "标准弹幕", "color": "#FF6600", "mode": "top", "likes": 88],
                ["progress": 5000, "content": "毫秒字段弹幕", "color": 0x00FF88, "mode": 4],
                ["p": "2.0,5,25,16711680", "m": "B站属性弹幕"],
            ],
            "truncated": false,
        ])
        XCTAssertEqual(hg.items.count, 3)
        XCTAssertEqual(hg.items[0].time, 2.0, accuracy: 0.001)
        XCTAssertEqual(hg.items[0].color, "#FF0000")
        XCTAssertEqual(hg.items[0].mode, .top)
        XCTAssertEqual(hg.items[1].time, 5.0, accuracy: 0.001)
        XCTAssertEqual(hg.items[1].color, "#00FF88")
        XCTAssertEqual(hg.items[1].mode, .bottom)
        XCTAssertEqual(hg.items[2].time, 12.5, accuracy: 0.001)
        XCTAssertEqual(hg.items[2].likes, 88)

        let xml = PluginDanmaku.parseAnyPayload(["xml": #"<i><d p="3.5,1,25,16777215,0,0,0,1">XML弹幕</d></i>"#])
        XCTAssertEqual(xml.items.count, 1)
        XCTAssertEqual(xml.items[0].text, "XML弹幕")

        let tuple = PluginDanmaku.parseAnyPayload([[8.25, 5, 0xABCDEF, "u1", "DPlayer数组弹幕"]])
        XCTAssertEqual(tuple.items.count, 1)
        XCTAssertEqual(tuple.items[0].color, "#ABCDEF")
        XCTAssertEqual(tuple.items[0].mode, .top)
    }

    @MainActor
    func testHomeSourceOrderingPreservesCustomAndAppendsNewSources() {
        let gate = SourceGate.shared
        let prev = gate.homeOrder
        defer { if prev.isEmpty { gate.resetHomeOrder() } else { gate.setHomeOrder(prev) } }

        gate.setHomeOrder(["builtin:novel", "builtin:hongguo", "site:plugin:com.test.hidden"])
        let ordered = gate.orderedKeys(["builtin:hongguo", "builtin:ai", "builtin:novel", "site:plugin:com.test.new"])
        XCTAssertEqual(ordered, ["builtin:novel", "builtin:hongguo", "builtin:ai", "site:plugin:com.test.new"])
    }

    func testDetailInlineEpisodePreviewRangeAnchorsAroundResume() {
        // <= 12 episodes: show everything inline
        XCTAssertEqual(EpisodeGroups.previewRange(total: 8, columns: 6, rows: 2, resume: nil, ascending: true), EpisodeRange(0, 7))
        // Fresh 80-ep drama (ascending): first 2 rows (0...11)
        XCTAssertEqual(EpisodeGroups.previewRange(total: 80, columns: 6, rows: 2, resume: nil, ascending: true), EpisodeRange(0, 11))
        // Fresh 80-ep drama (descending): latest 12 episodes (68...79)
        XCTAssertEqual(EpisodeGroups.previewRange(total: 80, columns: 6, rows: 2, resume: nil, ascending: false), EpisodeRange(68, 79))
        // Mid-series resume at index 37 (Ep 38): snaps to row boundary 36...47
        XCTAssertEqual(EpisodeGroups.previewRange(total: 80, columns: 6, rows: 2, resume: 37, ascending: true), EpisodeRange(36, 47))
        // Near-end resume at index 78 (Ep 79): clamps to full 12-cell window 68...79
        XCTAssertEqual(EpisodeGroups.previewRange(total: 80, columns: 6, rows: 2, resume: 78, ascending: true), EpisodeRange(68, 79))
    }

    func testTruncatedCENCHeadersDoNotCrash() {
        // Malformed moov with truncated trak/tkhd/senc boxes must fail gracefully rather than trap on subscript.
        var badMoov: [UInt8] = [
            0, 0, 0, 24, 0x6D, 0x6F, 0x6F, 0x76, // moov (24B)
            0, 0, 0, 16, 0x74, 0x72, 0x61, 0x6B, // trak (16B)
            0, 0, 0, 8,  0x74, 0x6B, 0x68, 0x64, // empty tkhd (0-byte body!)
        ]
        XCTAssertNoThrow(try {
            _ = try? CENCDecryptor.rangePlan(header: badMoov, keyHex: String(repeating: "00", count: 16))
        }())
        badMoov.append(contentsOf: [0, 0, 0, 12, 0x6D, 0x64, 0x61, 0x74, 1, 2, 3, 4])
        XCTAssertEqual(CENCDecryptor.moovLocation(badMoov), .end(24))
    }

    @MainActor
    func testAppBackupRoundTripAndSmartMerge() async throws {
        let lib = LibraryStore.shared
        let store = PluginStore.shared
        let s1 = HGSeries(seriesId: "backup_ut_1", title: "备份测试剧1", cover: "", episodeCount: 20)
        let s2 = HGSeries(seriesId: "backup_ut_2", title: "新包本地收藏2", cover: "", episodeCount: 10)
        let hadDemo = store.plugin(DebugPlugins.demoID) != nil
        defer {
            if lib.isFavorite(s1) { lib.toggleFavorite(s1) }
            if lib.isFavorite(s2) { lib.toggleFavorite(s2) }
            lib.removeProgress(s1)
            lib.removeProgress(s2)
            if !hadDemo { store.uninstall(DebugPlugins.demoID) }
        }

        if let pending = DebugPlugins.demoPending(update: false) {
            try store.commit(pending)
        }
        if !lib.isFavorite(s1) { lib.toggleFavorite(s1) }
        lib.record(s1, index: 4, ep: 5, seconds: 66, duration: 120)

        let backupData = try await AppBackup.createBackupData()
        XCTAssertTrue(AppBackup.isBackupData(backupData))

        // Simulate fresh install where old plugin & s1 are absent, while user already favorited s2.
        store.uninstall(DebugPlugins.demoID)
        XCTAssertNil(store.plugin(DebugPlugins.demoID))
        if lib.isFavorite(s1) { lib.toggleFavorite(s1) }
        lib.removeProgress(s1)
        if !lib.isFavorite(s2) { lib.toggleFavorite(s2) }

        let summary = try await AppBackup.restore(from: backupData)
        XCTAssertNotNil(store.plugin(DebugPlugins.demoID))
        XCTAssertTrue(lib.isFavorite(s1))
        XCTAssertTrue(lib.isFavorite(s2), "Smart merge must keep favorites added in the new install")
        XCTAssertEqual(lib.progress(for: s1)?.episodeNumber, 5)
        XCTAssertGreaterThanOrEqual(summary.plugins, 1)
    }
}
