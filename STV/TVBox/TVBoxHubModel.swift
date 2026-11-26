import Combine
import Foundation

// State of the TVBox page. It outlives a trip to the detail page or the player, and every part observes only what it draws.

enum HubMode: String, CaseIterable { case vod = "点播", live = "直播" }

/// Card with an identity computed once: long lists are diffed on every update.
struct VodCell: Identifiable, Equatable {
    let id: String
    let item: VodItem

    static func unique(_ items: [VodItem], _ seen: inout Set<String>) -> [VodCell] {
        items.compactMap { i in
            let id = i.id + "|" + i.title
            return seen.insert(id).inserted ? VodCell(id: id, item: i) : nil
        }
    }
}

/// A category with its filters, or a folder.
struct FeedKey: Hashable {
    let tid: String
    var extend: [String: String] = [:]
}

/// One paged list of cards.
@MainActor
final class VodFeed: ObservableObject {
    @Published private(set) var cells: [VodCell] = []
    /// Also true before the first load, so a new page opens on its skeleton and not on "nothing here".
    @Published private(set) var loading = true
    @Published private(set) var error: String?
    private var hasMore = true
    private var page = 0
    private var seen = Set<String>()
    private var job: Task<Void, Never>?
    /// Load in charge: an older one that is still winding down writes nothing.
    private var turn = 0
    private var running = false
    private var loadingPage = 0
    /// The first page was given up before it was up to date.
    private var unfinished = true
    private let uid: String
    private let key: FeedKey

    init(_ uid: String, _ key: FeedKey) { self.uid = uid; self.key = key }
    deinit { job?.cancel() }

    func ensure() { if !running, unfinished || (page == 0 && cells.isEmpty) { start(1) } }
    /// Next page; a page that adds nothing ends the list, a failed one waits for 重试.
    func more() { if page > 0, hasMore, !running, error == nil { start(page + 1) } }
    /// Left for another list: a script site answers one request at a time, the next list must not wait for this one.
    func leave() {
        guard running else { return }
        turn += 1
        job?.cancel()
        running = false
        unfinished = loadingPage == 1
        loading = cells.isEmpty
    }
    func retry() { if cells.isEmpty { start(1, force: true) } else { start(page + 1) } }
    func reload() async {
        start(1, force: true)
        await job?.value
    }

    private func start(_ target: Int, force: Bool = false) {
        job?.cancel()
        turn += 1
        let mine = turn
        running = true
        loadingPage = target
        loading = true
        error = nil
        let stream = TVBoxStore.engine.category(uid, key.tid, target, key.extend, force: force)
        job = Task { [weak self] in
            do {
                for try await s in stream { self?.show(s, target, mine) }
                if !Task.isCancelled { self?.finish(nil, mine) }
            } catch { if !Task.isCancelled { self?.finish(error, mine) } }
        }
    }

    private func show(_ s: Snapshot<VodPage>, _ target: Int, _ mine: Int) {
        guard mine == turn else { return }
        if let e = s.error { error = e }
        // a refresh that comes back empty leaves what is there
        if target == 1, s.value.items.isEmpty, !cells.isEmpty { return }
        var fresh: [VodCell]
        if target == 1 {
            var known = Set<String>()
            fresh = VodCell.unique(s.value.items, &known)
            seen = known
            if fresh != cells { cells = fresh }
        } else {
            fresh = VodCell.unique(s.value.items, &seen)
            if !fresh.isEmpty { cells += fresh }
        }
        page = target
        hasMore = s.value.hasMore && !fresh.isEmpty
    }

    private func finish(_ e: Error?, _ mine: Int) {
        guard mine == turn else { return }
        if let e { error = tvboxErrorText(e) }
        running = false
        unfinished = false
        loading = false
    }
}

/// Everything shown for one 点播 site.
@MainActor
final class SitePane: ObservableObject {
    static let recommended = VodCategory(id: "", name: "推荐")

