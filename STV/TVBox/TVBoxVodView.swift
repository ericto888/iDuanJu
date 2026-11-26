import SwiftUI

/// Floating controls of 点播: search with its scope, then categories + filter, the folder path, or the state of a search.
struct VodBar: View {
    @ObservedObject var pane: SitePane
    @ObservedObject var search: VodSearch
    let site: TVBoxSiteRef
    let searchable: [String]
    let blocked: Bool
    @State private var query = ""
    @State private var filtering = false

    var body: some View {
        VStack(spacing: 8) {
            TVBoxSearchField(placeholder: search.all ? "搜索全部 \(searchable.count) 个站点" : "搜索 \(site.site.name)", text: $query, id: "tvbox.search", onSubmit: submit) {
                HStack(spacing: 4) {
                    scope("当前站", false)
                    scope("全部站", true)
                }
            }
            .padding(.horizontal, 16)
            if search.active { VodSearchBar(search: search) }
            else if !pane.folders.isEmpty { path }
            else if !blocked && pane.tabs.count > 1 { categories }
        }
        .compatOnChange(of: query) { q in if q.isEmpty, search.active { search.clear() } }
        .compatOnChange(of: search.clears) { if !query.isEmpty { query = "" } }
        .sheet(isPresented: $filtering) { VodFilterSheet(pane: pane, tid: pane.category) }
        .tvboxShot("category", id: ObjectIdentifier(pane)) { pane.category = "1" }
        .tvboxShot("filter", id: ObjectIdentifier(pane)) { pane.category = "1"; pane.pick("1", "year", "2025"); filtering = true }
        .tvboxShot("failed", id: ObjectIdentifier(pane)) { pane.category = "5" }
        .tvboxShot("folders", id: ObjectIdentifier(pane)) { pane.category = "6" }
        .tvboxShot("folder", id: ObjectIdentifier(pane)) { pane.category = "6"; pane.enter(VodItem(uid: site.uid, vodId: "dir-0", title: "我的收藏夹", cover: "", remark: "", folder: true)) }
        .tvboxShot("search", id: ObjectIdentifier(pane)) { query = "山"; search.scope(true, query: query, current: site.uid, searchable: searchable) }
    }

    private func submit() { search.submit(query, current: site.uid, searchable: searchable) }

    private func scope(_ title: String, _ all: Bool) -> some View {
        Button { DS.tick(); search.scope(all, query: query, current: site.uid, searchable: searchable) } label: { Text(title) }
            .buttonStyle(ToneChipStyle(on: search.all == all, small: true))
            .fixedSize()
            .accessibilityIdentifier("tvbox.scope.\(title)")
            .accessibilityAddTraits(search.all == all ? .isSelected : [])
    }

    private var categories: some View {
        HStack(spacing: 0) {
            ChipRow(items: pane.tabs, selection: Binding(get: { pane.tab }, set: { pane.category = $0.id }), label: { $0.name }, idPrefix: "tvbox.category")
                .frame(height: 36)
            if !pane.category.isEmpty, !pane.filters(pane.category).isEmpty {
                RoundIconButton(systemName: "slider.horizontal.3", tone: pane.picked(pane.category).isEmpty ? .glass : .accent, size: 36) { filtering = true }
                    .padding(.trailing, 16)
                    .accessibilityLabel("筛选").accessibilityIdentifier("tvbox.filter")
            }
        }
    }

    /// 返回 › 上级 › 当前.
    private var path: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { pane.leave(to: pane.folders.count - 1) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("返回").font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(STVTheme.accent)
                    .frame(height: 36).contentShape(Rectangle())
                }
                .accessibilityIdentifier("tvbox.folder.back")
                ForEach(Array(pane.folders.enumerated()), id: \.offset) { i, f in
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(STVTheme.tertiary).accessibilityHidden(true)
                    Button { pane.leave(to: i + 1) } label: {
                        Text(f.title).font(.system(size: 14, weight: i == pane.folders.count - 1 ? .semibold : .regular))
                            .foregroundStyle(i == pane.folders.count - 1 ? STVTheme.text : STVTheme.secondary).lineLimit(1)
                            .frame(maxWidth: 200).frame(height: 36).contentShape(Rectangle())
                    }
                }
            }
            .buttonStyle(PressScale())
            .padding(.horizontal, 16)
        }
        .frame(height: 36)
        .compatScrollBounceBasedOnSize(axes: .horizontal)
    }
}

/// Progress of an aggregated search and its sites as chips.
private struct VodSearchBar: View {
    @ObservedObject var search: VodSearch

    var body: some View {
        if search.all {
            VStack(spacing: 8) {
                if !search.sites.isEmpty {
                    ChipRow(items: [""] + search.sites.map(\.uid), selection: Binding(get: { search.only }, set: { search.pick($0) }), label: title, neutral: { $0.isEmpty }, small: true, idPrefix: "tvbox.hits")
                        .frame(height: 32)
                }
                HStack(spacing: 8) {
                    if search.loading { DSSpinner(size: 12, tint: STVTheme.accent) }
                    Text("已返回 \(search.done) / \(search.total) 个站点" + (search.failed > 0 ? " · \(search.failed) 个失败" : ""))
                        .dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.secondary).monospacedDigit()
                        .accessibilityIdentifier("tvbox.search.progress")
                    Spacer(minLength: 0)
                    if search.loading {
                        Button { search.stop() } label: { MiniButtonLabel(title: "停止") }.buttonStyle(PressScale()).accessibilityIdentifier("tvbox.search.stop")
                    }
                }
                .frame(minHeight: 30)
                .padding(.horizontal, 20)
            }
        }
    }

    private func title(_ uid: String) -> String {
        if uid.isEmpty { return "全部 \(search.count)" }
        guard let s = search.sites.first(where: { $0.uid == uid }) else { return "" }
        return "\(s.name) \(s.count)"
    }
}

