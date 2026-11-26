import XCTest
@testable import STV

final class EpisodeGroupTests: XCTestCase {
    func testRedesignThirtyEpisodeGroups() {
        XCTAssertEqual(EpisodeGroups.ranges(total: 0), [])
        XCTAssertEqual(EpisodeGroups.ranges(total: 30), [EpisodeRange(0,29)])
        XCTAssertEqual(EpisodeGroups.ranges(total: 48), [EpisodeRange(0,29),EpisodeRange(30,47)])
        XCTAssertEqual(EpisodeGroups.ranges(total: 60), [EpisodeRange(0,29),EpisodeRange(30,59)])
        XCTAssertEqual(EpisodeGroups.size(for: 301), 50)
        XCTAssertEqual(EpisodeGroups.size(for: 601), 60)
    }

    /// Detail grid: plain numbering shows numbers, named episodes (variety dates, movies, extras) show their names.
    func testNamedEpisodes() {
        func eps(_ titles: [String]) -> [HGEpisode] { titles.enumerated().map { HGEpisode(ep: $0.offset + 1, vid: "v", duration: 0, title: $0.element) } }
        XCTAssertFalse(EpisodeGroups.named(eps(["", "", ""])))
        XCTAssertFalse(EpisodeGroups.named(eps(["第1集", "第02集", "3"])))
        XCTAssertFalse(EpisodeGroups.named(eps(["EP01", "EP02"])))
        XCTAssertTrue(EpisodeGroups.named(eps(["20240105期", "20240112期"])))
        XCTAssertTrue(EpisodeGroups.named(eps(["第1集", "番外"])))
    }
}
