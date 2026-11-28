import Combine
import SwiftUI

enum HomeTab: Hashable {
    case hongguo(HGRankGenre)
    case actorRank
    case huangguo(HuangguoSub)
    /// Opt-in long-video site (片源管理), listed after the built-in tabs.
    case site(DramaSource)
    var label: String {
        switch self {
        case .actorRank: "剧星榜"
        case .hongguo(let g): g == .all ? "红果榜单" : g.label
        case .huangguo(let s): "黄果" + s.label
        case .site(let s): s.label
        }
    }
    /// Label inside a source page's secondary chips.
    var subLabel: String {
        switch self {
        case .hongguo(.all): "全部榜单"
        case .hongguo(.ai): "红果 AI剧"
        case .huangguo(.ai): "黄果 AI 站"
        case .huangguo(let s): s.label
        default: label
        }
    }
}

/// Top-level home pages (横滑翻页 + 顶部分类条): one page per source; each source's own boards
/// (红果榜单 / 真人剧 / …) are secondary chips inside its page. Adult sites only appear once enabled in
/// 片源管理 (and unlocked with Face ID when the lock is on) — `SourceGate.visibleSites`.
enum HomeSource: Hashable, Identifiable {
    case hongguo, huangguo, ai
    case site(DramaSource)
    /// Telegram 频道 feed (not a drama source; its page is `ChannelFeedView`).
    case channels
    /// 漫画 (MangaHomeView).
    case manga
    /// 小说 (NovelHomeView: local TXT / EPUB bookshelf).
    case novel
    /// Stable unique identity (never collides even when a plugin shares a display name with a built-in source).
    var key: String {
        switch self {
        case .hongguo: "builtin:hongguo"
        case .huangguo: "builtin:huangguo"
        case .ai: "builtin:ai"
        case .site(let s): "site:" + s.rawValue
        case .channels: "builtin:channels"
        case .manga: "builtin:manga"
        case .novel: "builtin:novel"
        }
    }
    var id: String { key }
    var label: String {
        switch self {
        case .hongguo: "红果"
        case .huangguo: "黄果"
        case .ai: "AI剧"
        case .site(let s): s.label
        case .channels: "频道"
        case .manga: "漫画"
        case .novel: "小说"
        }
    }
    @MainActor var subs: [HomeTab] {
        switch self {
        case .hongguo: [.hongguo(.all), .hongguo(.human), .hongguo(.comic), .actorRank]
        case .huangguo: [.huangguo(.video), .huangguo(.legacy)]
        case .ai: SourceGate.shared.showHuangguo ? [.hongguo(.ai), .huangguo(.ai)] : [.hongguo(.ai)]
        case .site(let s): [.site(s)]
        case .channels, .manga, .novel: []
        }
    }
    private static func preferenceEnabled(_ key: String) -> Bool {
        guard let value = UserDefaults.standard.object(forKey: key) as? Bool else { return true }
        return value
    }
    @MainActor static var defaultAll: [HomeSource] {
        let g = SourceGate.shared
        let nonTVBoxSites = g.visibleSites.filter { src in
            if let k = src.cmsKey, let s = CMSStore.site(k), s.origin == "TVBox" || s.origin.hasPrefix("TVBox") { return false }
            return true
        }
        return [.hongguo] + (g.showHuangguo ? [.huangguo] : []) + [.ai] + nonTVBoxSites.map { .site($0) }
            + (preferenceEnabled("stv.home.showChannels") ? [.channels] : [])
            + (preferenceEnabled("stv.home.showManga") ? [.manga] : [])
            + (preferenceEnabled("stv.home.showNovel") ? [.novel] : [])
    }
    @MainActor static var all: [HomeSource] {
        let raw = defaultAll
        let byKey = Dictionary(uniqueKeysWithValues: raw.map { ($0.key, $0) })
        return SourceGate.shared.orderedKeys(raw.map(\.key)).compactMap { byKey[$0] }
    }
}

/// First page of one rank board. Each shelf observes only its own board, so a board arriving re-renders one shelf instead of
/// every section of every home page.
@MainActor
final class BoardFeed: ObservableObject {
    enum State {
        case idle, loaded([HGSeries]), failed(Error)
    }
    let board: BoardSpec
    @Published private(set) var state: State = .idle
    /// At most one network request per board, matching upstream's in-flight guard.
    private var loadingTask: Task<[HGSeries], Never>?

    init(_ b: BoardSpec) { board = b }

    var items: [HGSeries] { if case .loaded(let i) = state { return i }; return [] }
    var error: Error? { if case .failed(let e) = state { return e }; return nil }
    var hasAttemptedLoad: Bool {
        if loadingTask != nil { return true }
        if case .idle = state { return false }
        return true
    }

    /// Concurrent callers await the same in-flight request; they never start a second fetch.
    /// This keeps the plugin fallback-hero resolver deterministic without queuing refresh requests.
    func loadFirstPageIfNeeded(force: Bool = false) async -> [HGSeries] {
        if let loadingTask { return await loadingTask.value }
        if case .loaded = state, !force { return items }

        let task = Task { @MainActor in
            do {
                state = .loaded(try await board.fetch(HGPage(items: [], hasMore: true, nextOffset: nil), []).items)
            } catch {
                // A failed refresh keeps what is already on screen.
                if items.isEmpty { state = .failed(error) }
            }
            return items
        }
        loadingTask = task
        let result = await task.value
        loadingTask = nil
        return result
    }

    func load(force: Bool = false) {
        if loadingTask != nil { return }
        if case .loaded = state, !force { return }
        Task { _ = await loadFirstPageIfNeeded(force: force) }
    }
}
/// Keeps the board feeds alive across page switches and re-entries.
@MainActor
final class BoardCache {
    static let shared = BoardCache()
    private var feeds: [String: BoardFeed] = [:]
    func feed(_ b: BoardSpec) -> BoardFeed {
        if let f = feeds[b.id] { return f }
        let f = BoardFeed(b)
        feeds[b.id] = f
        return f
    }
}

// MARK: - Floating header plumbing

/// Vertical extent of a view in window coordinates, and the bottom safe area under it.
struct VSpan: Equatable {
    var top: CGFloat
    var bottom: CGFloat
    var inset: CGFloat = 0
}

/// Reports where a view really is. Frames scaled by a running navigation transition are skipped.
private struct SpanReader: View {
    @Binding var span: VSpan?
    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .global)
            let now = abs(f.width - g.size.width) < 0.5 ? VSpan(top: f.minY, bottom: f.maxY, inset: g.safeAreaInsets.bottom) : nil
            Color.clear.onAppear { set(now) }.compatOnChange(of: now) { set($0) }
        }
    }
    private func set(_ now: VSpan?) {
        guard let now else { return }
        if let s = span, abs(s.top - now.top) < 0.5, abs(s.bottom - now.bottom) < 0.5, abs(s.inset - now.inset) < 0.5 { return }
        span = now
    }
}

