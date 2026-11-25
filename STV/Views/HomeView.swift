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

/// One interaction-gated state machine drives both the home search header and root tab bar.
/// Geometry changes caused by loading or viewport resizing reset the sample instead of changing chrome.
struct HomeChromeScrollBehavior {
    private(set) var isHidden = false
    private var isInteracting = false
    private var previousOffset: CGFloat?
    private var previousTime: TimeInterval?
    private var previousContentHeight: CGFloat?
    private var previousViewportHeight: CGFloat?
    private var previousViewportWidth: CGFloat?
    let revealVelocity: CGFloat

    init(revealVelocity: CGFloat = 400) {
        self.revealVelocity = revealVelocity
    }

    mutating func setInteracting(_ active: Bool) {
        guard isInteracting != active else { return }
        isInteracting = active
        resetSamples()
    }

    mutating func update(
        offset: CGFloat,
        contentHeight: CGFloat? = nil,
        viewportHeight: CGFloat? = nil,
        viewportWidth: CGFloat? = nil,
        isWithinScrollRange: Bool? = nil,
        at time: TimeInterval
    ) -> Bool? {
        guard isInteracting else {
            resetSamples()
            return nil
        }
        if isWithinScrollRange == false {
            resetSamples()
            return nil
        }

        let contentChanged = dimensionChanged(contentHeight, from: previousContentHeight)
        let viewportChanged = dimensionChanged(viewportHeight, from: previousViewportHeight)
        let widthChanged = dimensionChanged(viewportWidth, from: previousViewportWidth)
        previousContentHeight = contentHeight
        previousViewportHeight = viewportHeight
        previousViewportWidth = viewportWidth

        // Loading cards or collapsing the search header changes geometry, not user intent.
        if contentChanged || viewportChanged || widthChanged {
            previousOffset = offset
            previousTime = time
            return nil
        }

        let previous = previousOffset
        let previousSampleTime = previousTime
        previousOffset = offset
        previousTime = time

        if offset > -8 {
            return setHidden(false)
        }

        guard let previous, let previousSampleTime else { return nil }
        let delta = offset - previous
        guard abs(delta) > 1.5 else { return nil }

        if delta < 0 {
            return setHidden(true)
        }

        let elapsed = max(time - previousSampleTime, 0.001)
        guard delta / elapsed >= revealVelocity else { return nil }
        return setHidden(false)
    }

    mutating func reset() {
        isHidden = false
        isInteracting = false
        previousContentHeight = nil
        previousViewportHeight = nil
        previousViewportWidth = nil
        resetSamples()
    }

    private func dimensionChanged(_ value: CGFloat?, from previous: CGFloat?) -> Bool {
        guard let value, let previous else { return false }
        return abs(value - previous) > 0.5
    }

    private mutating func resetSamples() {
        previousOffset = nil
        previousTime = nil
    }

    private mutating func setHidden(_ hidden: Bool) -> Bool? {
        guard isHidden != hidden else { return nil }
        isHidden = hidden
        resetSamples()
        return hidden
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
    var id: String { label }
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
    @MainActor static var all: [HomeSource] {
        let g = SourceGate.shared
        let nonTVBoxSites = g.visibleSites.filter { src in
            if let k = src.cmsKey, let s = CMSStore.site(k), s.origin == "TVBox" || s.origin.hasPrefix("TVBox") { return false }
            return true
        }
        return [.hongguo] + (g.showHuangguo ? [.huangguo] : []) + [.ai] + nonTVBoxSites.map { .site($0) } + [.channels, .manga, .novel]
    }
}

/// Caches the first page of each rank board for the home cards.
@MainActor
final class BoardCache: ObservableObject {
    static let shared = BoardCache()
    @Published var items: [String: [HGSeries]] = [:]
    @Published var loading: Set<String> = []
    @Published var failed: Set<String> = []
    @Published var errors: [String: Error] = [:]
    func load(_ b: BoardSpec, force: Bool = false) {
        guard !loading.contains(b.id), force || items[b.id] == nil else { return }
        loading.insert(b.id); failed.remove(b.id); errors[b.id] = nil
        Task {
            do { items[b.id] = try await b.fetch(HGPage(items: [], hasMore: true, nextOffset: nil), []).items; errors[b.id] = nil }
            catch { failed.insert(b.id); errors[b.id] = error }
            loading.remove(b.id)
        }
    }
}

private struct HomeFeedScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 发现页：玻璃搜索栏/筛选 → 来源分类条（红果 / 黄果 / AI剧 / 已开启的长视频站）→ 下方按来源横滑翻页，
/// 分类条联动（选中项自动滚到居中、指示条跟随）。每页：二级榜单选择 → 竖海报 hero → 真实榜单分段。
/// 横滑冲突：hero 轮播区域内的横滑归轮播；其它区域横滑翻来源页；首页是根页面，没有系统侧滑返回。
struct HomeView: View {
    @State private var source: HomeSource
    @State private var subs: [HomeSource: HomeTab]
    @State private var heroCovers: [HomeSource: String] = [:]
    /// ui-redesign 10/11: the header always sits on the page colour (ambient glow on top); once the current page
    /// scrolls it pins with a blurred 80 % page-colour ground and a hairline.
    private var headerInk: Color { STVTheme.text }
    @State private var scrolled: [HomeSource: Bool] = [:]
    @State private var headerHidden = false
    @State private var chromeScrollBehavior = HomeChromeScrollBehavior()
    private var pinned: Bool { scrolled[source] ?? false }
    @State private var showChannels = false

