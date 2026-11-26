import SwiftUI
import Combine

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

/// Each board publishes independently: loading one category only invalidates its own shelf.
@MainActor
final class BoardFeed: ObservableObject {
    enum State { case idle, loaded([HGSeries]), failed(Error) }
    let board: BoardSpec
    @Published private(set) var state: State = .idle
    private var loading = false

    init(_ board: BoardSpec) { self.board = board }
    var items: [HGSeries] { if case .loaded(let items) = state { return items }; return [] }
    var error: Error? { if case .failed(let error) = state { return error }; return nil }

    func load(force: Bool = false) {
        guard !loading else { return }
        if case .loaded = state, !force { return }
        loading = true
        Task {
            defer { loading = false }
            do { state = .loaded(try await board.fetch(HGPage(items: [], hasMore: true, nextOffset: nil), []).items) }
            catch { if items.isEmpty { state = .failed(error) } }
        }
    }
}

@MainActor
final class BoardCache {
    static let shared = BoardCache()
    private var feeds: [String: BoardFeed] = [:]
    func feed(_ board: BoardSpec) -> BoardFeed {
        if let feed = feeds[board.id] { return feed }
        let feed = BoardFeed(board)
        feeds[board.id] = feed
        return feed
    }
}

/// The hero observes only the candidate boards used for its own TOP5 selection.
@MainActor
final class HomeHeroSelection: ObservableObject {
    @Published private(set) var picks: [HGSeries] = []
    @Published private(set) var board: BoardSpec?
    private var ids: [String] = []
    private var feeds: [BoardFeed] = []
    private var subscriptions = Set<AnyCancellable>()

