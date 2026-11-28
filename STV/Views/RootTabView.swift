import SwiftUI

private struct HomeScrollChromeHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var homeScrollChromeHidden: Bool {
        get { self[HomeScrollChromeHiddenKey.self] }
        set { self[HomeScrollChromeHiddenKey.self] = newValue }
    }
}

private struct HomeScrollActivityKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    var homeScrollActivity: (Bool) -> Void {
        get { self[HomeScrollActivityKey.self] }
        set { self[HomeScrollActivityKey.self] = newValue }
    }
}

/// 四个根页面 + 窄屏底部悬浮玻璃胶囊 / 平板宽屏左侧悬浮玻璃导航轨（系统 TabBar 隐藏）。
/// 导航栏只在根页面显示；进入详情 / 播放器等二级页面时隐藏。
struct RootTabView: View {
    @State private var tab = Int(ProcessInfo.processInfo.environment["STV_TAB"] ?? "") ?? 0
    @State private var paths = [NavigationPath(), NavigationPath(), NavigationPath(), NavigationPath(), NavigationPath()]
    @State private var tabBarHidden = false
    @State private var restoreTask: Task<Void, Never>?

    private func restoreHomeChromeForScrollActivity(_ active: Bool) {
        restoreTask?.cancel()
        if active {
            if !tabBarHidden { tabBarHidden = true }
        } else if tabBarHidden {
            withAnimation(DS.select) { tabBarHidden = false }
        }
    }
    static let items: [(String, String)] = [("首页", "house.fill"), ("TVBox", "tv.fill"),
                                            ("找剧", "square.grid.2x2.fill"), ("我的", "person.crop.circle.fill")]
    var body: some View {
        GeometryReader { geo in
            let metrics = LayoutMetrics(width: geo.size.width, height: geo.size.height)
            let showNav = paths[tab].isEmpty
            let showBottomBar = showNav && !metrics.useRail && !tabBarHidden
            HStack(spacing: 0) {
                // The spring belongs to the bars alone: attached to the whole tree (as it was) every push and pop animated
                // the layout of all five tabs.
                Group {
                    if showNav && metrics.useRail {
                        GlassNavigationRail(selection: $tab, items: Self.items) { i in
                            if i == tab { paths[i] = NavigationPath() }
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .animation(DS.select, value: showNav && metrics.useRail)
                TabView(selection: $tab) {
                    Stack(path: $paths[0], reserveBottomBar: false) { HomeView() }.tag(0)
                    Stack(path: $paths[1]) { TVBoxHubView() }.tag(1)
                    Stack(path: $paths[2]) { CategoryView() }.tag(2)
                    Stack(path: $paths[3]) { ProfileView() }.tag(3)
                    Stack(path: $paths[4]) { SearchView() }.tag(4)
                }
                .tint(STVTheme.accent)
                .environment(\.homeScrollChromeHidden, tabBarHidden)
                .environment(\.homeScrollActivity) { active in
                    guard showNav && tab == 0 && !metrics.useRail else { return }
                    restoreHomeChromeForScrollActivity(active)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            if #available(iOS 18.0, *) { return }
                            guard showNav && tab == 0 && !metrics.useRail else { return }
                            let dy = value.translation.height
                            let dx = value.translation.width
                            guard abs(dy) > abs(dx) * 1.2 else { return }
                            if dy < -14 {
                                restoreTask?.cancel()
                                if !tabBarHidden { tabBarHidden = true }
                            } else if dy > 14 {
                                restoreTask?.cancel()
                                if tabBarHidden { tabBarHidden = false }
                            }
                        }
                        .onEnded { _ in
                            if #available(iOS 18.0, *) { return }
                            guard tabBarHidden else { return }
                            restoreTask?.cancel()
                            restoreTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 450_000_000)
                                guard !Task.isCancelled else { return }
                                tabBarHidden = false
                            }
                        }
                )
                .overlay(alignment: .bottom) {
                    Group {
                        if showBottomBar {
                            GlassTabBar(selection: $tab, items: Self.items) { i in
                                if i == tab { paths[i] = NavigationPath() }
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(DS.select, value: showBottomBar)
                }
                .compatOnChange(of: tab) { _ in
                    restoreTask?.cancel()
                    tabBarHidden = false
                }
                .compatOnChange(of: showNav) { visible in
                    if !visible {
                        restoreTask?.cancel()
                        tabBarHidden = false
                    }
                }
            }
            .environment(\.layoutMetrics, metrics)
        }
        .onAppear {
            Router.handler = { r in paths[tab].append(r) }
            #if DEBUG
            if ProcessInfo.processInfo.environment["STV_TD_OPEN"] == "1" { Router.push(.tdlib) }
            #endif
        }
        // Cold start: restore a saved TDLib login (no network login, nothing is sent).
        .task { await TDLibService.shared.bootstrap() }
    }
}

private struct Stack<V: View>: View {
    @Binding var path: NavigationPath
    var reserveBottomBar: Bool = true
    @ViewBuilder var content: V
    @Namespace private var ns
    var body: some View {
        NavigationStack(path: $path) {
            content
                .toolbar(.hidden, for: .tabBar)
                .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: reserveBottomBar ? GlassTabBar.clearance : 0) }
                .routes()
        }.environment(\.zoomNS, ns)
    }
}

struct GlassTabBar: View {
    static let clearance: CGFloat = 72
    @Binding var selection: Int
    let items: [(String, String)]
    var searchTag: Int? = nil
    var onReselect: (Int) -> Void = { _ in }
    @Namespace private var ns
    var body: some View {
        LiquidGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(items.indices, id: \.self) { i in
                        NavBarItem(title: items[i].0, symbol: items[i].1, on: i == selection, height: 48, ns: ns) { pick(i) }
                            .accessibilityIdentifier("tab.\(i)")
                    }
                }
                .padding(6)
                .liquidGlassCapsule(interactive: true)