/// What the pages under the floating home header need: where their content rests and where to report "scrolled".
struct HomeHeader {
    /// False outside 发现, where the same pages have a bar of their own.
    var active = false
    /// From the header's lower edge to the floating tab bar, in window coordinates; nil until the first layout.
    var rest: VSpan?
    /// Where the pager starts, and how far it reaches under the tab bar.
    var pagerTop: CGFloat = 0
    var tabBar: CGFloat = 0
    var onScrolled: (Bool) -> Void = { _ in }
}

private struct HomeHeaderKey: EnvironmentKey { static let defaultValue = HomeHeader() }
extension EnvironmentValues {
    var homeHeader: HomeHeader {
        get { self[HomeHeaderKey.self] }
        set { self[HomeHeaderKey.self] = newValue }
    }
}

/// Insets from geometry, not from assumptions: a pager cell's position and safe area differ between systems, so a page
/// compares where its content would start and end with where the header and the tab bar really are.
private struct HomePageInset: ViewModifier {
    @Environment(\.homeHeader) private var header
    @State private var own: VSpan?
    /// A cell that is not on screen yet can report a frame of its own coordinate space: only believe plausible ones.
    private var placed: VSpan? { own.flatMap { abs($0.top - header.pagerTop) < 40 ? $0 : nil } }
    private var top: CGFloat {
        guard let rest = header.rest else { return 114 }
        return max(0, rest.top - (placed?.top ?? header.pagerTop))
    }
    private var bottom: CGFloat {
        guard header.tabBar > 0 else { return 0 }
        guard let rest = header.rest, let placed else { return header.tabBar }
        return max(0, placed.bottom - rest.bottom)
    }
    func body(content: Content) -> some View {
        if header.active {
            content
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: top) }
                .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: bottom) }
                .compatOnScrolled(threshold: 6) { header.onScrolled($0) }
                .background { SpanReader(span: $own) }
        } else {
            content
        }
    }
}

extension View {
    /// For the scroll view of a home page: rest below the floating header, scroll under it. No-op outside 发现.
    func homePageInset() -> some View { modifier(HomePageInset()) }
}