    let uid: String
    @Published private(set) var cells: [VodCell] = []
    @Published private(set) var categories: [VodCategory] = []
    /// Also true before the first load.
    @Published private(set) var loading = true
    @Published private(set) var error: String?
    /// "" = 推荐.
    @Published var category = ""
    /// Open `vod_tag=folder` entries, innermost last.
    @Published private(set) var folders: [VodItem] = []
    @Published private var picks: [String: [String: String]] = [:]
    private var home: VodHome?
    private var feeds: [(key: FeedKey, feed: VodFeed)] = []
    private var job: Task<Void, Never>?
    private var turn = 0

    init(_ uid: String) { self.uid = uid }
    deinit { job?.cancel() }

    /// 推荐 stays in place while its list may still arrive (categories come first).
    var tabs: [VodCategory] { (!cells.isEmpty || (loading && category.isEmpty) ? [Self.recommended] : []) + categories }
    var tab: VodCategory { category.isEmpty ? Self.recommended : categories.first { $0.id == category } ?? Self.recommended }

    func ensure() { if job == nil || (home == nil && !loading) { load(force: false) } }
    func reload() async {
        load(force: true)
        await job?.value
    }
    func refresh() { load(force: true) }

    private func load(force: Bool) {
        job?.cancel()
        turn += 1
        let mine = turn
        loading = true
        error = nil
        let stream = TVBoxStore.engine.home(uid, force: force)
        job = Task { [weak self] in
            do {
                for try await s in stream { self?.show(s, mine) }
                if !Task.isCancelled { self?.finish(nil, mine) }
            } catch { if !Task.isCancelled { self?.finish(error, mine) } }
        }
    }

    private func show(_ s: Snapshot<VodHome>, _ mine: Int) {
        guard mine == turn else { return }
        if let e = s.error { error = e }
        var next = s.value
        // parts a refresh did not get this time stay as they were
        if let old = home {
            if next.categories.isEmpty { next.categories = old.categories; next.filters = old.filters }
            if next.items.isEmpty { next.items = old.items }
        }
        if home != next {
            home = next
            var known = Set<String>()
            cells = VodCell.unique(next.items, &known)
            categories = next.categories
        }
        // a site without recommendations opens on its first category
        guard s.fresh else { return }
        let valid = category.isEmpty ? !cells.isEmpty : categories.contains { $0.id == category }
        if !valid { category = cells.isEmpty ? categories.first?.id ?? "" : "" }
    }

    private func finish(_ e: Error?, _ mine: Int) {
        guard mine == turn else { return }
        if let e { error = tvboxErrorText(e) }
        loading = false
    }

    // MARK: Filters

    func filters(_ tid: String) -> [VodFilter] { home?.filters[tid] ?? [] }
    func picked(_ tid: String) -> [String: String] {
        if let p = picks[tid] { return p }
        var out: [String: String] = [:]
        for f in filters(tid) where !f.initial.isEmpty { out[f.key] = f.initial }
        return out
    }
    func pick(_ tid: String, _ key: String, _ value: String) {
        var p = picked(tid)
        p[key] = value.isEmpty ? nil : value
        picks[tid] = p
    }
    func resetFilters(_ tid: String) { picks[tid] = nil }

    // MARK: Lists

    /// The last two dozen lists stay as they were left.
    func feed(_ key: FeedKey) -> VodFeed {
        if let i = feeds.firstIndex(where: { $0.key == key }) {
            if i < feeds.count - 1 { feeds.append(feeds.remove(at: i)) }
            return feeds[feeds.count - 1].feed
        }
        if feeds.count >= 24 { feeds.removeFirst() }
        let f = VodFeed(uid, key)
        feeds.append((key, f))
        return f
    }

    func enter(_ f: VodItem) { folders.append(f) }
    /// Back to the folder at `depth` (0 = out of all of them).
    func leave(to depth: Int) { if folders.count > depth { folders.removeLast(folders.count - depth) } }
}