    init() {
        let e = ProcessInfo.processInfo.environment["STV_HOME_TAB"] ?? ""
        var src = HomeSource.hongguo, sub: [HomeSource: HomeTab] = [:]
        if e == "actorRank" { sub[.hongguo] = .actorRank }
        #if DEBUG
        if let s = DramaSource(rawValue: e), s.isLongVideo { src = .site(s) }
        if e == "huangguo" { src = .huangguo }
        if e == "ai" { src = .ai }
        if e == "channels" { src = .channels }
        if e == "manga" { src = .manga }
        if e == "novel" { src = .novel }
        #endif
        _source = State(initialValue: src)
        _subs = State(initialValue: sub)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            sourcePager
        }
        // The feed must run to the physical bottom edge like 找剧: this VStack is the layer whose
        // parent owns the real bottom safe area, so opt out here first.
        .ignoresSafeArea(.container, edges: .bottom)
        .background(STVTheme.bg.ignoresSafeArea())
        .dsAmbient(visible: !pinned)
        .animation(.easeInOut(duration: 0.22), value: headerHidden)
        .compatOnChange(of: source) { _ in
            chromeScrollBehavior.reset()
            setChromeHidden(false)
        }
        .onAppear {
            chromeScrollBehavior.reset()
            setChromeHidden(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeChromeResetRequested)) { _ in
            chromeScrollBehavior.reset()
            setChromeHidden(false)
        }
        .onDisappear {
            chromeScrollBehavior.reset()
            setChromeHidden(false)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showChannels) { channelPanel }
        .compatOnChange(of: SourceGate.shared.visibleSites) { if !HomeSource.all.contains(source) { source = .hongguo } }
    }

