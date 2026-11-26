import Combine
import Foundation

/// One channel of a live list. `number`: its place in the player's list, 0 while its group is locked.
struct LiveRow: Identifiable {
    let id: Int
    let group: String
    let channel: LiveChannel
    let number: Int
}

/// One live source: groups, rows and the programme on air per channel.
@MainActor
final class LivePane: ObservableObject {
    enum Tab: Hashable { case all, favorites, group(String) }

    let uid: String
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var locked: [String: LiveGroup] = [:]
    @Published private(set) var shown: [LiveRow] = []
    @Published private(set) var total = 0
    @Published private(set) var hasGuide = false
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var tab: Tab = .all
    @Published var query = "" { didSet { if query != oldValue { filter() } } }

    private var data: LiveData?
    private var rows: [LiveRow] = []
    private var programs: [Int: Program] = [:]
    private var job: Task<Void, Never>?
    /// Load in charge: an older one that is still winding down writes nothing.
    private var turn = 0
    private var sorting: Task<Void, Never>?

    init(_ uid: String) { self.uid = uid }
    deinit { job?.cancel(); sorting?.cancel() }

    var loaded: Bool { data != nil }

    func ensure() { if data == nil, !loading { load(force: false) } }
    func retry() { load(force: true) }
    func reload() async {
        load(force: true)
        await job?.value
    }

    private func load(force: Bool) {
        job?.cancel()
        turn += 1
        let mine = turn
        loading = true
        error = nil
        let stream = TVBoxStore.engine.liveChannels(uid, force: force)
        job = Task { [weak self] in
            do {
                for try await s in stream { self?.show(s, mine) }
                if !Task.isCancelled { self?.finish(nil, mine) }
            } catch { if !Task.isCancelled { self?.finish(error, mine) } }
        }
    }

    private func show(_ s: Snapshot<LiveData>, _ mine: Int) {
        guard mine == turn else { return }
        if let e = s.error { error = e }
        // a refresh that comes back empty leaves what is there
        if data === s.value || (s.value.list.groups.isEmpty && !rows.isEmpty) { return }
        data = s.value
        rebuild()
    }

    private func finish(_ e: Error?, _ mine: Int) {
        guard mine == turn else { return }
        if let e { error = tvboxErrorText(e) }
        loading = false
    }

    /// The list changed, or a group was unlocked.
    func rebuild() {
        guard let d = data else { return }
        let open = TVBoxStore.shared.unlocked(uid)
        var out: [LiveRow] = [], names: [Tab] = [], closed: [String: LiveGroup] = [:], seen = Set<String>()
        var n = 0
        for g in d.list.groups {
            let isOpen = g.pass.isEmpty || open.contains(g.name)
            if seen.insert(g.name).inserted { names.append(.group(g.name)) }
            if !isOpen { closed[g.name] = g }
            for c in g.channels {
                if isOpen { n += 1 }
                out.append(LiveRow(id: out.count, group: g.name, channel: c, number: isOpen ? n : 0))
            }
        }
        rows = out
        programs = [:]
        total = n
        locked = closed
        tabs = [.all, .favorites] + names
        hasGuide = !d.ref.live.epg.isEmpty || !d.list.epg.isEmpty || out.contains { !$0.channel.epg.isEmpty }
        if !tabs.contains(tab) { tab = .all }
        filter()
    }

    func select(_ t: Tab) {
        tab = t
        filter()
    }

    func favoritesChanged() { if tab == .favorites { filter() } }

    /// Lists of many thousand channels are filtered off the main thread.
    private func filter() {
        sorting?.cancel()
        let all = rows, t = tab, q = query.trimmed
        let stars = t == .favorites ? Set(TVBoxStore.shared.favoriteChannels) : []
        if all.count < 1500 {
            shown = Self.filtered(all, t, q, stars)
            return
        }
        sorting = Task { [weak self] in
            let out = await Task.detached(priority: .userInitiated) { Self.filtered(all, t, q, stars) }.value
            if !Task.isCancelled { self?.shown = out }
        }
    }

    nonisolated private static func filtered(_ rows: [LiveRow], _ tab: Tab, _ q: String, _ stars: Set<String>) -> [LiveRow] {
        rows.filter { r in
            if r.number == 0 { return false }
            if !q.isEmpty { return r.channel.name.containsIgnoringCase(q) }
            switch tab {
            case .all: return true
            case .favorites: return stars.contains(r.channel.name)
            case .group(let g): return r.group == g
            }
        }
    }

    // MARK: Playing

    /// The list may be refreshed between the tap and the player reading it: the channel goes by its `ChannelKey` (group, name,
    /// first address), which the player looks up in the list it gets.
    func open(_ r: LiveRow, in series: HGSeries) {
        let media = JSONObject().put("urls", Array(r.channel.urls.prefix(1))).toString()
        LiveHooks.remember(HGEpisode(ep: r.number, vid: "", duration: 0, title: r.channel.name, page: r.group, media: media), in: series)
        Router.push(.play(series, nil))
    }

    // MARK: Guide

    struct Program { let text: String; let until: Int64 }

    /// What is already known about a row, without waiting.
    func knownProgram(_ r: LiveRow) -> Program? {
        guard let p = programs[r.id], p.until > Catchup.nowMs else { return nil }
        return p
    }

    /// 当前节目, looked up once a row has stayed on screen for a moment and kept until the programme ends.
    func program(_ r: LiveRow) async -> Program? {
        if let known = knownProgram(r) { return known }
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return nil }
        let list = (try? await TVBoxStore.engine.guide(uid, r.channel.name, tvgId: r.channel.tvgId, tvgName: r.channel.tvgName)) ?? []
        if Task.isCancelled { return nil }
        let now = Catchup.nowMs
        let (cur, next) = EpgService.nowNext(list, now)
        var text = ""
        if let cur { text = "正在播出：\(cur.title)" } else if let next { text = "稍后：\(next.title)" }
        // guides are corrected during the day: never trusted for longer than a quarter of an hour
        let end = cur?.end ?? next?.start ?? Int64.max
        let p = Program(text: text, until: min(max(end, now + 60_000), now + 15 * 60_000))
        programs[r.id] = p
        return p
    }
}