/// Search in one site (paged) or in all of them (streaming).
@MainActor
final class VodSearch: ObservableObject {
    struct Hits: Hashable { let uid: String; let name: String; var count: Int }

    @Published private(set) var submitted = ""
    @Published private(set) var all = false
    /// Cells of the chosen site, or of every site.
    @Published private(set) var shown: [VodCell] = []
    /// Sites with hits, in the order they answered.
    @Published private(set) var sites: [Hits] = []
    @Published private(set) var names: [String: String] = [:]
    @Published private(set) var only = ""
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var failed = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// Bumped whenever the search is put away, so the field empties itself.
    @Published private(set) var clears = 0

    private var cells: [VodCell] = []
    private var seen = Set<String>()
    private var waiting: [SearchHit] = []
    private var remaining: [String] = []
    private var site = ""
    private var page = 0
    private var hasMore = false
    private var paused = false
    private var turn = 0
    private var job: Task<Void, Never>?
    private var flusher: Task<Void, Never>?

    deinit { job?.cancel(); flusher?.cancel() }

    var active: Bool { !submitted.isEmpty }
    var count: Int { cells.count }

    func clear() {
        reset()
        submitted = ""
        clears += 1
    }

    /// 当前站 / 全部站; a running query starts over in the new scope.
    func scope(_ everywhere: Bool, query: String, current: String, searchable: [String]) {
        guard everywhere != all else { return }
        all = everywhere
        if !query.trimmed.isEmpty, active || everywhere { submit(query, current: current, searchable: searchable) }
    }

    func submit(_ query: String, current: String, searchable: [String]) {
        let q = query.trimmed
        reset()
        submitted = q
        site = current
        if q.isEmpty { return }
        if all {
            remaining = searchable
            total = searchable.count
            stream()
        } else { next() }
    }

    func pick(_ uid: String) {
        only = uid
        filter()
    }

    /// The user's 停止: keeps what has arrived.
    func stop() {
        halt()
        flush()
        remaining = []
        loading = false
    }

    /// The page is off screen: nothing keeps searching behind the player. `resume` picks up where it stopped.
    func pause() {
        guard loading else { return }
        halt()
        flush()
        loading = false
        paused = true
    }

    func resume() {
        guard paused else { return }
        paused = false
        if all { stream() } else { next() }
    }

    func more() { if !all, page > 0, hasMore, !loading, error == nil { next() } }
    func retry() { if !all { next() } }

    /// Ends the running load; what it still delivers is ignored.
    private func halt() {
        job?.cancel()
        turn += 1
    }

    private func reset() {
        halt()
        flusher?.cancel()
        flusher = nil
        cells = []; seen = []; waiting = []; remaining = []
        shown = []; sites = []; names = [:]; only = ""
        done = 0; total = 0; failed = 0
        page = 0; hasMore = false; paused = false
        error = nil; loading = false
    }

    private func stream() {
        guard !remaining.isEmpty else { return }
        halt()
        let mine = turn
        loading = true
        let hits = TVBoxStore.engine.searchAll(remaining, submitted)
        job = Task { [weak self] in
            for await h in hits { self?.receive(h, mine) }
            if !Task.isCancelled { self?.finish(mine) }
        }
    }

    private func finish(_ mine: Int) {
        guard mine == turn else { return }
        flush()
        remaining = []
        loading = false
    }