    func configure(_ boards: [BoardSpec], fallback: Bool) {
        let candidates = fallback ? boards : Array(boards.prefix(1))
        let nextIDs = candidates.map(\.id)
        guard nextIDs != ids else {
            candidates.forEach { BoardCache.shared.feed($0).load() }
            return
        }
        ids = nextIDs
        subscriptions.removeAll()
        feeds = candidates.map { BoardCache.shared.feed($0) }
        for feed in feeds {
            feed.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }.store(in: &subscriptions)
        }
        feeds.forEach { $0.load() }
        refresh()
    }

    private func refresh() {
        let loaded = feeds.filter { !$0.items.isEmpty }
        let chosen = loaded.first { $0.items.count >= 5 } ?? loaded.first
        if board?.id != chosen?.board.id { board = chosen?.board }
        let next = Array(chosen?.items.prefix(5) ?? [])
        if picks != next { picks = next }
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
    @StateObject private var heroSelection = HomeHeroSelection()
    private let gutter: CGFloat = 16
    /// DEBUG `STV_HOME_SCROLL=bottom` opens the feed scrolled to the end (simulator screenshots).
    private static var debugAnchor: UnitPoint? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STV_HOME_SCROLL"] == "bottom" { return .bottom }
        #endif
        return nil
    }

    var body: some View {
        if case .site(let source) = tab, source.cmsKey != nil || source.pluginID != nil {
            DynamicSiteFeed(source: source, bottomBarHidden: bottomBarHidden, onHero: onHero,
                            onScrollOffset: onScrollOffset, onScrollInteraction: onScrollInteraction,
                            onScrollMetrics: onScrollMetrics)
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
                    if source == .hongguo { HomeContinueSection() }
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
        .refreshable { if tab == .actorRank { await ActorRankStore.shared.reload() } else { boards.forEach { BoardCache.shared.feed($0).load(force: true) } } }
        .task(id: tab) {
            heroIndex = 0
            if case .huangguo(.legacy) = tab, legacyChannels.isEmpty { await loadLegacy() }
        }
        .onAppear { loadHomeBoards(); reportHero() }
        .compatOnChange(of: tab) { loadHomeBoards() }
        .compatOnChange(of: boards.map(\.id)) { _ in loadHomeBoards() }
        .compatOnChange(of: heroKey) { reportHero() }
        .compatOnChange(of: heroPicks.count) { count in
            if heroIndex >= count { heroIndex = 0 }
        }
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

    private var heroBoard: BoardSpec? { heroSelection.board }

    private func loadHomeBoards() {
        let fallback: Bool
        switch tab {
        case .huangguo(.ai), .huangguo(.video): fallback = true
        default: fallback = false
        }
        heroSelection.configure(boards, fallback: fallback)
    }

    private var heroPicks: [HGSeries] { heroSelection.picks }

    @ViewBuilder private var sections: some View {
        if case .huangguo(.legacy) = tab, legacyChannels.isEmpty {
            if let legacyError { ErrorStateView(error: legacyError) { Task { await loadLegacy() } } }
            else { cardsSkeleton }
        } else {
            ForEach(Array(boards.enumerated()), id: \.element.id) { n, board in
                HomeBoardSection(
                    feed: BoardCache.shared.feed(board),
                    board: board,
                    heroIDs: Set(heroPicks.map(\.id)),
                    isHeroBoard: board.id == heroBoard?.id,
                    landscape: { if case .site(let site) = tab { return site.isLongVideo }; return false }(),
                    topPadding: n == 0 && heroPicks.isEmpty ? 18 : 24,
                    gutter: gutter
                )
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

/// A single shelf observes only its own board feed.
private struct HomeBoardSection: View {
    @ObservedObject var feed: BoardFeed
    let board: BoardSpec
    let heroIDs: Set<String>
    let isHeroBoard: Bool
    let landscape: Bool
    let topPadding: CGFloat
    let gutter: CGFloat

    var body: some View {
        Group {
            if let error = feed.error {
                ErrorStateView(error: error) { feed.load(force: true) }
            } else if !feed.items.isEmpty {
                let rest = isHeroBoard ? feed.items.filter { !heroIDs.contains($0.id) } : feed.items
                HomeShelf(title: board.title, note: nil, items: Array(rest.prefix(12)), more: board)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    DSSectionHeader(title: board.title)
                    LazyVGrid(columns: HomeSection.columns(landscape: landscape), spacing: 16) {
                        ForEach(0..<(landscape ? 2 : 3), id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 8) {
                                ShimmerBlock().aspectRatio(landscape ? 16/9 : 3/4, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                                ShimmerBlock().frame(height: 12).frame(maxWidth: 90)
                            }
                        }
                    }
                    .padding(.horizontal, gutter)
                }
            }
        }
        .padding(.top, topPadding)
        .onAppear { feed.load() }
    }
}

/// Watch history publishes independently of the home feed; progress ticks do not redraw other shelves.
private struct HomeContinueSection: View {
    @ObservedObject private var library = LibraryStore.shared
    var body: some View {
        let items = Array(library.continueWatching.prefix(10))
        if !items.isEmpty { HomeContinueRow(items: items).padding(.top, 24) }
    }
}

/// Shared compact category navigation for CMS and JS-plugin site feeds.
/// Uses the same chip treatment as long-video board navigation, while keeping each site's
/// category IDs, order, and loading behavior independent.
private struct SiteCategoryChipBar: View {
    let categories: [SiteCategory]
    @Binding var selection: String
    var onSelect: (SiteCategory) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.id) { category in
                        Button {
                            withAnimation(.compatSnappy) { selection = category.id }
                            onSelect(category)
                        } label: {
                            Text(category.title)
                        }
                        .buttonStyle(ToneChipStyle(on: selection == category.id, neutral: true))
                        .id(category.id)
                        .accessibilityIdentifier("home.siteCategory.\(category.id)")
                        .accessibilityAddTraits(selection == category.id ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .compatScrollBounceBasedOnSize(axes: .horizontal)
            .mask(FadeMask())
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .compatOnChange(of: selection) { id in
                withAnimation(.compatSnappy) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

@MainActor
final class SourceHomeCache {
    static let shared = SourceHomeCache()

    struct Snapshot {
        var categories: [SiteCategory]
        var selected: String
        var featuredItems: [HGSeries]
        var featuredIndex: Int
        var shelfItems: [String: [HGSeries]]
        var shelfLoaded: Set<String>
        var selectedCategoryID: String?
        var heroCover: String?
        var selectedPager: Pager.Snapshot
        var allPager: Pager.Snapshot
    }

    private var values: [String: Snapshot] = [:]

    func remove(pluginID: String, overrides: [String] = []) {
        values.removeValue(forKey: DramaSource.plugin(pluginID).rawValue)
        for id in overrides { values.removeValue(forKey: id) }
    }

    private func key(_ source: DramaSource) -> String {
        source.rawValue
    }

    func snapshot(for source: DramaSource) -> Snapshot? {
        values[key(source)]
    }

    func save(_ snapshot: Snapshot, for source: DramaSource) {
        values[key(source)] = snapshot
    }

    func updateSelectedPager(_ snapshot: Pager.Snapshot, for source: DramaSource) {
        values[key(source)]?.selectedPager = snapshot
    }

    func updateAllPager(_ snapshot: Pager.Snapshot, for source: DramaSource) {
        values[key(source)]?.allPager = snapshot
    }
}

/// CMS / JS plugin home: every returned category is a selectable module, and the selected one pages its own list.
/// One renderer for every CMS / JavaScript video source.
/// The site supplies categories and optional homeFeatures; refresh, paging and category loading
/// stay identical for XVideos and every plugin. No source-ID-specific home view exists.
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
    @StateObject private var allPager = Pager()
    @State private var featuredItems: [HGSeries] = []
    @State private var featuredIndex = 0
    @State private var shelfItems: [String: [HGSeries]] = [:]
    @State private var shelfLoaded: Set<String> = []
    @State private var shelfLoading: Set<String> = []
    @State private var shelfRequestTokens: [String: UUID] = [:]
    @State private var shelfErrors: [String: Error] = [:]
    @State private var selectedCategory: SiteCategory?
    @State private var heroCover: String?
    @State private var didLoad = false
    @State private var isRefreshing = false

    private var features: Set<String> {
        guard let id = source.pluginID else { return [] }
        return Set(PluginStore.snapshot(id)?.manifest.homeFeatures ?? [])
    }
    private var usesCategoryShelves: Bool { features.contains("categoryShelves") }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        GeometryReader { g in
                            Color.clear.preference(key: HomeFeedScrollOffsetKey.self,
                                                   value: g.frame(in: .named("home.feed.scroll")).minY)
                        }
                        .frame(height: 0)
                        .id("dynamic.top")

                        if selectedCategory == nil && !categories.isEmpty {
                            categoryBar(proxy)
                        }

                        if selectedCategory == nil && !featuredItems.isEmpty {
                            PosterHero(board: source.label, picks: featuredItems, index: $featuredIndex)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                                .compatOnChange(of: featuredIndex) { index in
                                    if featuredItems.indices.contains(index) {
                                        onHero(featuredItems[index].cover)
                                    }
                                }
                        }

                        if let selectedCategory {
                            allCategoryView(selectedCategory)
                        } else if usesCategoryShelves {
                            ForEach(categories) { category in
                                categoryShelf(category)
                            }
                        } else {
                            selectedCategoryFeed
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, bottomBarHidden ? 0 : 96)
                }
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

            }
        }
        .task {
            pager.onSnapshotChanged = { snapshot in
                SourceHomeCache.shared.updateSelectedPager(snapshot, for: source)
            }
            allPager.onSnapshotChanged = { snapshot in
                SourceHomeCache.shared.updateAllPager(snapshot, for: source)
            }
            guard !didLoad else { return }
            didLoad = true
            if let cached = SourceHomeCache.shared.snapshot(for: source) {
                categories = cached.categories
                selected = cached.selected
                featuredItems = cached.featuredItems
                featuredIndex = min(cached.featuredIndex, max(0, cached.featuredItems.count - 1))
                shelfItems = cached.shelfItems
                shelfLoaded = cached.shelfLoaded
                selectedCategory = cached.selectedCategoryID.flatMap { id in
                    cached.categories.first(where: { $0.id == id })
                }
                heroCover = cached.heroCover
                pager.setFetcher(selectedFetcher(for: cached.selected))
                pager.restore(cached.selectedPager)
                if let category = selectedCategory {
                    allPager.setFetcher(allFetcher(for: category))
                    allPager.restore(cached.allPager)
                }
                if let cover = cached.heroCover, !cover.isEmpty { onHero(cover) }
                return
            }
            await refresh()
        }
        .compatOnChange(of: heroCover) { cover in if let cover { onHero(cover) } }
        .compatOnChange(of: selected) { _ in saveMemory() }
        .compatOnChange(of: selectedCategory?.id) { _ in saveMemory() }
    }

    @ViewBuilder
    private func categoryBar(_ proxy: ScrollViewProxy) -> some View {
        if !categories.isEmpty {
            SiteCategoryChipBar(categories: categories, selection: $selected) { category in
                if usesCategoryShelves {
                    withAnimation(.compatSnappy) {
                        proxy.scrollTo(shelfAnchor(category), anchor: .top)
                    }
                } else {
                    reload(category.id)
                }
            }
            .padding(.bottom, 4)
            .accessibilityIdentifier("home.dynamic.categoryBar")
        }
    }

    private var selectedCategoryFeed: some View {
        Group {
            if let e = pager.error, pager.items.isEmpty {
                ErrorStateView(error: e) { reload(selected) }
            } else if pager.items.isEmpty && pager.isLoading {
                cardsSkeleton.padding(.horizontal, 16)
            } else if pager.items.isEmpty {
                CompatEmptyStateView(title: "该分类暂无内容", systemImage: "rectangle.stack",
                                     description: "该站点当前分类没有内容，请选择其他分类或下拉刷新。")
            } else {
                NumberedGrid(items: pager.items, numbered: false, hasMore: pager.hasMore,
                             loading: pager.isLoading) { pager.loadMore() }
            }
        }
    }

    @ViewBuilder
    private func categoryShelf(_ category: SiteCategory) -> some View {
        let rawItems = shelfItems[category.id] ?? []
        let isRecommendation = category.title.trimmingCharacters(in: .whitespacesAndNewlines) == "推荐"
        let heroIDs = Set(featuredItems.map(\.id))
        let visibleItems = isRecommendation && !heroIDs.isEmpty
            ? rawItems.filter { !heroIDs.contains($0.id) }
            : rawItems

        Group {
            if !visibleItems.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    DSSectionHeader(title: category.title) {
                        Button { showAll(category) } label: { MoreLabel() }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("home.more.\(category.title)")
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(visibleItems.prefix(12)) { series in
                                NavigationLink(value: Route.series(series)) {
                                    HomePosterCard(series: series).frame(width: source.isLongVideo ? 200 : 112)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .compatScrollBounceBasedOnSize(axes: .horizontal)
                }
            } else if shelfLoading.contains(category.id) || !shelfLoaded.contains(category.id) {
                VStack(alignment: .leading, spacing: 12) {
                    DSSectionHeader(title: category.title)
                    cardsSkeleton.padding(.horizontal, 16)
                }
            } else if let error = shelfErrors[category.id] {
                VStack(alignment: .leading, spacing: 8) {
                    DSSectionHeader(title: category.title)
                    ErrorStateView(error: error) { Task { await loadShelf(category, force: true) } }
                }
            }
        }
        .id(shelfAnchor(category))
        .onAppear { Task { await loadShelf(category) } }
    }
    private func shelfAnchor(_ category: SiteCategory) -> String {
        "home.shelf.\(category.id)"
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

    private func allCategoryView(_ category: SiteCategory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    selectedCategory = nil
                    allPager.reset { _, _ in HGPage(items: [], hasMore: false, nextOffset: nil) }
                } label: {
                    Label("返回首页", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                Spacer()
                Text(category.title).font(.system(size: 17, weight: .semibold))
            }
            .padding(.horizontal, 16)
            if allPager.items.isEmpty && allPager.isLoading {
                cardsSkeleton.padding(.horizontal, 16)
            } else if let error = allPager.error, allPager.items.isEmpty {
                ErrorStateView(error: error) { reloadAll(category) }
            } else {
                NumberedGrid(items: allPager.items, numbered: false,
                             hasMore: allPager.hasMore, loading: allPager.isLoading) {
                    allPager.loadMore()
                }
            }
        }
        .padding(.top, 8)
    }

    @MainActor
    private func loadShelf(_ category: SiteCategory, force: Bool = false) async {
        guard force || (!shelfLoading.contains(category.id) && !shelfLoaded.contains(category.id)) else { return }
        guard let provider = Sites.provider(source) else { return }
        let requestToken = UUID()
        shelfRequestTokens[category.id] = requestToken
        shelfLoading.insert(category.id)
        shelfErrors[category.id] = nil
        defer {
            if shelfRequestTokens[category.id] == requestToken {
                shelfLoading.remove(category.id)
                shelfRequestTokens[category.id] = nil
            }
        }
        do {
            let page = try await provider.list(category, page: 1)
            guard shelfRequestTokens[category.id] == requestToken else { return }
            shelfItems[category.id] = page.items
            shelfLoaded.insert(category.id)
            shelfErrors[category.id] = nil
        } catch {
            guard shelfRequestTokens[category.id] == requestToken else { return }
            shelfErrors[category.id] = error
        }
        saveMemory()
    }

    @MainActor
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let previousAllCategoryID = selectedCategory?.id
        let previousSelectedID = selected
        let previousLoadedShelves = shelfLoaded
        let home = await Self.loadHome(source)
        categories = home.categories
        featuredItems = home.featured
        featuredIndex = 0
        shelfErrors = [:]

        if let cover = featuredItems.first?.cover, !cover.isEmpty {
            heroCover = cover
            onHero(cover)
        }

        let id = categories.contains { $0.id == previousSelectedID }
            ? previousSelectedID
            : (categories.first?.id ?? "")
        selected = id
        selectedCategory = previousAllCategoryID.flatMap { oldID in
            categories.first(where: { $0.id == oldID })
        }

        if usesCategoryShelves {
            // Refresh only shelves already visited; the rest remain lazy-loaded as they enter view.
            for category in categories where previousLoadedShelves.contains(category.id) {
                await loadShelf(category, force: true)
            }
        }

        if let allCategory = selectedCategory {
            await allPager.refreshPreservingDepth(allFetcher(for: allCategory))
        } else if !usesCategoryShelves {
            await pager.refreshPreservingDepth(selectedFetcher(for: id))
        }
        saveMemory()
    }

    @MainActor
    private func saveMemory() {
        SourceHomeCache.shared.save(
            .init(categories: categories, selected: selected, featuredItems: featuredItems,
                  featuredIndex: featuredIndex, shelfItems: shelfItems, shelfLoaded: shelfLoaded,
                  selectedCategoryID: selectedCategory?.id, heroCover: heroCover,
                  selectedPager: pager.snapshot(), allPager: allPager.snapshot()),
            for: source
        )
    }

    private func selectedFetcher(for id: String) -> (HGPage, [HGSeries]) async throws -> HGPage {
        let source = source
        return { previous, _ in
            guard let provider = Sites.provider(source) else {
                throw ProviderError.unsupported(source.label)
            }
            let category = SiteCategory(id: id, title: "", path: id)
            let pageNumber = max(1, previous.nextOffset ?? 1)
            let page = try await provider.list(category, page: pageNumber)
            if pageNumber == 1 {
                if featuredItems.isEmpty, let cover = page.items.first?.cover, !cover.isEmpty {
                    await MainActor.run { heroCover = cover }
                }
                if source.pluginID != nil {
                    let latestCategories = provider.categories
                    if !latestCategories.isEmpty {
                        await MainActor.run {
                            if categories.map(\.id) != latestCategories.map(\.id) {
                                categories = latestCategories
                            }
                        }
                    }
                }
            }
            return page
        }
    }

    private func allFetcher(for category: SiteCategory) -> (HGPage, [HGSeries]) async throws -> HGPage {
        let source = source
        return { previous, _ in
            guard let provider = Sites.provider(source) else {
                throw ProviderError.unsupported(source.label)
            }
            let pageNumber = max(1, previous.nextOffset ?? 1)
            return try await provider.list(category, page: pageNumber)
        }
    }

    private func reload(_ id: String) {
        pager.reset(selectedFetcher(for: id))
    }

    @MainActor
    private func showAll(_ category: SiteCategory) {
        selectedCategory = category
        saveMemory()
        reloadAll(category)
    }

    @MainActor
    private func reloadAll(_ category: SiteCategory) {
        allPager.reset(allFetcher(for: category))
    }

    private struct DynamicHomeData {
        var categories: [SiteCategory]
        var featured: [HGSeries]
    }

    private static func loadHome(_ source: DramaSource) async -> DynamicHomeData {
        if let key = source.cmsKey {
            var stored = CMSStore.site(key)?.categories ?? []
            if let site = CMSStore.site(key),
               let fresh = try? await MacCMSProvider.fetchCategories(api: site.api, siteKey: key),
               !fresh.isEmpty {
                stored = fresh
                await MainActor.run { CMSStore.shared.cacheCategories(key, fresh) }
            }
            let latest = SiteCategory(id: "", title: "最新", path: "")
            return DynamicHomeData(
                categories: [latest] + stored.map { SiteCategory(id: $0.id, title: $0.name, path: $0.id) },
                featured: []
            )
        }

        let fallback = SiteCategory(id: JSVideoProvider.homeID, title: "推荐", path: JSVideoProvider.homeID)
        guard let provider = Sites.provider(source) else {
            return DynamicHomeData(categories: [fallback], featured: [])
        }

        // Prefer real categories from home(). Only synthesize the host recommendation entry
        // when home() is unavailable or returned no categories, matching the upstream no-duplicate rule.
        if let pluginID = source.pluginID,
           let response = try? await PluginRuntime.call(pluginID, "home", [:]) as? [String: Any] {
            let fresh = PluginOut.categories(response["categories"])
            if !fresh.isEmpty {
                await MainActor.run { PluginStore.shared.cacheCategories(pluginID, fresh) }
            }
            let categories = fresh.map {
                SiteCategory(id: $0.id, title: $0.name, path: $0.id, isRank: $0.isRank)
            }
            let supportsFeatured = PluginStore.snapshot(pluginID)?.manifest.homeFeatures?.contains("featured") == true
            let featured = supportsFeatured ? JSVideoProvider(source: source).featuredItems(from: response) : []
            if !categories.isEmpty {
                return DynamicHomeData(categories: categories, featured: featured)
            }
            let cached = provider.categories.filter { !$0.id.isEmpty }
            return DynamicHomeData(categories: cached.isEmpty ? [fallback] : cached, featured: featured)
        }

        let categories = provider.categories.filter { !$0.id.isEmpty }
        return DynamicHomeData(categories: categories.isEmpty ? [fallback] : categories, featured: [])
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
            CoverBackdrop(url: url).opacity(0.9).id(url).transition(.opacity)
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