    /// Horizontal source pager. iOS 17+ uses a paging `ScrollView` instead of a page-style
    /// `TabView`: the TabView hosts its pages in a private pager that re-applies the bottom safe
    /// area to each page, so the feed viewport stopped above the Home Indicator. A ScrollView is
    /// the same structure as 找剧 / 我的 and reaches the physical screen edge.
    @MainActor @ViewBuilder private var sourcePager: some View {
        if #available(iOS 17.0, *) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(HomeSource.all) { s in
                        sourcePage(s)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: pagerSelection)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .ignoresSafeArea(.container, edges: .bottom)
        } else {
            TabView(selection: $source) {
                ForEach(HomeSource.all) { s in
                    sourcePage(s).tag(s)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    @MainActor @ViewBuilder private func sourcePage(_ s: HomeSource) -> some View {
        if s == .channels {
            ChannelFeedView(embedded: true)
        } else if s == .manga {
            MangaHomeView(embedded: true)
        } else if s == .novel {
            NovelHomeView(embedded: true)
        } else {
            HomeFeedPage(source: s,
                         bottomBarHidden: headerHidden,
                         tab: Binding(get: { subs[s] ?? s.subs[0] }, set: { subs[s] = $0 }),
                         onHero: { heroCovers[s] = $0 },
                         onScrolled: { v in if scrolled[s] != v { scrolled[s] = v } },
                         onScrollOffset: { offset in handleFeedOffset(offset, for: s) },
                         onScrollInteraction: { active in handleFeedInteraction(active, for: s) },
                         onScrollMetrics: { metrics in handleFeedMetrics(metrics, for: s) })
        }
    }

    /// `scrollPosition(id:)` tracks the pager's item ids (`HomeSource.id`, a String).
    @MainActor private var pagerSelection: Binding<String?> {
        Binding(
            get: { source.id },
            set: { id in
                guard let id, id != source.id,
                      let picked = HomeSource.all.first(where: { $0.id == id }) else { return }
                source = picked
            }
        )
    }

    private func setChromeHidden(_ hidden: Bool) {
        if headerHidden != hidden {
            withAnimation(.easeInOut(duration: 0.22)) { headerHidden = hidden }
        }
        NotificationCenter.default.post(name: .homeChromeVisibilityChanged, object: hidden)
        NotificationCenter.default.post(name: .homeBottomBarVisibilityChanged, object: hidden)
    }

    private func handleFeedInteraction(_ active: Bool, for feedSource: HomeSource) {
        guard feedSource == source else { return }
        chromeScrollBehavior.setInteracting(active)
    }

    private func handleFeedMetrics(_ metrics: CompatScrollMetrics, for feedSource: HomeSource) {
        guard feedSource == source else { return }
        if let hidden = chromeScrollBehavior.update(
            offset: -metrics.offsetY,
            contentHeight: metrics.contentHeight,
            viewportHeight: metrics.containerHeight,
            viewportWidth: metrics.containerWidth,
            isWithinScrollRange: metrics.isWithinScrollRange,
            at: ProcessInfo.processInfo.systemUptime
        ) {
            setChromeHidden(hidden)
        }
    }

    /// iOS 16-17 preference-key fallback; only accepted while a vertical user drag is active.
    private func handleFeedOffset(_ offset: CGFloat, for feedSource: HomeSource) {
        handleFeedMetrics(
            CompatScrollMetrics(
                offsetY: -offset,
                contentHeight: nil,
                containerHeight: nil,
                containerWidth: nil,
                isWithinScrollRange: nil
            ),
            for: feedSource
        )
    }

    /// Resolve the search provider from the page currently selected in the home source pager.
    /// The AI page follows its selected sub-board (Hongguo AI or Huangguo AI).
    private var activeSearchSource: DramaSource {
        switch source {
        case .hongguo: return .hongguo
        case .huangguo: return .huangguo
        case .ai:
            if case .some(.huangguo(.ai)) = subs[.ai] { return .huangguo }
            return .hongguo
        case .site(let site): return site
        case .channels, .manga, .novel: return .hongguo
        }
    }

    // MARK: Header (search + filter, source bar)

    private var header: some View {
        VStack(spacing: 0) {
            if !headerHidden {
                HStack(spacing: 0) {
                    NavigationLink(value: Route.searchFromSource(activeSearchSource)) {
                        DSSearchBarLabel()
                            .padding(.leading, 16).frame(height: 46).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("home.search")
                    Button { showChannels = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 14, weight: .semibold))
                            Text("筛选").font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(STVTheme.text)
                        .padding(.horizontal, 16).frame(height: 46).contentShape(Rectangle())
                    }.buttonStyle(PressScale()).accessibilityLabel("筛选与全部频道").accessibilityIdentifier("home.filter")
                }
                .background(STVTheme.glass, in: Capsule())
                .overlay { Capsule().strokeBorder(STVTheme.glassBorder, lineWidth: 1) }
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            HomeChannelBar(items: HomeSource.all, selection: $source, label: \.label, ink: headerInk) { showChannels = true }
                .padding(.leading, 20)
                .padding(.top, pinned ? 14 : 18)
        }
        .padding(.top, 8)
        .padding(.bottom, pinned ? 10 : 0)
        .dsPinned(pinned)
        .animation(.easeOut(duration: 0.22), value: pinned)
        .zIndex(1)
    }

    /// 当前来源页 hero 海报模糊铺在页面顶部，向页面底色淡出。
    @ViewBuilder private var atmosphere: some View {
        let url = heroCovers[source]
        ZStack {
            // Dark ground under the blurred poster keeps the white header legible; without a poster (漫画 / 频道)
            // it would be a dark band in light mode, so use a soft tint of the page colour instead.
            if url != nil { Color(red: 0.08, green: 0.10, blue: 0.15) } else { STVTheme.elevated }
            if let url {
                CoverView(url: url, corner: 0).blur(radius: 48).opacity(0.75).id(url)
                    .transition(.opacity)
            }
        }
        .frame(height: 420)
        .clipped()
        .mask(LinearGradient(colors: [.black, .black.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom))
        .animation(.easeInOut(duration: 0.45), value: url)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var channelPanel: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(HomeSource.all.filter { !$0.subs.isEmpty }) { s in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(s.label).font(.subheadline.weight(.semibold)).foregroundStyle(STVTheme.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                                ForEach(s.subs, id: \.self) { t in
                                    let on = s == source && (subs[s] ?? s.subs[0]) == t
                                    Button { subs[s] = t; source = s; showChannels = false } label: {
                                        Text(t.subLabel).font(.subheadline.weight(on ? .semibold : .regular))
                                            .foregroundStyle(on ? STVTheme.accent : STVTheme.text)
                                            .frame(maxWidth: .infinity).frame(height: 40)
                                            .background(on ? STVTheme.accent.opacity(0.14) : STVTheme.glass,
                                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }.buttonStyle(.plain).accessibilityIdentifier("panel.\(s.label).\(t.subLabel)")
                                }
                            }
                        }
                    }
                }.padding(20)
            }
            .background(STVTheme.surface.ignoresSafeArea())
            .navigationTitle("频道").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("home.channelPanel")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showChannels = false } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// One source page: secondary board chips → hero → real board sections. Vertical scroll inside a horizontal pager.
private struct HomeFeedPage: View {
    let source: HomeSource
    let bottomBarHidden: Bool
    @Binding var tab: HomeTab
    var onHero: (String) -> Void
    var onScrolled: (Bool) -> Void = { _ in }
    var onScrollOffset: (CGFloat) -> Void = { _ in }
    var onScrollInteraction: (Bool) -> Void = { _ in }
    var onScrollMetrics: (CompatScrollMetrics) -> Void = { _ in }
    @State private var legacyChannels: [HuangguoChannel] = []
    @State private var legacyError: Error?
    @State private var heroIndex = 0
    @ObservedObject private var cache = BoardCache.shared
    @ObservedObject private var library = LibraryStore.shared
    private let gutter: CGFloat = 16
    /// DEBUG `STV_HOME_SCROLL=bottom` opens the feed scrolled to the end (simulator screenshots).
    private static var debugAnchor: UnitPoint? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STV_HOME_SCROLL"] == "bottom" { return .bottom }
        #endif
        return nil
    }

    var body: some View {
        if case .site(let source) = tab, source.pluginID == "com.eric.idj.huanggua" {
            HuangguaHomeFeed(source: source, bottomBarHidden: bottomBarHidden,
                             onHero: onHero, onScrollOffset: onScrollOffset,
                             onScrollInteraction: onScrollInteraction, onScrollMetrics: onScrollMetrics)
        } else if case .site(let source) = tab, source.cmsKey != nil || source.pluginID != nil {
            DynamicSiteFeed(source: source, bottomBarHidden: bottomBarHidden, onHero: onHero, onScrollOffset: onScrollOffset, onScrollInteraction: onScrollInteraction, onScrollMetrics: onScrollMetrics)
        } else {
            rankFeed
        }
    }

    private var rankFeed: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GeometryReader { proxy in
                    Color.clear.preference(key: HomeFeedScrollOffsetKey.self, value: proxy.frame(in: .named("home.feed.scroll")).minY)
                }
                .frame(height: 0)
                if source.subs.count > 1 { subChips } else if case .site = source { boardChips }
                if tab == .actorRank {
                    ActorRankList().padding(.vertical, 8)
                } else {
                    if !heroPicks.isEmpty {
                        PosterHero(board: boards.first?.title ?? "", picks: heroPicks, index: $heroIndex).id(tab).padding(.horizontal, gutter)
                            .padding(.top, 16)
                            .transition(.opacity)
                    }
                    if source == .hongguo, !library.continueWatching.isEmpty {
                        HomeContinueRow(items: library.continueWatching).padding(.top, 24)
                    }
                    sections
                }
            }
            // Fixed scroll tail keeps the last card reachable above the floating tab bar.
            // It does not alter the viewport when the bar is shown or hidden.
            .padding(.bottom, bottomBarHidden ? 0 : 96)
            .animation(.easeOut(duration: 0.25), value: bottomBarHidden)
            .animation(.easeOut(duration: 0.25), value: heroPicks.isEmpty)
        }
        // CategoryView's scroll view runs to the physical bottom edge; the paged host above
        // re-applies the safe area to its pages, so the feed has to opt out here as well or
        // cards get cut off exactly at the Home Indicator with an empty strip below.
        .ignoresSafeArea(.container, edges: .bottom)
        .background(STVTheme.bg.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .coordinateSpace(name: "home.feed.scroll")
        .onPreferenceChange(HomeFeedScrollOffsetKey.self) { offset in
            if #unavailable(iOS 18.0) { onScrollOffset(offset) }
        }
        .compatOnScrollInteraction { onScrollInteraction($0) }
        .compatOnScrollMetrics { onScrollMetrics($0) }
        .compatDefaultScrollAnchor(Self.debugAnchor)
        .compatOnScrolled(threshold: 4) { onScrolled($0) }
        .accessibilityIdentifier("home.page.\(source.label)")
        .refreshable { if tab == .actorRank { await ActorRankStore.shared.reload() } else { boards.forEach { cache.load($0, force: true) } } }
        .task(id: tab) {
            heroIndex = 0
            if case .huangguo(.legacy) = tab, legacyChannels.isEmpty { await loadLegacy() }
        }
        .onAppear { boards.prefix(1).forEach { cache.load($0) }; reportHero() }
        .compatOnChange(of: tab) { boards.prefix(1).forEach { cache.load($0) } }
        .compatOnChange(of: heroKey) { reportHero() }
    }

    private var heroKey: String { (heroPicks.indices.contains(heroIndex) ? heroPicks[heroIndex].cover : "") + "\(heroIndex)" }
    private func reportHero() { if heroPicks.indices.contains(heroIndex) { onHero(heroPicks[heroIndex].cover) } }

    /// ui-redesign 10: secondary boards are the same glass segmented control as 找剧.
    private var subChips: some View {
        SegmentedTabs(items: source.subs, selection: $tab, label: \.subLabel, idPrefix: "home.sub")
            .padding(.horizontal, gutter)
            .padding(.top, 18)
    }

    /// Long-video site pages: same chip row height as 红果/黄果 (top never jumps); each chip opens that board.
    private var boardChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(boards.enumerated()), id: \.element.id) { i, b in
                    NavigationLink(value: Route.board(b)) { Text(b.title) }
                    .buttonStyle(ToneChipStyle(on: i == 0, neutral: true))
                    .accessibilityIdentifier("home.sub.\(b.title)")
                }
            }.padding(.horizontal, gutter)
        }
        .compatScrollBounceBasedOnSize(axes: .horizontal)
        .mask(FadeMask())
        .padding(.top, 18)
    }

    // MARK: Data

    private var boards: [BoardSpec] {
        switch tab {
        case .hongguo(let g): g.subs.map { BoardSpec(kind: .hongguo(g, $0)) }
        case .huangguo(.ai): HuangguoClient.aiChannels.map { BoardSpec(kind: .huangguo($0)) }
        case .huangguo(.video): HuangguoClient.videoChannels.map { BoardSpec(kind: .huangguo($0)) }
        case .huangguo(.legacy): legacyChannels.map { BoardSpec(kind: .huangguo($0)) }
        case .site(let s): (Sites.provider(s)?.categories ?? []).map { BoardSpec(kind: .site(s, $0)) }
        case .actorRank: []
        }
    }

    private var heroPicks: [HGSeries] {
        guard let first = boards.first, let items = cache.items[first.id] else { return [] }
        return Array(items.prefix(5))
    }

    @ViewBuilder private var sections: some View {
        if case .huangguo(.legacy) = tab, legacyChannels.isEmpty {
            if let legacyError { ErrorStateView(error: legacyError) { Task { await loadLegacy() } } }
            else { cardsSkeleton }
        } else {
            if let e = boards.lazy.compactMap({ cache.errors[$0.id] }).first(where: { $0.verifyTarget != nil }) {
                ErrorStateView(error: e) { boards.forEach { cache.load($0, force: true) } }
            }
            ForEach(Array(boards.enumerated()), id: \.element.id) { n, b in
                Group {
                    if let items = cache.items[b.id], !items.isEmpty {
                        // 第一个榜单一律跳过 hero 里已展示的剧（数据不够时也跳过，只剩标题和「全部」）。
                        let heroIds = Set(heroPicks.map(\.id))
                        let rest = n == 0 ? items.filter { !heroIds.contains($0.id) } : items
                        HomeShelf(title: b.title, note: nil, items: Array(rest.prefix(12)), more: b)
                    } else if cache.failed.contains(b.id) {
                        HomeShelf(title: b.title, note: cache.errors[b.id]?.verifyTarget != nil ? "需要验证，点上方「去验证」" : "加载失败，下拉重试", items: [], more: b)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            DSSectionHeader(title: b.title)
                            cardsSkeleton.padding(.horizontal, gutter)
                        }
                    }
                }
                .padding(.top, n == 0 && heroPicks.isEmpty && library.continueWatching.isEmpty ? 18 : 24)
                .onAppear { cache.load(b) }
            }
        }
    }

    private var cardsSkeleton: some View {
        let landscape: Bool = { if case .site(let s) = tab { return s.isLongVideo } else { return false } }()
        return LazyVGrid(columns: HomeSection.columns(landscape: landscape), spacing: 16) {
            ForEach(0..<(landscape ? 2 : 3), id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    ShimmerBlock().aspectRatio(landscape ? 16/9 : 3/4, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                    ShimmerBlock().frame(height: 12).frame(maxWidth: 90)
                }
            }
        }
    }

    private func loadLegacy() async {
        do { legacyChannels = try await HuangguoClient.shared.legacyChannels(); legacyError = nil } catch { legacyError = error }
    }
}