    /// Answers come in bursts: the grid takes them a few times a second.
    private func receive(_ h: SearchHit, _ mine: Int) {
        guard mine == turn else { return }
        waiting.append(h)
        guard flusher == nil else { return }
        flusher = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            if !Task.isCancelled { self?.flush() }
        }
    }

    private func flush() {
        flusher?.cancel()
        flusher = nil
        guard !waiting.isEmpty else { return }
        let batch = waiting
        waiting = []
        let answered = Set(batch.map(\.ref.uid))
        remaining.removeAll { answered.contains($0) }
        done += batch.count
        failed += batch.reduce(0) { $0 + ($1.error == nil ? 0 : 1) }
        var found = sites, titles = names
        for h in batch {
            let fresh = VodCell.unique(Self.ranked(h.items, submitted), &seen)
            if fresh.isEmpty { continue }
            found.append(Hits(uid: h.ref.uid, name: h.ref.site.name, count: fresh.count))
            titles[h.ref.uid] = h.ref.site.name
            cells += fresh
        }
        if found.count != sites.count {
            sites = found
            names = titles
            filter()
        }
    }

    /// Exact and prefix matches of a site first.
    private static func ranked(_ list: [VodItem], _ q: String) -> [VodItem] {
        var groups: [[VodItem]] = [[], [], [], []]
        for i in list {
            let t = i.title
            groups[t == q ? 0 : t.hasPrefix(q) ? 1 : t.contains(q) ? 2 : 3].append(i)
        }
        return Array(groups.joined())
    }

    private func filter() { shown = only.isEmpty ? cells : cells.filter { $0.item.uid == only } }

    private func next() {
        halt()
        let mine = turn
        loading = true
        error = nil
        let target = page + 1, uid = site, q = submitted
        job = Task { [weak self] in
            do {
                let r = try await TVBoxStore.engine.search(uid, q, page: target)
                if !Task.isCancelled { self?.append(r, target, mine) }
            } catch { if !Task.isCancelled { self?.fail(error, mine) } }
        }
    }

    private func append(_ r: VodPage, _ target: Int, _ mine: Int) {
        guard mine == turn else { return }
        let fresh = VodCell.unique(r.items, &seen)
        cells += fresh
        page = target
        hasMore = r.hasMore && !fresh.isEmpty
        filter()
        loading = false
    }

    private func fail(_ e: Error, _ mine: Int) {
        guard mine == turn else { return }
        error = tvboxErrorText(e)
        loading = false
    }
}

/// The page as a whole: panes per site and live source, search, messages of `action` cards.
@MainActor
final class TVBoxHubModel: ObservableObject {
    @Published var mode: HubMode = .vod
    @Published var message: String?
    @Published private(set) var acting = false
    let search = VodSearch()
    private var sites: [(key: String, pane: SitePane)] = []
    private var lives: [(key: String, pane: LivePane)] = []

    func site(_ uid: String, _ stamp: String) -> SitePane {
        let key = stamp + "|" + uid
        if let hit = sites.first(where: { $0.key == key }) { return hit.pane }
        let p = SitePane(uid)
        if sites.count >= 8 { sites.removeFirst() }
        sites.append((key, p))
        return p
    }

    func live(_ uid: String, _ stamp: String) -> LivePane {
        let key = stamp + "|" + uid
        if let hit = lives.first(where: { $0.key == key }) { return hit.pane }
        let p = LivePane(uid)
        if lives.count >= 6 { lives.removeFirst() }
        lives.append((key, p))
        return p
    }

    /// A folder opens in the pane of its own site (a search may have found it elsewhere); an `action` runs in the spider.
    func open(_ item: VodItem) {
        if !item.action.isEmpty { act(item); return }
        guard item.folder else { return }
        let store = TVBoxStore.shared
        search.clear()
        site(item.uid, TVBoxStore.stamp(store.activeRepo)).enter(item)
        if let r = store.activeRepo { store.setLastSite(r.id, item.uid) }
    }

    private func act(_ item: VodItem) {
        guard !acting else { return }
        acting = true
        Task {
            do { message = Self.reply(try await TVBoxStore.engine.action(item.uid, item.action)) } catch { message = tvboxErrorText(error) }
            acting = false
        }
    }

    private static func reply(_ text: String) -> String {
        if let o = LenientJson.objectOrNull(text) {
            for k in ["msg", "toast", "message"] {
                let v = o.string(k)
                if !v.isEmpty, v != "null" { return v }
            }
        }
        let t = text.trimmed
        return t.isEmpty || t.hasPrefix("{") ? "已执行" : String(t.prefix(200))
    }
}