/// iPhone 首页交给系统处理底部安全区；iPad 保留原有分页布局补偿。
private struct HomeBottomSafeArea: ViewModifier {
    let indicator: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            content
        } else {
            content
                .padding(.bottom, indicator)
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

/// 发现页：玻璃搜索栏/筛选 + 来源分类条浮在内容上，下方按来源横滑翻页（红果 / 黄果 / AI剧 / 已开启的长视频站 / 频道 / 漫画 / 小说），
/// 分类条联动（选中项自动滚到居中、指示条跟随）。每页：二级榜单选择 → 竖海报 hero → 真实榜单分段。
/// 横滑冲突：hero 轮播区域内的横滑归轮播；其它区域横滑翻来源页；首页是根页面，没有系统侧滑返回。
struct HomeView: View {
    @ObservedObject private var gate = SourceGate.shared
    @ObservedObject private var pluginStore = PluginStore.shared
    @ObservedObject private var cmsStore = CMSStore.shared
    @AppStorage("stv.home.showChannels") private var showChannelSource = true
    @AppStorage("stv.home.showNovel") private var showNovelSource = true
    @AppStorage("stv.home.showManga") private var showMangaSource = true
    @State private var source: HomeSource
    @State private var scrollSourceKey: String?
    @State private var subs: [HomeSource: HomeTab]
    /// Cached: building it walks every site, plugin and 采集站, and it used to run several times per body.
    @State private var sources: [HomeSource] = HomeSource.all
    /// Lazy page mounting: only build the active page, its immediate ±1 swipe neighbors, and previously visited pages
    /// so jumping across tabs or installing a new plugin never instantiates all intermediate pages on the main thread.
    @State private var visited: Set<HomeSource>
    @State private var scrolled: [HomeSource: Bool] = [:]
    @State private var headerSpan: VSpan?
    @State private var safeSpan: VSpan?
    @State private var showChannels = false
    @State private var reorderingSources = false
    private var rest: VSpan? {
        guard let h = headerSpan, let s = safeSpan else { return nil }
        return VSpan(top: h.bottom, bottom: s.bottom)
    }
    private var bottomInset: CGFloat { safeSpan?.inset ?? GlassTabBar.clearance + 34 }
    /// Home-indicator part of the bottom safe area; the rest is the floating tab bar (none next to the iPad rail).
    private var indicator: CGFloat { bottomInset >= GlassTabBar.clearance ? bottomInset - GlassTabBar.clearance : bottomInset }
    private var pinned: Bool { scrolled[source] ?? false }
    private var sourceRevisionToken: String {
        "\(gate.revision)-\(pluginStore.revision)-\(cmsStore.revision)-\(showChannelSource)-\(showNovelSource)-\(showMangaSource)"
    }

    init() {
        let e = ProcessInfo.processInfo.environment["STV_HOME_TAB"] ?? ""
        var src = HomeSource.all.first ?? .hongguo, sub: [HomeSource: HomeTab] = [:]
        if e == "actorRank" { src = .hongguo; sub[.hongguo] = .actorRank }
        #if DEBUG
        if let s = DramaSource(rawValue: e), s.isLongVideo { src = .site(s) }
        if e == "huangguo" { src = .huangguo }
        if e == "ai" { src = .ai }
        if e == "channels" { src = .channels }
        if e == "manga" { src = .manga }
        if e == "novel" { src = .novel }
        #endif
        _source = State(initialValue: src)
        _scrollSourceKey = State(initialValue: src.key)
        _subs = State(initialValue: sub)
        _visited = State(initialValue: [src])
    }

    private func shouldMount(_ s: HomeSource) -> Bool {
        if s == source || visited.contains(s) { return true }
        guard let cur = sources.firstIndex(of: source), let idx = sources.firstIndex(of: s) else { return false }
        return abs(cur - idx) <= 1
    }

    private func pageCell(_ s: HomeSource) -> some View {
        HomePageSlot(
            source: s,
            mounted: shouldMount(s),
            tab: Binding(get: { subs[s] ?? s.subs.first ?? .hongguo(.all) }, set: { subs[s] = $0 })
        )
        .environment(\.homeHeader, HomeHeader(active: true, rest: rest, pagerTop: safeSpan?.top ?? 0, tabBar: 0, onScrolled: { v in
            guard s == source else { return }
            if scrolled[s] != v {
                withAnimation(DS.select) { scrolled[s] = v }
            }
        }))
    }

    @ViewBuilder
    private var pagerContent: some View {
        if #available(iOS 17.0, *) {
            // Native paging avoids UIPageViewController selection desyncs when sources are added,
            // removed, reordered, or mounted lazily.
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(sources, id: \.key) { s in
                            pageCell(s)
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollSourceKey)
                .scrollIndicators(.hidden)
            }
        } else {
            TabView(selection: $source) {
                ForEach(sources) { s in
                    pageCell(s)
                        .tag(s)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .id(sources.map(\.key).joined(separator: "|"))
        }
    }

    var body: some View {
        pagerContent
        // Preserve the branch's iPhone system-safe-area handling and iPad layout compensation.
        .overlay(alignment: .bottom) {
            if bottomInset > indicator {
                LinearGradient(colors: [STVTheme.bg.opacity(0), STVTheme.bg], startPoint: .top, endPoint: .bottom)
                    .frame(height: 36).allowsHitTesting(false)
            }
        }
        .modifier(HomeBottomSafeArea(indicator: indicator))
        .background { SpanReader(span: $safeSpan).ignoresSafeArea(.keyboard) }
        .overlay(alignment: .top) { header }
        .dsAmbient(visible: !pinned)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showChannels, onDismiss: { reorderingSources = false }) { channelPanel }
        .compatOnChange(of: sourceRevisionToken) { _ in refreshSources() }
        .compatOnChange(of: source) { next in
            if !visited.contains(next) { visited.insert(next) }
            if scrollSourceKey != next.key {
                let prevIdx = scrollSourceKey.flatMap { key in sources.firstIndex(where: { $0.key == key }) }
                let nextIdx = sources.firstIndex(of: next)
                if let prevIdx, let nextIdx, abs(prevIdx - nextIdx) == 1 {
                    withAnimation(DS.select) { scrollSourceKey = next.key }
                } else {
                    scrollSourceKey = next.key
                }
            }
        }
        .compatOnChange(of: scrollSourceKey) { nextKey in
            guard let nextKey, nextKey != source.key,
                  let next = sources.first(where: { $0.key == nextKey }) else { return }
            if !visited.contains(next) { visited.insert(next) }
            source = next
        }
        .task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await NovelStore.prewarm()
            await LegadoSourceStore.prewarm()
        }
        .onAppear { refreshSources() }
    }

    private func refreshSources() {
        let now = HomeSource.all
        if now != sources { sources = now }
        if !now.contains(source), let first = now.first { source = first }
        if !visited.contains(source) { visited.insert(source) }
        if scrollSourceKey != source.key { scrollSourceKey = source.key }
    }

    /// Use the currently visible home source as the initial search provider.
    private var activeSearchSource: DramaSource {
        switch source {
        case .hongguo: return .hongguo
        case .huangguo: return .huangguo
        case .site(let site): return site
        case .ai:
            if case .some(.huangguo(.ai)) = subs[.ai] { return .huangguo }
            return .hongguo
        case .channels, .manga, .novel: return .hongguo
        }
    }

    // MARK: Header (search + filter, source bar)

    private var header: some View {
        VStack(spacing: 0) {
            if !homeScrollChromeHidden {
                LiquidGlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        NavigationLink(value: Route.searchFromSource(activeSearchSource)) {
                            DSSearchBarLabel()
                                .padding(.horizontal, 16).frame(height: 46).contentShape(Capsule())
                                .liquidGlassCapsule(interactive: true)
                        }
                        .buttonStyle(GlassPress()).accessibilityLabel("搜索").accessibilityIdentifier("home.search")
                        Button { showChannels = true } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 14, weight: .semibold))
                                Text("筛选").font(.system(size: 14, weight: .medium))
                            }
                            .foregroundStyle(STVTheme.text)
                            .padding(.horizontal, 16).frame(height: 46).contentShape(Capsule())
                            .liquidGlassCapsule(interactive: true)
                        }
                        .buttonStyle(GlassPress()).accessibilityLabel("筛选与全部频道").accessibilityIdentifier("home.filter")
                    }
                }
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            HomeChannelBar(items: sources, selection: $source, label: \.label, ink: STVTheme.text)
                .padding(.top, homeScrollChromeHidden ? 0 : 12)
        }
        .padding(.top, homeScrollChromeHidden ? 0 : 8)
        .padding(.bottom, 8)
        .animation(DS.select, value: homeScrollChromeHidden)
        .background { LiquidEdgeFade(visible: pinned) }
        .background { SpanReader(span: $headerSpan) }
    }

    private var channelPanel: some View {
        DSSheet("频道", subtitle: reorderingSources ? "调整首页顶部来源顺序" : "选择来源、排序与榜单") {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Text("首页来源").dsFont(13, .semibold, relativeTo: .footnote).foregroundStyle(STVTheme.secondary)
                            Spacer(minLength: 0)
                            if reorderingSources && !gate.homeOrder.isEmpty {
                                Button {
                                    DS.tick()
                                    withAnimation(DS.select) {
                                        gate.resetHomeOrder()
                                        refreshSources()
                                    }
                                } label: {
                                    Text("恢复默认").dsFont(13, .medium, relativeTo: .footnote).foregroundStyle(STVTheme.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("home.order.reset")
                            }
                            if sources.count > 1 {
                                Button {
                                    DS.tick()
                                    withAnimation(DS.select) { reorderingSources.toggle() }
                                } label: {
                                    Text(reorderingSources ? "完成" : "排序")
                                        .dsFont(13, .semibold, relativeTo: .footnote)
                                        .foregroundStyle(STVTheme.accent)
                                        .padding(.horizontal, 12).padding(.vertical, 5)
                                        .background(STVTheme.accentSoft, in: Capsule())
                                }
                                .buttonStyle(PressScale())
                                .accessibilityIdentifier("home.order.toggle")
                            }
                        }
                        if reorderingSources {
                            HomeSourceOrderRows(sources: sources) { updated in
                                sources = updated
                                gate.setHomeOrder(updated.map(\.key))
                            }
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10)], spacing: 10) {
                                ForEach(sources) { s in
                                    let on = s == source
                                    Button {
                                        DS.tick()
                                        source = s
                                        showChannels = false
                                    } label: {
                                        Text(s.label).dsFont(14, on ? .semibold : .regular, relativeTo: .subheadline)
                                            .foregroundStyle(on ? STVTheme.accent : STVTheme.text)
                                            .lineLimit(1).minimumScaleFactor(0.8)
                                            .frame(maxWidth: .infinity, minHeight: 42)
                                            .background(on ? STVTheme.accentSoft : STVTheme.glass,
                                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                            .contentShape(RoundedRectangle(cornerRadius: 14))
                                    }
                                    .buttonStyle(PressScale()).accessibilityAddTraits(on ? .isSelected : [])
                                    .accessibilityIdentifier("panel.source.\(s.label)")
                                }
                            }
                        }
                    }

                    if !reorderingSources {
                        ForEach(sources.filter { !$0.subs.isEmpty }) { s in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(s.label + " · 板块").dsFont(13, .semibold, relativeTo: .footnote).foregroundStyle(STVTheme.secondary)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                                    ForEach(s.subs, id: \.self) { t in
                                        let on = s == source && (subs[s] ?? s.subs[0]) == t
                                        Button { subs[s] = t; source = s; showChannels = false } label: {
                                            Text(t.subLabel).dsFont(14, on ? .semibold : .regular, relativeTo: .subheadline)
                                                .foregroundStyle(on ? STVTheme.accent : STVTheme.text)
                                                .lineLimit(1).minimumScaleFactor(0.8)
                                                .frame(maxWidth: .infinity, minHeight: 44)
                                                .background(on ? STVTheme.accentSoft : STVTheme.glass,
                                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                                .contentShape(RoundedRectangle(cornerRadius: 14))
                                        }
                                        .buttonStyle(PressScale()).accessibilityAddTraits(on ? .isSelected : [])
                                        .accessibilityIdentifier("panel.\(s.label).\(t.subLabel)")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.channelPanel")
        .dsSheetChrome([.medium, .large])
    }
}

/// Shared inline reorder list for Home sources (supports 置顶 / 上移 / 下移, used in both Home sheet & 片源管理).
struct HomeSourceOrderRows: View {
    let sources: [HomeSource]
    let onChange: ([HomeSource]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { idx, item in
                HStack(spacing: 12) {
                    Text("\(idx + 1)")
                        .dsFont(12, .bold, relativeTo: .caption)
                        .foregroundStyle(idx == 0 ? STVTheme.accent : STVTheme.tertiary)
                        .frame(width: 22, alignment: .center)
                    Text(item.label)
                        .dsFont(15, .medium, relativeTo: .body)
                        .foregroundStyle(STVTheme.text)
                        .lineLimit(1)
                    if case .site(let s) = item {
                        DSTag(text: s.pluginID != nil ? "插件" : (s.cmsKey != nil ? "采集站" : "内置"))
                    }
                    Spacer(minLength: 0)
                    Button { moveTop(idx) } label: {
                        Image(systemName: "arrow.up.to.line")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(idx > 0 ? STVTheme.secondary : STVTheme.tertiary.opacity(0.35))
                            .frame(width: 34, height: 34).contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale()).disabled(idx == 0).accessibilityLabel("置顶 \(item.label)")
                    Button { move(idx, by: -1) } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(idx > 0 ? STVTheme.text : STVTheme.tertiary.opacity(0.35))
                            .frame(width: 34, height: 34).contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale()).disabled(idx == 0).accessibilityLabel("上移 \(item.label)")
                    Button { move(idx, by: 1) } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(idx < sources.count - 1 ? STVTheme.text : STVTheme.tertiary.opacity(0.35))
                            .frame(width: 34, height: 34).contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale()).disabled(idx >= sources.count - 1).accessibilityLabel("下移 \(item.label)")
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                if idx < sources.count - 1 { Hairline().padding(.leading, 48) }
            }
        }
        .background(STVTheme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func moveTop(_ idx: Int) {
        guard idx > 0, sources.indices.contains(idx) else { return }
        DS.tick()
        var copy = sources
        let picked = copy.remove(at: idx)
        copy.insert(picked, at: 0)
        withAnimation(DS.select) { onChange(copy) }
    }

    private func move(_ idx: Int, by delta: Int) {
        let target = idx + delta
        guard sources.indices.contains(idx), sources.indices.contains(target) else { return }
        DS.tick()
        var copy = sources
        copy.swapAt(idx, target)
        withAnimation(DS.select) { onChange(copy) }
    }
}

/// Stable identity wrapper for lazily mounted pages in the native pager.
private struct HomePageSlot: View {
    let source: HomeSource
    let mounted: Bool
    @Binding var tab: HomeTab

    var body: some View {
        ZStack {
            if mounted {
                HomePage(source: source, tab: $tab)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Built only when the pager reaches it: 频道 / 漫画 / 小说 load their stores from disk on first use, and constructing those
/// views together with the header used to do all of that at launch.
private struct HomePage: View {
    let source: HomeSource
    @Binding var tab: HomeTab
    var body: some View {
        switch source {
        case .channels: ChannelFeedView(embedded: true)
        case .manga: MangaHomeView(embedded: true)
        case .novel: NovelHomeView(embedded: true)
        default: HomeFeedPage(source: source, tab: $tab)
        }
    }
}

/// One source page: secondary board chips → hero → real board sections. Vertical scroll inside a horizontal pager.
private struct HomeFeedPage: View {
    let source: HomeSource
    @Binding var tab: HomeTab
    @ObservedObject private var pluginStore = PluginStore.shared
    @State private var legacyChannels: [HuangguoChannel] = []
    @State private var legacyError: Error?
    @State private var pluginHomeSource: String?
    @State private var pluginFeatured: [HGSeries] = []
    @State private var pluginHomeError: Error?
    @State private var fallbackHeroSource: String?
    @State private var fallbackHeroBoardID: String?
    /// Invalidates older homepage requests when the selected tab changes or a refresh/retry starts.
    @State private var pluginHomeRequestID = UUID()
    @State private var featuredIndex = 0
    private let gutter: CGFloat = 16
    /// DEBUG `STV_HOME_SCROLL=bottom` opens the feed scrolled to the end (simulator screenshots).
    private static var debugAnchor: UnitPoint? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STV_HOME_SCROLL"] == "bottom" { return .bottom }
        #endif
        return nil
    }

    var body: some View {
        // Only plugins opting into categoryShelves use the multi-shelf native homepage.
        // CMS and legacy JS plugins keep their existing DynamicSiteFeed behavior.
        if case .site(let site) = tab,
           site.cmsKey != nil || (site.pluginID != nil && !usesCategoryShelves(site)) {
            DynamicSiteFeed(source: site)
        } else {
            rankFeed
        }
    }

    private func usesCategoryShelves(_ site: DramaSource) -> Bool {
        guard let id = site.pluginID else { return false }
        return PluginHomeFeatures.usesCategoryShelves(PluginStore.snapshot(id)?.manifest.homeFeatures)
    }

    private var rankFeed: some View {
        let allBoards = self.boards
        let pluginID = sourcePluginID
        let features = pluginID.flatMap { PluginStore.snapshot($0)?.manifest.homeFeatures }
        let boards = allBoards
        let hasFeatured = PluginHomeFeatures.showsFeaturedCarousel(features, itemCount: pluginFeatured.count)
        let fallbackHero = pluginID == nil
            ? boards.first
            : boards.first(where: { $0.id == fallbackHeroBoardID && fallbackHeroSource == pluginID })
        let loadingPluginHome = pluginID.map { PluginStore.snapshot($0)?.manifest.capabilities.contains("home") == true && pluginHomeSource != $0 } ?? false
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if source.subs.count > 1 { subChips } else if case .site = source { boardChips(allBoards) }
                if loadingPluginHome {
                    if let error = pluginHomeError {
                        ErrorStateView(error: error) {
                            if case .site(let site) = source {
                                Task {
                                    let requestID = UUID()
                                    pluginHomeRequestID = requestID
                                    fallbackHeroSource = nil
                                    fallbackHeroBoardID = nil
                                    await loadPluginHome(site, requestID: requestID)
                                    guard isCurrentPluginHomeRequest(requestID, site: site) else { return }
                                    await resolveFallbackHero(site, requestID: requestID)
                                }
                            }
                        }
                    } else {
                        HomeCardsSkeleton(landscape: true).padding(.horizontal, 16).padding(.top, 24)
                    }
                } else if tab == .actorRank {
                    ActorRankList().padding(.vertical, 16)
                } else {
                    // Lazy: boards below the fold are neither built nor requested until they are scrolled to.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if boards.isEmpty && pluginID != nil {
                            DSEmptyState("暂无可用分类", systemImage: "rectangle.stack", message: "该站源暂未提供有效分类。")
                                .padding(.top, 24)
                        } else if hasFeatured {
                            HomePluginFeaturedSection(title: source.label, items: pluginFeatured, index: $featuredIndex)
                        } else if let fallbackHero {
                            // If no valid declared featured items exist, use the first category
                            // (in source order) that actually has content.
                            HomeHeroSection(feed: BoardCache.shared.feed(fallbackHero), board: fallbackHero).id(fallbackHero.id)
                        }
                        if source == .hongguo { HomeContinueSection() }
                        sections(boards, featuredIDs: hasFeatured ? Set(pluginFeatured.map(\.id)) : [])
                    }
                }
            }
            .padding(.bottom, 24)
            .compatScrollContent()
        }
        .scrollIndicators(.hidden)
        .compatDefaultScrollAnchor(Self.debugAnchor)
        .accessibilityIdentifier("home.page.\(source.label)")
        .homePageInset()
        .refreshable {
            if tab == .actorRank {
                await ActorRankStore.shared.reload()
            } else {
                if case .site(let site) = tab, usesCategoryShelves(site) {
                    let requestID = UUID()
                    pluginHomeRequestID = requestID
                    pluginHomeSource = nil
                    pluginHomeError = nil
                    fallbackHeroSource = nil
                    fallbackHeroBoardID = nil
                    await loadPluginHome(site, requestID: requestID)
                    guard isCurrentPluginHomeRequest(requestID, site: site) else { return }
                    // Refresh only feeds that were already active; do not eagerly request every
                    // shelf just because the homepage was pulled down.
                    for board in self.boards {
                        guard isCurrentPluginHomeRequest(requestID, site: site) else { return }
                        let feed = BoardCache.shared.feed(board)
                        if feed.hasAttemptedLoad { _ = await feed.loadFirstPageIfNeeded(force: true) }
                    }
                    guard isCurrentPluginHomeRequest(requestID, site: site) else { return }
                    await resolveFallbackHero(site, requestID: requestID)
                } else {
                    self.boards.forEach { BoardCache.shared.feed($0).load(force: true) }
                }
            }
        }
        .task(id: tab) {
            if case .site(let site) = tab, usesCategoryShelves(site) {
                let requestID = UUID()
                pluginHomeRequestID = requestID
                await loadPluginHome(site, requestID: requestID)
                guard isCurrentPluginHomeRequest(requestID, site: site) else { return }
                await resolveFallbackHero(site, requestID: requestID)
            } else if case .huangguo(.legacy) = tab, legacyChannels.isEmpty {
                await loadLegacy()
            }
        }
    }

    private var sourcePluginID: String? {
        if case .site(let site) = source { return site.pluginID }
        return nil
    }

    private func isCurrentPluginHomeRequest(_ requestID: UUID, site: DramaSource) -> Bool {
        !Task.isCancelled && pluginHomeRequestID == requestID && tab == .site(site)
    }

    private func loadPluginHome(_ site: DramaSource, requestID: UUID) async {
        guard isCurrentPluginHomeRequest(requestID, site: site),
              let id = site.pluginID, pluginHomeSource != id else { return }
        pluginHomeError = nil
        guard let manifest = PluginStore.snapshot(id)?.manifest,
              manifest.capabilities.contains("home"),
              PluginHomeFeatures.usesCategoryShelves(manifest.homeFeatures),
              let provider = Sites.provider(site) as? JSVideoProvider else {
            guard isCurrentPluginHomeRequest(requestID, site: site) else { return }
            pluginHomeSource = id
            pluginFeatured = []
            return
        }
        do {
            let data = try await provider.homeData()
            guard isCurrentPluginHomeRequest(requestID, site: site) else { return }
            pluginFeatured = data.featured
            pluginHomeSource = id
        } catch {
            guard isCurrentPluginHomeRequest(requestID, site: site) else { return }
            pluginHomeError = error
            pluginHomeSource = nil
        }
    }

    private func resolveFallbackHero(_ site: DramaSource, requestID: UUID, force: Bool = false) async {
        guard isCurrentPluginHomeRequest(requestID, site: site),
              let id = site.pluginID,
              usesCategoryShelves(site),
              !PluginHomeFeatures.showsFeaturedCarousel(PluginStore.snapshot(id)?.manifest.homeFeatures, itemCount: pluginFeatured.count),
              fallbackHeroSource != id || force else { return }
        fallbackHeroSource = nil
        fallbackHeroBoardID = nil
        let first = await PluginHomeFeatures.firstPopulated(self.boards) { board in
            guard self.isCurrentPluginHomeRequest(requestID, site: site) else { return false }
            let items = await BoardCache.shared.feed(board).loadFirstPageIfNeeded(force: force)
            return self.isCurrentPluginHomeRequest(requestID, site: site) && !items.isEmpty
        }
        guard isCurrentPluginHomeRequest(requestID, site: site) else { return }
        fallbackHeroBoardID = first?.id
        fallbackHeroSource = id
    }

    /// ui-redesign 10: secondary boards are the same segmented control as 找剧.
    private var subChips: some View {
        SegmentedTabs(items: source.subs, selection: $tab, label: \.subLabel, idPrefix: "home.sub")
            .padding(.horizontal, gutter)
            .padding(.top, 8)
    }

    /// Long-video site pages: same chip row height as 红果/黄果 (top never jumps); each chip opens that board.
    private func boardChips(_ boards: [BoardSpec]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(Array(boards.enumerated()), id: \.element.id) { i, b in
                    NavigationLink(value: Route.board(b)) { Text(b.title) }
                    .buttonStyle(ToneChipStyle(on: i == 0, neutral: true))
                    .accessibilityIdentifier("home.sub.\(b.title)")
                }
            }.padding(.horizontal, gutter).padding(.vertical, 5)
        }
        .frame(height: 42)
        .compatScrollBounceBasedOnSize(axes: .horizontal)
        .mask(FadeMask())
        .padding(.top, 8)
    }

    // MARK: Data

    private var boards: [BoardSpec] {
        switch tab {
        case .hongguo(let g): g.subs.map { BoardSpec(kind: .hongguo(g, $0)) }
        case .huangguo(.ai): HuangguoClient.aiChannels.map { BoardSpec(kind: .huangguo($0)) }
        case .huangguo(.video): HuangguoClient.videoChannels.map { BoardSpec(kind: .huangguo($0)) }
        case .huangguo(.legacy): legacyChannels.map { BoardSpec(kind: .huangguo($0)) }
        case .site(let s): (Sites.provider(s)?.categories ?? []).map { category in
            let numbered = s.pluginID.map { PluginHomeFeatures.usesNumbering(PluginStore.snapshot($0)?.manifest.homeFeatures) } ?? true
            return BoardSpec(kind: .site(s, category), numbered: numbered)
        }
        case .actorRank: []
        }
    }

    @ViewBuilder private func sections(_ boards: [BoardSpec], featuredIDs: Set<String> = []) -> some View {
        if case .huangguo(.legacy) = tab, legacyChannels.isEmpty {
            if let legacyError { ErrorStateView(error: legacyError) { Task { await loadLegacy() } } }
            else { HomeCardsSkeleton(landscape: false).padding(.horizontal, gutter).padding(.top, 24) }
        } else {
            let landscape: Bool = { if case .site(let s) = tab { return s.isLongVideo } else { return false } }()
            ForEach(Array(boards.enumerated()), id: \.element.id) { n, b in
                HomeBoardSection(feed: BoardCache.shared.feed(b), board: b,
                                 skip: featuredIDs.isEmpty && b.id == (fallbackHeroBoardID ?? (pluginIDForCurrentTab == nil ? boards.first?.id : nil)) ? HomeHeroSection.count : 0,
                                 landscape: landscape, excludeIDs: featuredIDs) {
                    boards.forEach { BoardCache.shared.feed($0).load(force: true) }
                }
                .padding(.top, 24)
            }
        }
    }

    private var pluginIDForCurrentTab: String? {
        if case .site(let site) = tab { return site.pluginID }
        return nil
    }

    private func loadLegacy() async {
        do { legacyChannels = try await HuangguoClient.shared.legacyChannels(); legacyError = nil } catch { legacyError = error }
    }
}