/// CMS / JS plugin home: every returned category is a selectable module, and the selected one pages its own list.
private struct DynamicSiteFeed: View {
    let source: DramaSource
    let bottomBarHidden: Bool
    var onHero: (String) -> Void
    var onScrollOffset: (CGFloat) -> Void = { _ in }
    var onScrollInteraction: (Bool) -> Void = { _ in }
    var onScrollMetrics: (CompatScrollMetrics) -> Void = { _ in }
    @State private var categories: [SiteCategory] = []
    @State private var selected = ""
    @StateObject private var pager = Pager()
    @State private var heroCover: String?
    @State private var didLoad = false

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        GeometryReader { g in
                            Color.clear.preference(key: HomeFeedScrollOffsetKey.self, value: g.frame(in: .named("home.feed.scroll")).minY)
                        }
                        .frame(height: 0)
                        .id("dynamic.top")
                        if categories.count > 1 { chips }
                        if let e = pager.error, pager.items.isEmpty {
                            ErrorStateView(error: e) { reload(selected) }
                        } else if pager.items.isEmpty && (pager.isLoading || pager.hasMore) {
                            // 分类加载 / 首页第一页请求期间也显示骨架，避免切回来源时先闪一帧空白。
                            cardsSkeleton.padding(.horizontal, 16)
                        } else if pager.items.isEmpty {
                            CompatEmptyStateView(title: "该分类暂无内容", systemImage: "rectangle.stack", description: "部分采集站的父分类不直接提供资源，请选择动作片、国产剧等具体分类。")
                        } else {
                            NumberedGrid(items: pager.items, numbered: false, hasMore: pager.hasMore, loading: pager.isLoading) { pager.loadMore() }
                        }
                    }
                    // Fixed tail lets the last grid row scroll clear of the floating navigation; with the
                    // bar hidden there is no tail so the grid ends on the physical screen edge.
                    .padding(.top, 8)
                    .padding(.bottom, bottomBarHidden ? 0 : 96)
                }
                // Same as the ranked feed: keep the grid scrolling to the screen edge, not to the
                // safe-area line where the paged host would otherwise stop it.
                .ignoresSafeArea(.container, edges: .bottom)
                .scrollIndicators(.hidden)
                .coordinateSpace(name: "home.feed.scroll")
                .onPreferenceChange(HomeFeedScrollOffsetKey.self) { offset in
                    if #unavailable(iOS 18.0) { onScrollOffset(offset) }
                }
                .compatOnScrollInteraction { onScrollInteraction($0) }
                .compatOnScrollMetrics { onScrollMetrics($0) }
                .accessibilityIdentifier("home.page.\(source.label)")
                .refreshable { await refresh() }

                Button {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("dynamic.top", anchor: .top) }
                    Task { await refresh() }
                } label: {
                    Group {
                        if pager.isLoading {
                            ProgressView().tint(STVTheme.text)
                        } else {
                            Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .semibold)).foregroundStyle(STVTheme.text)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(STVTheme.glass, in: Circle())
                    .overlay { Circle().strokeBorder(STVTheme.glassBorder, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                }
                .buttonStyle(PressScale())
                .disabled(pager.isLoading)
                .padding(.trailing, 18)
                // Clear the floating tab bar (and the Home Indicator when it is hidden).
                .padding(.bottom, bottomBarHidden ? 44 : 96)
                .accessibilityLabel("刷新列表")
                .accessibilityIdentifier("home.dynamic.refresh")
            }
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            await refresh()
        }
        .compatOnChange(of: heroCover) { cover in if let cover { onHero(cover) } }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories) { c in
                    let on = c.id == selected
                    Button { selected = c.id; reload(c.id) } label: {
                        Text(c.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? STVTheme.bg : STVTheme.text.opacity(0.8))
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(on ? STVTheme.text : STVTheme.text.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.module.\(c.title)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }.padding(.horizontal, 16)
        }
        .compatScrollBounceBasedOnSize(axes: .horizontal)
        .padding(.bottom, 4)
    }

    private var cardsSkeleton: some View {
        LazyVGrid(columns: HomeSection.columns(landscape: source.isLongVideo), spacing: 16) {
            ForEach(0..<(source.isLongVideo ? 2 : 3), id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    ShimmerBlock().aspectRatio(source.isLongVideo ? 16/9 : 3/4, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    ShimmerBlock().frame(height: 12).frame(maxWidth: 90)
                }
            }
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
            if (prev.nextOffset ?? 1) <= 1 {
                if let cover = page.items.first?.cover, !cover.isEmpty {
                    await MainActor.run { heroCover = cover }
                }
                // 插件与采集站的分类都可能在首屏请求里刷新，首屏返回后再更新分类条。
                if source.isDynamic {
                    let latestCats = provider.categories
                    if !latestCats.isEmpty {
                        await MainActor.run {
                            if categories.map(\.id) != latestCats.map(\.id) { categories = latestCats }
                        }
                    }
                }
            }
            return page
        }
    }

    private static func loadCategories(_ source: DramaSource) async -> [SiteCategory] {
        if let key = source.cmsKey {
            // 与内置站源一致：先用已保存的分类立即出首屏，分类校验放到后台，不阻塞第一页。
            let stored = CMSStore.site(key)?.categories ?? []
            if let site = CMSStore.site(key) {
                Task {
                    guard let fresh = try? await MacCMSProvider.fetchCategories(api: site.api),
                          !fresh.isEmpty,
                          (CMSStore.site(key)?.categories ?? []).map(\.id) != fresh.map(\.id) else { return }
                    await MainActor.run { CMSStore.shared.cacheCategories(key, fresh) }
                }
            }
            let latest = SiteCategory(id: "", title: "最新", path: "")
            return [latest] + stored.map { SiteCategory(id: $0.id, title: $0.name, path: $0.id) }
        }
        let fallback = SiteCategory(id: "", title: "推荐", path: "")
        guard let provider = Sites.provider(source) else { return [fallback] }

        // JS 视频插件的分类由 home() 动态提供。不能只读 cachedCategories：
        // 首次进入时缓存通常为空，而此前只有点击“推荐”后才可能触发 home()，形成循环依赖。
        if let pluginID = source.pluginID,
           let response = try? await PluginRuntime.call(pluginID, "home", [:]) as? [String: Any] {
            let fresh = PluginOut.categories(response["categories"])
            if !fresh.isEmpty {
                await MainActor.run { PluginStore.shared.cacheCategories(pluginID, fresh) }
                return [fallback] + fresh.map {
                    SiteCategory(id: $0.id, title: $0.name, path: $0.id, isRank: $0.isRank)
                }
            }
        }

        // home() 不可用时仍兼容已有缓存分类及旧插件。
        let categories = provider.categories.filter { !$0.id.isEmpty }
        return [fallback] + categories
    }
}