// MARK: - Pages

/// Recommendations, category lists, folders and search results of one site. Recent lists stay alive, so switching between
/// categories is instant and keeps the scroll position.
struct VodPages: View {
    @ObservedObject var pane: SitePane
    @ObservedObject var search: VodSearch
    let hub: TVBoxHubModel
    let repo: TVBoxRepo
    let site: TVBoxSiteRef
    let block: SiteBlock?
    let onTrust: () -> Void

    private enum Page: Hashable { case home, list(FeedKey), search }
    private struct Start: Hashable { let pane: ObjectIdentifier; let open: Bool }

    private var current: Page {
        if search.active { return .search }
        if let f = pane.folders.last { return .list(FeedKey(tid: f.vodId)) }
        if pane.category.isEmpty { return .home }
        return .list(FeedKey(tid: pane.category, extend: pane.picked(pane.category)))
    }

    var body: some View {
        Group {
            if let block, !search.active {
                VodBlocked(repo: repo, kind: site.site.kind, block: block, onTrust: onTrust)
            } else {
                KeptPages(current: current, limit: 4) { p in
                    switch p {
                    case .home: VodHomePage(pane: pane, hub: hub, name: site.site.name)
                    case .list(let key): VodFeedPage(feed: pane.feed(key), hub: hub)
                    case .search: VodSearchPage(search: search, hub: hub)
                    }
                }
                .id(ObjectIdentifier(pane))
            }
        }
        .task(id: Start(pane: ObjectIdentifier(pane), open: block == nil)) { if block == nil { pane.ensure() } }
    }
}

private struct VodHomePage: View {
    @ObservedObject var pane: SitePane
    let hub: TVBoxHubModel
    let name: String

    var body: some View {
        VodGrid(cells: pane.cells, loading: pane.loading && pane.cells.isEmpty, error: pane.error, empty: "这个站点没有推荐内容", hub: hub, retry: { pane.refresh() }) {
            VStack(alignment: .leading, spacing: 12) {
                TVBoxContinueRow()
                DSSectionHeader(title: "推荐", note: name, inset: 0) {
                    if pane.loading && !pane.cells.isEmpty { DSSpinner(size: 16) }
                    else {
                        Button { pane.refresh() } label: { MoreLabel(title: "刷新", icon: "arrow.clockwise") }
                            .buttonStyle(PressScale()).accessibilityIdentifier("tvbox.refresh")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { await pane.reload() }
    }
}

private struct VodFeedPage: View {
    @ObservedObject var feed: VodFeed
    let hub: TVBoxHubModel
    @Environment(\.keptPageActive) private var active

    private struct Turn: Hashable { let feed: ObjectIdentifier; let active: Bool }

    var body: some View {
        VodGrid(cells: feed.cells, loading: feed.loading, error: feed.error, empty: "这里还没有内容", hub: hub, more: { feed.more() }, retry: { feed.retry() }) { EmptyView() }
            .refreshable { await feed.reload() }
            .task(id: Turn(feed: ObjectIdentifier(feed), active: active)) { if active { feed.ensure() } else { feed.leave() } }
    }
}

private struct VodSearchPage: View {
    @ObservedObject var search: VodSearch
    let hub: TVBoxHubModel

    var body: some View {
        VodGrid(cells: search.shown, loading: search.loading, error: search.error, empty: "没有找到「\(search.submitted)」", sites: search.all ? search.names : [:], hub: hub,
                more: { search.more() }, retry: { search.retry() }) { EmptyView() }
            .id("\(search.submitted)|\(search.all)|\(search.only)")
    }
}

// MARK: - Filters

private struct VodFilterSheet: View {
    @ObservedObject var pane: SitePane
    let tid: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let picked = pane.picked(tid)
        DSSheet(title: "筛选", trailing: {
            Button { DS.tick(); pane.resetFilters(tid) } label: { MiniButtonLabel(title: "重置") }.buttonStyle(PressScale()).accessibilityIdentifier("tvbox.filter.reset")
        }, content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(pane.filters(tid).enumerated()), id: \.offset) { _, f in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(f.name).dsFont(13, .semibold, relativeTo: .footnote).foregroundStyle(STVTheme.secondary)
                            ChipWrap {
                                ForEach(Array(f.options.enumerated()), id: \.offset) { _, o in
                                    let on = (picked[f.key] ?? "") == o.value
                                    Button { DS.tick(); withAnimation(DS.select) { pane.pick(tid, f.key, o.value) } } label: { Text(o.name) }
                                        .buttonStyle(ToneChipStyle(on: on))
                                        .accessibilityAddTraits(on ? .isSelected : [])
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 20)
            }
        }, footer: {
            DSSheetFooter {
                Button { dismiss() } label: { PillButtonLabel(title: "完成", expand: true) }.buttonStyle(PressScale(scale: 0.98)).accessibilityIdentifier("tvbox.filter.done")
            }
        })
        .dsSheetChrome()
    }
}
