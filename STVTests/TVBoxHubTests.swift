import XCTest
@testable import STV

/// State of the TVBox page: identities, groups and late answers.
@MainActor
final class TVBoxHubTests: XCTestCase {
    private func item(_ id: String, _ title: String) -> VodItem { VodItem(uid: "u", vodId: id, title: title, cover: "", remark: "") }

    /// Puts one config into the app's engine and returns the uid of its first live list.
    private func useLive(_ text: String) async throws -> String {
        await TVBoxStore.shared.ready()
        guard case .config(let c) = try TVBoxConfig.parse(text, "https://h.example/c.json") else { throw TVBoxError("not a config") }
        let repo = RepoRuntime("hub-test", "测试", c, trusted: false, allowPrivate: false)
        TVBoxStore.engine.setRepos([repo], active: repo.id)
        return try XCTUnwrap(repo.lives.first?.uid)
    }

    override func tearDown() async throws {
        TVBoxStore.engine.setRepos([], active: "")
        try await super.tearDown()
    }

    func testCardsNeverShareAnIdentity() {
        var seen = Set<String>()
        let cells = VodCell.unique([item("1", "a"), item("1", "a"), item("1", "b"), item("2", "a")], &seen)
        XCTAssertEqual(cells.map(\.item.title), ["a", "b", "a"])
        XCTAssertEqual(Set(cells.map(\.id)).count, cells.count)
        XCTAssertTrue(VodCell.unique([item("2", "a")], &seen).isEmpty)
    }

    func testLiveGroupsNamedLikeTheBuiltInOnes() async throws {
        let uid = try await useLive(#"{"lives":[{"name":"L","groups":[{"name":"全部","channel":[{"name":"A","urls":["http://h.example/1"]}]},{"name":"收藏","channel":[{"name":"B","urls":["http://h.example/2"]},{"name":"A","urls":["http://h.example/3"]}]},{"name":"锁","pass":"1","channel":[{"name":"C","urls":["http://h.example/4"]}]}]}]}"#)
        let pane = LivePane(uid)
        await pane.reload()
        XCTAssertNil(pane.error)
        XCTAssertEqual(pane.tabs, [.all, .favorites, .group("全部"), .group("收藏"), .group("锁")])
        XCTAssertEqual(pane.shown.map(\.number), [1, 2, 3], "channels of a locked group are not numbered")
        XCTAssertEqual(Array(pane.locked.keys), ["锁"])
        XCTAssertEqual(Set(pane.shown.map(\.id)).count, 3)
        pane.select(.group("收藏"))
        XCTAssertEqual(pane.shown.map(\.channel.name), ["B", "A"])
        pane.query = "a"
        XCTAssertEqual(pane.shown.map(\.number), [1, 3], "a search looks at every open group")
    }

    /// A tap leaves the channel's identity for the player, which finds it again in a list that changed meanwhile.
    func testChannelsOpenByTheirKey() async throws {
        let uid = try await useLive(#"{"lives":[{"name":"L","groups":[{"name":"g","channel":[{"name":"A","urls":["http://h.example/1"]},{"name":"A","urls":["http://h.example/2"]}]}]}]}"#)
        let pane = LivePane(uid)
        await pane.reload()
        let second = try XCTUnwrap(pane.shown.last)
        let ref = try XCTUnwrap(TVBoxStore.engine.live(uid))
        let series = TVBoxStore.shared.liveSeries(TVBoxLiveRef(uid: uid, live: ref.live))
        pane.open(second, in: series)
        let key = try XCTUnwrap(LiveHooks.lastChannel(series))
        XCTAssertEqual(key, ChannelKey(group: "g", name: "A", url: "http://h.example/2"))
        let reordered = [HGEpisode(ep: 1, vid: "x#0", duration: 0, title: "A", page: "g", media: #"{"urls":["http://h.example/2"]}"#),
                         HGEpisode(ep: 2, vid: "x#1", duration: 0, title: "A", page: "g", media: #"{"urls":["http://h.example/1"]}"#)]
        XCTAssertEqual(key.index(in: reordered), 0)
    }

    func testListsOfSitesThatAreGoneReportIt() async {
        await TVBoxStore.shared.ready()
        let feed = VodFeed("no-such-site", FeedKey(tid: "1"))
        XCTAssertTrue(feed.loading, "a new page opens on its skeleton")
        await feed.reload()
        XCTAssertFalse(feed.loading)
        XCTAssertNotNil(feed.error)
        XCTAssertTrue(feed.cells.isEmpty)
        feed.more()
        XCTAssertFalse(feed.loading, "a failed list waits for the user")
    }

    func testSearchScopesAndClears() {
        let s = VodSearch()
        s.scope(true, query: "", current: "a", searchable: [])
        XCTAssertTrue(s.all)
        XCTAssertFalse(s.active)
        s.submit(" 山 ", current: "a", searchable: [])
        XCTAssertEqual(s.submitted, "山")
        XCTAssertFalse(s.loading, "nothing to ask")
        let before = s.clears
        s.clear()
        XCTAssertFalse(s.active)
        XCTAssertEqual(s.clears, before + 1)
    }
}