/// Featured items returned by home() and explicitly enabled by manifest.homeFeatures.
private struct HomePluginFeaturedSection: View {
    let title: String
    let items: [HGSeries]
    @Binding var index: Int
    var body: some View {
        let picks = Array(items.prefix(5))
        if !picks.isEmpty {
            PosterHero(board: title, picks: picks, index: $index)
                .padding(.horizontal, 16).padding(.top, 16)
                .transition(.opacity)
        }
    }
}

/// Hero of the first board; observes that board only.
private struct HomeHeroSection: View {
    static let count = 5
    @ObservedObject var feed: BoardFeed
    let board: BoardSpec
    @State private var index = 0
    var body: some View {
        let picks = Array(feed.items.prefix(Self.count))
        Group {
            if !picks.isEmpty {
                PosterHero(board: board.title, picks: picks, index: $index)
                    .padding(.horizontal, 16).padding(.top, 16)
                    .transition(.opacity)
            } else if feed.error == nil {
                ShimmerBlock(corner: 22).frame(height: 177).padding(.horizontal, 16).padding(.top, 16)
            }
        }
        .animation(.easeOut(duration: 0.25), value: picks.isEmpty)
        .onAppear { feed.load() }
    }
}

/// Watch history lives in its own view: playback writes progress every few seconds, which must not re-render the feed.
private struct HomeContinueSection: View {
    @ObservedObject private var library = LibraryStore.shared
    var body: some View {
        let items = Array(library.continueWatching.prefix(10))
        if !items.isEmpty { HomeContinueRow(items: items).padding(.top, 24) }
    }
}