                if let searchTag {
                    NavSearchButton(on: selection == searchTag, size: 60) { pick(searchTag) }
                }
            }
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .padding(.bottom, -8)
    }

    private func pick(_ i: Int) {
        if i == selection { onReselect(i) } else { withAnimation(DS.select) { selection = i } }
    }
}

/// One destination of the tab bar / rail; the selection thumb slides between neighbours.
private struct NavBarItem: View {
    let title: String
    let symbol: String
    let on: Bool
    let height: CGFloat
    let ns: Namespace.ID
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 17, weight: on ? .semibold : .regular)).frame(height: 20)
                Text(title).font(.system(size: 11, weight: on ? .semibold : .medium))
            }
            .foregroundStyle(on ? STVTheme.accent : STVTheme.secondary)
            .frame(maxWidth: .infinity).frame(height: height)
            .background {
                if on {
                    Capsule(style: .continuous).fill(STVTheme.glassBorder).matchedGeometryEffect(id: "pill", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale(scale: 0.94))
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct NavSearchButton: View {
    let on: Bool
    let size: CGFloat
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: on ? .bold : .semibold))
                .foregroundStyle(on ? STVTheme.accent : STVTheme.text)
                .frame(width: size, height: size)
                .liquidGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(PressScale(scale: 0.94))
        .accessibilityLabel("搜索")
        .accessibilityIdentifier("tab.search")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Vertical floating glass navigation rail for Expanded iPad / Stage Manager widths (>= 840pt).
struct GlassNavigationRail: View {
    @Binding var selection: Int
    let items: [(String, String)]
    var searchTag: Int? = nil
    var onReselect: (Int) -> Void = { _ in }
    @Namespace private var ns
    var body: some View {
        LiquidGlassGroup(spacing: 12) {
            VStack(spacing: 12) {
                if let searchTag {
                    NavSearchButton(on: selection == searchTag, size: 56) { pick(searchTag) }
                }
                VStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { i in
                        NavBarItem(title: items[i].0, symbol: items[i].1, on: i == selection, height: 56, ns: ns) { pick(i) }
                            .accessibilityIdentifier("tab.\(i)")
                    }
                }
                .padding(6)
                .liquidGlass(corner: 34, interactive: true)
                Spacer()
            }
        }
        .frame(width: 84)
        .padding(.vertical, 16)
        .padding(.leading, 8)
    }

    private func pick(_ i: Int) {
        if i == selection { onReselect(i) } else { withAnimation(DS.select) { selection = i } }
    }
}
