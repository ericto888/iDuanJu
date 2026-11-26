import Foundation

/// A TVBox 点播站点 behind the app's catalog: series id = `vod_id`, episode vid = `<vod_id>#<line>#<index>`.
struct TVBoxProvider: SiteProvider {
    let source: DramaSource
    let uid: String

    private static let latest = SiteCategory(id: "", title: "推荐", path: "")

    var categories: [SiteCategory] {
        [Self.latest] + (TVBoxStore.engine.knownHome(uid)?.categories ?? []).map { SiteCategory(id: $0.id, title: $0.name, path: $0.id) }
    }

    private func gate() async throws {
        await TVBoxStore.shared.ready()
        if TVBoxStore.isAdult(uid), !(await MainActor.run { SourceGate.shared.unlocked }) { throw TVBoxError("成人站点已隐藏") }
    }

    private func last<T>(_ s: AsyncThrowingStream<Snapshot<T>, Error>) async throws -> T {
        var out: Snapshot<T>?
        for try await x in s { out = x }
        guard let v = out else { throw CancellationError() }
        return v.value
    }

    func list(_ c: SiteCategory, page: Int) async throws -> HGPage {
        try await gate()
        if c.id.isEmpty {
            let h = try await last(TVBoxStore.engine.home(uid))
            return HGPage(items: Self.series(h.items), hasMore: false, nextOffset: nil)
        }
        return Self.page(try await last(TVBoxStore.engine.category(uid, c.id, page)))
    }

    func search(_ q: String, page: Int) async throws -> HGPage {
        try await gate()
        return Self.page(try await TVBoxStore.engine.search(uid, q, page: page))
    }

    private static func page(_ p: VodPage) -> HGPage { HGPage(items: series(p.items), hasMore: p.hasMore, nextOffset: p.page + 1) }

    private static func series(_ items: [VodItem]) -> [HGSeries] {
        PluginOut.unique(items.filter { !$0.folder && $0.action.isEmpty }.map(\.series)) { $0.id }
    }

    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        try await gate()
        var d = try await TVBoxStore.engine.detail(uid, s.seriesId)
        if d.cover.isEmpty { d.cover = s.cover }
        return d
    }

    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        try await gate()
        return try await TVBoxStore.engine.resolve(uid, ep)
    }
}

/// A TVBox 直播列表: channels are episodes (`<uid>#<index>`), groups their `page`.
struct TVBoxLiveProvider: SiteProvider {
    let source: DramaSource
    let uid: String

    var categories: [SiteCategory] { [] }
    func list(_ c: SiteCategory, page: Int) async throws -> HGPage { HGPage(items: [], hasMore: false) }

    /// Channels are searched on the live page; a list is not a catalog.
    func search(_ q: String, page: Int) async throws -> HGPage { HGPage(items: [], hasMore: false) }

    private func unlocked() async -> Set<String> {
        await TVBoxStore.shared.ready()
        return await MainActor.run { TVBoxStore.shared.unlocked(uid) }
    }

    func detail(_ s: HGSeries) async throws -> HGSeriesDetail {
        let open = await unlocked()
        return try await TVBoxStore.engine.liveDetail(uid, unlocked: open)
    }

    func resolve(_ s: HGSeries, _ ep: HGEpisode) async throws -> HGResolvedVideo {
        let open = await unlocked()
        return try await TVBoxStore.engine.resolveLive(uid, ep, unlocked: open)
    }
}