/// One board: shelf, skeleton or inline error.
private struct HomeBoardSection: View {
    @ObservedObject var feed: BoardFeed
    let board: BoardSpec
    /// Items already shown by the hero above.
    let skip: Int
    let landscape: Bool
    var excludeIDs: Set<String> = []
    let reloadAll: () -> Void
    @State private var verify: VerifyTarget?

    var body: some View {
        Group {
            if let e = feed.error {
                if skip > 0 {
                    ErrorStateView(error: e, retry: reloadAll)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HomeShelf(title: board.title, note: nil, items: [], more: board)
                        HStack(spacing: 10) {
                            Text(e.verifyTarget != nil ? "需要站点验证" : "加载失败").dsFont(13, relativeTo: .footnote).foregroundStyle(STVTheme.secondary)
                            Spacer(minLength: 0)
                            if let t = e.verifyTarget { Button { verify = t } label: { MiniButtonLabel(title: "去验证") } }
                            Button { feed.load(force: true) } label: { MiniButtonLabel(title: "重试") }
                        }
                        .buttonStyle(PressScale())
                        .padding(.horizontal, 16)
                    }
                }
            } else if case .loaded(let items) = feed.state {
                // 第一个榜单一律跳过 hero 里已展示的剧（数据不够时也跳过，只剩标题和「全部」）。
                HomeShelf(title: board.title, note: nil,
                          items: Array(items.filter { !excludeIDs.contains($0.id) }.dropFirst(skip).prefix(12)), more: board)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    DSSectionHeader(title: board.title)
                    HomeCardsSkeleton(landscape: landscape).padding(.horizontal, 16)
                }
            }
        }
        .onAppear { feed.load() }
        .sheet(item: $verify) { t in SiteVerifySheet(target: t, onDone: reloadAll) }
    }
}