/// 黄瓜短剧专属首页：TOP 1-5 轮播 → 推荐横向卡片 → 各站点分类横向卡片。
/// “全部”进入对应分类的完整网格，不再把分类只放在页面顶部的筛选条里。
private struct HuangguaHomeFeed: View {
    let source: DramaSource
    let bottomBarHidden: Bool
    var onHero: (String) -> Void
    var onScrollOffset: (CGFloat) -> Void = { _ in }
    var onScrollInteraction: (Bool) -> Void = { _ in }
    var onScrollMetrics: (CompatScrollMetrics) -> Void = { _ in }

    @State private var categories: [SiteCategory] = []
    @State private var recommendation: [HGSeries] = []
    @State private var categoryItems: [String: [HGSeries]] = [:]
    @State private var selectedCategory: SiteCategory?
    @StateObject private var allPager = Pager()
    @State private var isLoading = false
    @State private var loadError: Error?
    @State private var heroIndex = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GeometryReader { proxy in
                    Color.clear.preference(key: HomeFeedScrollOffsetKey.self, value: proxy.frame(in: .named("home.feed.scroll")).minY)
                }.frame(height: 0)

                if let selectedCategory {
                    HStack {
                        Button {
                            self.selectedCategory = nil
                        } label: {
                            Label("返回黄瓜首页", systemImage: "chevron.left")
                                .font(.system(size: 14, weight: .medium))
                        }.buttonStyle(.plain)
                        Spacer()
                        Text(selectedCategory.title).font(.system(size: 17, weight: .semibold))
                    }.padding(.horizontal, 16).padding(.top, 8)

                    if allPager.items.isEmpty && allPager.isLoading {
                        loadingGrid
                    } else if let error = allPager.error, allPager.items.isEmpty {
                        ErrorStateView(error: error) { reloadAll(selectedCategory) }
                    } else {
                        NumberedGrid(items: allPager.items, numbered: false,
                                     hasMore: allPager.hasMore, loading: allPager.isLoading) {
                            allPager.loadMore()
                        }
                        .padding(.horizontal, 16)
                    }
                } else {
                    if !recommendation.isEmpty {
                        PosterHero(board: "黄瓜短剧", picks: Array(recommendation.prefix(5)), index: $heroIndex)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .compatOnChange(of: heroIndex) { index in
                                let picks = Array(recommendation.prefix(5))
                                if picks.indices.contains(index) { onHero(picks[index].cover) }
                            }

                        shelf(title: "推荐", items: recommendation, category: SiteCategory(id: "", title: "推荐", path: ""))
                    } else if isLoading {
                        loadingGrid
                    }

                    ForEach(categories) { category in
                        if let items = categoryItems[category.id], !items.isEmpty {
                            shelf(title: category.title, items: items, category: category)
                        }
                    }

                    if let loadError, recommendation.isEmpty {
                        ErrorStateView(error: loadError) { Task { await refresh() } }
                    }
                }
            }
            .padding(.bottom, bottomBarHidden ? 0 : 96)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .background(STVTheme.bg.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .coordinateSpace(name: "home.feed.scroll")
        .onPreferenceChange(HomeFeedScrollOffsetKey.self) { offset in
            if #unavailable(iOS 18.0) { onScrollOffset(offset) }
        }
        .compatOnScrollInteraction { onScrollInteraction($0) }
        .compatOnScrollMetrics { onScrollMetrics($0) }
        .accessibilityIdentifier("home.page.黄瓜短剧")
        .refreshable { await refresh() }
        .task { if recommendation.isEmpty { await refresh() } }
        .compatOnChange(of: recommendation.count) { _ in
            if let cover = recommendation.first?.cover, !cover.isEmpty { onHero(cover) }
        }
    }

    @ViewBuilder private func shelf(title: String, items: [HGSeries], category: SiteCategory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSectionHeader(title: title) {
                Button {
                    Task { await loadAll(category) }
                } label: {
                    HStack(spacing: 3) {
                        Text("全部")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }.font(.system(size: 12, weight: .medium)).foregroundStyle(STVTheme.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.more.黄瓜.\(title)")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items.prefix(12)) { series in
                        NavigationLink(value: Route.series(series)) {
                            HomePosterCard(series: series).frame(width: 112)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16)
            }
            .compatScrollBounceBasedOnSize(axes: .horizontal)
        }
        .padding(.top, 2)
    }

    private var loadingGrid: some View {
        LazyVGrid(columns: HomeSection.columns(landscape: false), spacing: 16) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    ShimmerBlock().aspectRatio(3/4, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    ShimmerBlock().frame(height: 12).frame(maxWidth: 90)
                }
            }
        }.padding(.horizontal, 16)
    }

    @MainActor private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            guard let pluginID = source.pluginID,
                  let provider = Sites.provider(source) else { throw ProviderError.unsupported("黄瓜短剧插件未启用") }
            let home = try await PluginRuntime.call(pluginID, "home", [:]) as? [String: Any] ?? [:]
            let fresh = PluginOut.categories(home["categories"]).filter { $0.id != "browse" }
            PluginStore.shared.cacheCategories(pluginID, fresh)
            categories = fresh.map { SiteCategory(id: $0.id, title: $0.name, path: $0.id) }

            let rec = try await provider.list(SiteCategory(id: "", title: "推荐", path: ""), page: 1)
            recommendation = rec.items
            var loaded: [String: [HGSeries]] = [:]
            for category in categories {
                let page = try await provider.list(category, page: 1)
                loaded[category.id] = page.items
            }
            categoryItems = loaded
        } catch {
            loadError = error
        }
    }

    @MainActor private func loadAll(_ category: SiteCategory) async {
        selectedCategory = category
        reloadAll(category)
    }

    /// Use the shared host Pager for every plugin category. The source owns URL construction,
    /// page parsing and hasMore; the app only requests the next page through SiteProvider.
    @MainActor private func reloadAll(_ category: SiteCategory) {
        guard let provider = Sites.provider(source) else { return }
        allPager.reset { previous, _ in
            let requestedPage = max(1, previous.nextOffset ?? 1)
            return try await provider.list(category, page: requestedPage)
        }
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
    var onExpand: () -> Void
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .lastTextBaseline, spacing: 22) {
                        ForEach(items, id: \.self) { it in
                            let on = it == selection
                            Button { withAnimation(DS.select) { selection = it } } label: {
                                UnderlineTabLabel(title: label(it), on: on, ink: ink, inkOff: STVTheme.secondary, ns: ns)
                                    .frame(minHeight: 40, alignment: .bottom)
                            }.buttonStyle(.plain).id(it).accessibilityIdentifier("home.channel.\(label(it))")
                                .accessibilityAddTraits(on ? .isSelected : [])
                        }
                        Color.clear.frame(width: 12, height: 1)
                    }
                }
                .accessibilityIdentifier("home.channels")
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.88),
                                             .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                .compatOnChange(of: selection) { it in withAnimation(.compatSnappy) { proxy.scrollTo(it, anchor: .center) } }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
            Button(action: onExpand) {
                Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(STVTheme.secondary).frame(width: 44, height: 40)
            }.buttonStyle(.plain).accessibilityLabel("展开全部频道").accessibilityIdentifier("home.expand")
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
        .shadow(color: .black.opacity(0.22), radius: 15, y: 14)
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
            CoverView(url: url, corner: 0).blur(radius: 40).scaleEffect(1.5).opacity(0.85).id(url).transition(.opacity)
            LinearGradient(colors: [.black.opacity(0.18), .black.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipped()
        .animation(.easeInOut(duration: 0.4), value: url)
        .allowsHitTesting(false)
    }

    private func kicker(_ rank: Int) -> String { board.isEmpty ? "TOP \(rank)" : "\(board) · TOP \(rank)" }

    @ViewBuilder private func page(_ s: HGSeries, rank: Int) -> some View {
        if landscape {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    CoverView(url: s.cover, corner: 12)
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
                CoverView(url: s.cover, corner: 12)
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
                HStack(spacing: 10) {
                    ForEach(items.prefix(10)) { p in
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
            .compatScrollBounceBasedOnSize(axes: .horizontal)
        }
    }

    private func card(_ p: WatchProgress) -> some View {
        HStack(spacing: 12) {
            CoverView(url: p.series.cover, corner: 8).frame(width: 52, height: 52 * 4 / 3).zoomSource(p.series.id, ns)
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
        if p.series.source.isLongVideo { return p.resumeLabel }
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

/// 分段：左写接口真实榜单名，右侧「全部」进完整榜单；下面按封面比例的网格。
struct HomeSection: View {
    @Environment(\.layoutMetrics) private var layout
    static func columns(landscape: Bool) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: landscape ? 12 : 10, alignment: .top), count: landscape ? 2 : 3)
    }
    /// 竖海报 2 行 × 3，横版 2 行 × 2。
    static func count(for items: [HGSeries]) -> Int { (items.first?.isLandscapeCover ?? false) ? 4 : 6 }
    let title: String
    let note: String?
    let items: [HGSeries]
    var more: BoardSpec? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(STVTheme.text)
                Spacer(minLength: 0)
                if let note { Text(note).font(.system(size: 12, weight: .medium)).foregroundStyle(STVTheme.secondary) }
                if let more {
                    NavigationLink(value: Route.board(more)) {
                        HStack(spacing: 2) { Text("全部"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                            .font(.system(size: 13)).foregroundStyle(STVTheme.secondary)
                    }.buttonStyle(.plain).accessibilityIdentifier("home.more.\(title)")
                }
            }
            if !items.isEmpty {
                let landscape = items.first?.isLandscapeCover ?? false
                let gridCols = landscape ? layout.wideGridItems(spacing: 12, alignment: .top) : layout.posterGridItems(spacing: 10, alignment: .top)
                LazyVGrid(columns: gridCols, alignment: .leading, spacing: 16) {
                    ForEach(items) { s in
                        NavigationLink(value: Route.series(s)) { HomePosterCard(series: s) }.buttonStyle(.plain)
                            .accessibilityIdentifier("home.card")
                    }
                }
            }
        }
    }
}

/// 卡片按来源封面比例：短剧 3:4 竖海报（三列），长视频站 16:9（两列）。
/// 封面下方片名（两行内）+ 一行类型/集数；右下角只保留「全 N 集 / 更新至 N 集」小角标。
struct HomePosterCard: View {
    @Environment(\.zoomNS) private var ns
    let series: HGSeries
    var body: some View {
        let landscape = series.isLandscapeCover
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(landscape ? 16/9 : 3/4, contentMode: .fit)
                .overlay { CoverView(url: series.cover, corner: 0) }
                .clipShape(RoundedRectangle(cornerRadius: landscape ? 12 : 10, style: .continuous))
                .zoomSource(series.id, ns)
                .overlay(alignment: .bottomTrailing) {
                    if let p = HomeFmt.progress(series) { HomeBadge(text: p).padding(5) }
                }
                .overlay { RoundedRectangle(cornerRadius: landscape ? 12 : 10, style: .continuous).strokeBorder(STVTheme.glassBorder, lineWidth: 0.6) }
            Text(series.title)
                .font(.system(size: landscape ? 14 : 13, weight: .semibold)).foregroundStyle(STVTheme.text)
                .lineLimit(landscape ? 1 : 2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 7)
            let meta = HomeFmt.meta(series)
            if !meta.isEmpty {
                Text(meta).font(.system(size: 11)).foregroundStyle(STVTheme.secondary).lineLimit(1).padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Full list of one board, 3-column numbered grid with infinite paging.
struct BoardListView: View {
    let board: BoardSpec
    @StateObject private var pager = Pager()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let e = pager.error, pager.items.isEmpty { ErrorStateView(error: e) { reload() } }
                else { NumberedGrid(items: pager.items, hasMore: pager.hasMore, loading: pager.isLoading) { pager.loadMore() } }
            }.padding(.vertical, 8)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .accessibilityIdentifier("screen.board")
        .navigationTitle(board.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if pager.items.isEmpty { reload() } }
    }
    private func reload() { let b = board; pager.reset { try await b.fetch($0, $1) } }
}