private struct HomeCardsSkeleton: View {
    let landscape: Bool
    var body: some View {
        HStack(alignment: .top, spacing: landscape ? 12 : 10) {
            ForEach(0..<(landscape ? 2 : 3), id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    ShimmerBlock().aspectRatio(landscape ? 16/9 : 3/4, contentMode: .fit)
                    ShimmerBlock(corner: 5).frame(height: 12).frame(maxWidth: 90)
                }
            }
        }
    }
}

/// CMS / JS plugin home: every returned category is a selectable module, and the selected one pages its own list.
private struct DynamicSiteFeed: View {
    let source: DramaSource
    @State private var categories: [SiteCategory] = []
    @State private var selected = ""
    @StateObject private var pager = Pager()
    @State private var didLoad = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Color.clear.frame(height: 0).id("dynamic.top")
                    if categories.count > 1 { chips }
                    if let e = pager.error, pager.items.isEmpty {
                        ErrorStateView(error: e) { reload(selected) }
                    } else if pager.items.isEmpty && pager.isLoading {
                        HomeCardsSkeleton(landscape: source.isLongVideo).padding(.horizontal, 16)
                    } else if pager.items.isEmpty {
                        DSEmptyState("该分类暂无内容", systemImage: "rectangle.stack", message: "部分采集站的父分类不直接提供资源，请选择动作片、国产剧等具体分类。")
                    } else {
                        NumberedGrid(items: pager.items, numbered: false, hasMore: pager.hasMore, loading: pager.isLoading) { pager.loadMore() }
                    }
                }
                .padding(.vertical, 8)
                .compatScrollContent()
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("home.page.\(source.label)")
            .refreshable { await refresh() }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("dynamic.top", anchor: .top) }
                    Task { await refresh() }
                } label: {
                    Group {
                        if pager.isLoading { DSSpinner(size: 18, tint: STVTheme.text) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 17, weight: .semibold)).foregroundStyle(STVTheme.text) }
                    }
                    .frame(width: 48, height: 48)
                    .liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
                }
                .buttonStyle(GlassPress())
                .disabled(pager.isLoading)
                .padding(.trailing, 18).padding(.bottom, 24)
                .accessibilityLabel("刷新列表")
                .accessibilityIdentifier("home.dynamic.refresh")
            }
            .homePageInset()
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            await refresh()
        }
    }

    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(categories) { c in
                        let on = c.id == selected
                        Button { DS.tick(); withAnimation(DS.select) { selected = c.id }; reload(c.id) } label: { Text(c.title) }
                            .buttonStyle(ToneChipStyle(on: on))
                            .id(c.id)
                            .accessibilityIdentifier("home.module.\(c.title)")
                            .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }.padding(.horizontal, 16)
            }
            .frame(height: 34)
            .compatScrollBounceBasedOnSize(axes: .horizontal)
            .compatOnChange(of: selected) { id in withAnimation(DS.select) { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private func refresh() async {
        let loaded = await Self.loadCategories(source)
        categories = loaded
        let id = loaded.contains { $0.id == selected } ? selected : (loaded.first?.id ?? "")
        selected = id
        reload(id)
    }

    private func reload(_ id: String) {
        let source = source
        pager.reset { prev, _ in
            guard let provider = Sites.provider(source) else { throw ProviderError.unsupported(source.label) }
            let category = SiteCategory(id: id, title: "", path: id)
            let page = try await provider.list(category, page: max(1, prev.nextOffset ?? 1))
            if (prev.nextOffset ?? 1) <= 1, source.pluginID != nil {
                let latestCats = provider.categories
                if !latestCats.isEmpty {
                    await MainActor.run {
                        if categories.map(\.id) != latestCats.map(\.id) { categories = latestCats }
                    }
                }
            }
            return page
        }
    }

    private static func loadCategories(_ source: DramaSource) async -> [SiteCategory] {
        if let key = source.cmsKey {
            var stored = CMSStore.site(key)?.categories ?? []
            if let site = CMSStore.site(key), let fresh = try? await MacCMSProvider.fetchCategories(api: site.api), !fresh.isEmpty {
                stored = fresh
                await MainActor.run { CMSStore.shared.cacheCategories(key, fresh) }
            }
            let latest = SiteCategory(id: "", title: "最新", path: "")
            return [latest] + stored.map { SiteCategory(id: $0.id, title: $0.name, path: $0.id) }
        }
        let fallback = SiteCategory(id: "", title: "推荐", path: "")
        guard let provider = Sites.provider(source) else { return [fallback] }
        let cats = provider.categories
        return cats.isEmpty ? [fallback] : cats
    }
}

enum HomeFmt {
    /// 次要信息：类型（最多两个标签）· 集数 / 热度；长视频是时长 · 观看。
    static func meta(_ s: HGSeries) -> String {
        if s.source.isLongVideo { return Fmt.meta(s) }
        let genres = s.tags.prefix(2).joined(separator: " · ")
        let parts = [genres.isEmpty ? nil : genres, s.episodeCount > 0 ? "\(s.episodeCount)集" : nil].compactMap { $0 }
        return parts.isEmpty ? Fmt.meta(s) : parts.joined(separator: " · ")
    }
    /// 右下角小角标：「更新至 N 集」/「全 N 集」/ 长视频时长。
    static func progress(_ s: HGSeries) -> String? {
        if let sub = s.subtitle, sub.contains("更新至") || sub.hasPrefix("全") { return sub }
        if s.source.isLongVideo { return s.duration > 0 ? Fmt.clock(s.duration) : nil }
        return s.episodeCount > 0 ? "全\(s.episodeCount)集" : nil
    }
}

/// 分类条：未选中 17pt 次要色，选中 20pt 粗体 + 品牌色短条（随选中项滑动）；点击或翻页时选中项自动滚到居中。
struct HomeChannelBar<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var ink: Color = .white
    @Namespace private var ns
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .lastTextBaseline, spacing: 22) {
                    ForEach(items, id: \.self) { it in
                        let on = it == selection
                        // Do NOT wrap `selection = it` in `withAnimation`: `TabView(.page)` (`UIPageViewController`)
                        // otherwise sweeps & synchronously instantiates every intermediate page on the main thread.
                        Button { if !on { DS.tick(); selection = it } } label: {
                            UnderlineTabLabel(title: label(it), on: on, ink: ink, inkOff: STVTheme.secondary, ns: ns)
                                .frame(minHeight: 40, alignment: .bottom)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).id(it).accessibilityIdentifier("home.channel.\(label(it))")
                            .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
                .animation(DS.select, value: selection)
                .animation(DS.select, value: items)
            }
            .accessibilityIdentifier("home.channels")
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.93),
                                         .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
            .compatOnChange(of: selection) { it in withAnimation(DS.select) { proxy.scrollTo(it, anchor: .center) } }
            .compatOnChange(of: items) { _ in proxy.scrollTo(selection, anchor: .center) }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
        .frame(height: 40)
    }
}

/// 竖海报 hero：整块用当前海报模糊做底，左侧完整 3:4 竖海报（不裁成横图），
/// 右侧榜单名、片名、标签/集数/热度、简介或主演，以及「查看详情」。横滑切换，右上指示点。
/// 长视频站点（横版封面）同一布局里海报区按 16:9 显示在上方。
private struct PosterHero: View {
    @Environment(\.zoomNS) private var ns
    let board: String
    let picks: [HGSeries]
    @Binding var index: Int

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(picks.enumerated()), id: \.element.id) { i, s in
                NavigationLink(value: Route.series(s)) { page(s, rank: i + 1) }.buttonStyle(.plain).tag(i)
                    .accessibilityIdentifier("home.hero.page.\(i)")
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Same card height for every source so switching pages never makes the top jump.
        .frame(height: height)
        .background { backdrop }
        .overlay(alignment: .bottomTrailing) { dots }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        // Shadow of a plain shape behind the card: on the card itself it re-rendered the whole pager off screen per frame.
        .background { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.shadow(.drop(color: .black.opacity(0.22), radius: 15, y: 14))).padding(1) }
        // Auto-advance; the timer restarts on every page change, so a manual swipe gets a full 6 s.
        .task(id: "\(picks.count)-\(index)") {
            guard picks.count > 1, Self.autoAdvance else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) { index = (index + 1) % picks.count }
        }
    }

    /// `.hero`: 14 pt padding around a 112 pt 3:4 poster (landscape sites: 16:9 at 176 pt).
    private static let pad: CGFloat = 14
    private static let posterHeight: CGFloat = 112 * 4 / 3
    private static let landscapeHeight: CGFloat = pad + 99 + pad + 62
    private static let portraitHeight: CGFloat = pad + posterHeight + pad
    private var height: CGFloat { landscape ? Self.landscapeHeight : Self.portraitHeight }
    /// DEBUG `STV_HERO_STILL=1` (UI tests) disables auto-advance so taps never race a page change.
    static var autoAdvance: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STV_HERO_STILL"] == "1" { return false }
        #endif
        return true
    }
    private var landscape: Bool { picks.first?.isLandscapeCover ?? false }

    /// Poster colours: the current cover blurred, darkened toward the bottom-right like the spec's gradient card.
    private var backdrop: some View {
        let url = picks.indices.contains(index) ? picks[index].cover : ""
        return ZStack {
            Color(red: 0.14, green: 0.10, blue: 0.10)
            CoverBackdrop(url: url).opacity(0.9)
            LinearGradient(colors: [.black.opacity(0.18), .black.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .allowsHitTesting(false)
    }

    private func kicker(_ rank: Int) -> String { board.isEmpty ? "TOP \(rank)" : "\(board) · TOP \(rank)" }

    @ViewBuilder private func page(_ s: HGSeries, rank: Int) -> some View {
        if landscape {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    CoverView(url: s.cover, corner: 12, maxPixelSize: CoverPixels.wide)
                        .frame(width: 176, height: 99)
                        .zoomSource(s.id, ns)
                        .overlay(alignment: .bottomTrailing) { if let p = HomeFmt.progress(s) { HomeBadge(text: p).padding(5) } }
                        .accessibilityIdentifier("home.hero.cover")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(kicker(rank)).font(.system(size: 11, weight: .heavy)).tracking(0.6)
                            .foregroundStyle(Color(red: 0.949, green: 0.710, blue: 0.361)).lineLimit(1)
                        Text(s.title).font(.system(size: 16, weight: .bold)).foregroundStyle(.white).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                let line = Fmt.meta(s)
                if !line.isEmpty { Text(line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.74)).lineLimit(1).padding(.top, 9) }
                Spacer(minLength: 0)
                detailButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
        } else {
            HStack(alignment: .top, spacing: 14) {
                CoverView(url: s.cover, corner: 12, maxPixelSize: CoverPixels.poster)
                    .frame(width: 112, height: 112 * 4 / 3)
                    .overlay {
                        LinearGradient(stops: [.init(color: .clear, location: 0.46), .init(color: .black.opacity(0.62), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let e = DS.episodes(s) {
                            Text(e).font(.system(size: 11)).foregroundStyle(.white.opacity(0.9)).padding(.trailing, 8).padding(.bottom, 7)
                        }
                    }
                    .zoomSource(s.id, ns)
                info(s, rank: rank)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func info(_ s: HGSeries, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kicker(rank)).font(.system(size: 11, weight: .heavy)).tracking(0.6)
                .foregroundStyle(Color(red: 0.949, green: 0.710, blue: 0.361)).lineLimit(1)
            Text(s.title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            let line1 = [DS.genres(s), s.episodeCount > 0 ? "\(s.episodeCount) 集" : nil].compactMap { $0 }.joined(separator: " · ")
            let line2 = s.playCount > 0 ? DS.count(s.playCount) + "热度" : (s.actors.isEmpty ? "" : "主演 " + s.actors.prefix(3).joined(separator: " / "))
            VStack(alignment: .leading, spacing: 0) {
                if !line1.isEmpty { Text(line1).lineLimit(1) }
                if !line2.isEmpty { Text(line2).lineLimit(1) }
            }
            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.74))
            .lineSpacing(3)
            .padding(.top, 7)
            Spacer(minLength: 0)
            detailButton
        }
        .padding(.top, 3).padding(.bottom, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var detailButton: some View {
        PillButtonLabel(title: "查看详情", icon: "play.fill", tone: .white, small: true)
    }

    private var dots: some View {
        HStack(spacing: 4) {
            ForEach(picks.indices, id: \.self) { i in
                Capsule().fill(i == index ? Color.white : Color.white.opacity(0.4)).frame(width: i == index ? 14 : 5, height: 5)
            }
        }
        .animation(DS.select, value: index)
        .padding(.trailing, 14).padding(.bottom, 14 + 1 + 13.5)
        .opacity(picks.count > 1 ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(index + 1) 部，共 \(picks.count) 部")
        .accessibilityIdentifier("home.hero.dots")
    }
}

/// ui-redesign 10 `.cw`: horizontal 继续观看 cards with progress and a round play button.
struct HomeContinueRow: View {
    @Environment(\.zoomNS) private var ns
    let items: [WatchProgress]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSectionHeader(title: "继续观看") {
                NavigationLink(value: Route.history) { MoreLabel() }.buttonStyle(.plain).accessibilityIdentifier("home.more.继续观看")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(items) { p in
                        ZStack(alignment: .trailing) {
                            NavigationLink(value: Route.series(p.series)) { card(p) }
                                .buttonStyle(PressScale(scale: 0.98))
                                .contextMenu { Button("删除观看记录", systemImage: "trash", role: .destructive) { LibraryStore.shared.removeProgress(p.series) } }
                            NavigationLink(value: Route.play(p.series, p.episodeIndex)) { playButton }
                                .buttonStyle(PressScale()).padding(.trailing, 12)
                                .accessibilityLabel("继续播放 \(p.series.title)")
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 2)
            }
            .frame(height: 94)
            .compatScrollBounceBasedOnSize(axes: .horizontal)
        }
    }

    private func card(_ p: WatchProgress) -> some View {
        HStack(spacing: 12) {
            CoverView(url: p.series.cover, corner: 10, maxPixelSize: CoverPixels.thumb).frame(width: 52, height: 52 * 4 / 3).zoomSource(p.series.id, ns)
            VStack(alignment: .leading, spacing: 0) {
                Text(p.series.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(STVTheme.text).lineLimit(1)
                Text(line(p)).font(.system(size: 12)).foregroundStyle(STVTheme.secondary).lineLimit(1).padding(.top, 2)
                DSProgressBar(value: p.fraction).padding(.top, 9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 10)
        .frame(width: 296)
        .dsCard(18)
    }

    private var playButton: some View {
        Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(STVTheme.bg)
            .offset(x: 1)
            .frame(width: 38, height: 38)
            .background(Circle().fill(STVTheme.text))
            .contentShape(Circle())
    }

    private func line(_ p: WatchProgress) -> String {
        if p.series.source.isLongVideo { return Fmt.resume(p) }
        let total = p.series.episodeCount
        return total > 0 ? "看到第 \(p.episodeNumber) 集 · 共 \(total) 集" : "看到第 \(p.episodeNumber) 集"
    }
}

/// ui-redesign 10/11: one horizontally scrolling row per board (`.hs` of 112 pt cells).
struct HomeShelf: View {
    let title: String
    let note: String?
    let items: [HGSeries]
    var more: BoardSpec? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSectionHeader(title: title, note: note) {
                if let more {
                    NavigationLink(value: Route.board(more)) { MoreLabel() }.buttonStyle(.plain).accessibilityIdentifier("home.more.\(title)")
                }
            }
            if !items.isEmpty {
                let landscape = items.first?.isLandscapeCover ?? false
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(items) { s in
                            PosterCellView(series: s, subtitle: DS.shelfMeta(s))
                                .frame(width: landscape ? 200 : 112)
                                .accessibilityIdentifier("home.card")
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .compatScrollBounceBasedOnSize(axes: .horizontal)
            }
        }
    }
}

struct HomeBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).monospacedDigit()
            .lineLimit(1).padding(.horizontal, 5).frame(height: 17)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Full list of one board, 3-column numbered grid with infinite paging.
struct BoardListView: View {
    let board: BoardSpec
    @StateObject private var pager = Pager()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let e = pager.error, pager.items.isEmpty { ErrorStateView(error: e) { reload() } }
                else { NumberedGrid(items: pager.items, numbered: board.numbered, hasMore: pager.hasMore, loading: pager.isLoading) { pager.loadMore() } }
            }.padding(.vertical, 8)
        }
        .accessibilityIdentifier("screen.board")
        .dsNavigation(board.title)
        .refreshable { reload() }
        .task { if pager.items.isEmpty { reload() } }
    }
    private func reload() { let b = board; pager.reset { try await b.fetch($0, $1) } }
}
