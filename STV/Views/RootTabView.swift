import SwiftUI

/// 四个根页面 + 窄屏底部悬浮玻璃胶囊 / 平板宽屏左侧悬浮玻璃导航轨（系统 TabBar 隐藏）。
/// 导航栏只在根页面显示；进入详情 / 播放器等二级页面时隐藏。
struct RootTabView: View {
    @State private var tab = Int(ProcessInfo.processInfo.environment["STV_TAB"] ?? "") ?? 0
    @State private var paths = [NavigationPath(), NavigationPath(), NavigationPath(), NavigationPath()]
    @State private var homeChromeHidden = false
    @State private var homeBottomBarHidden = false
    @State private var categoryBottomBarHidden = false
    @State private var profileBottomBarHidden = false
    static let items: [(String, String)] = [("首页", "house.fill"), ("TVBox", "tv.fill"),
                                            ("找剧", "square.grid.2x2.fill"), ("我的", "person.crop.circle.fill")]
    var body: some View {
        GeometryReader { geo in
            let metrics = LayoutMetrics(width: geo.size.width, height: geo.size.height)
            let showNav = paths[tab].isEmpty
            HStack(spacing: 0) {
                Group {
                    if showNav && metrics.useRail && !(tab == 0 && homeChromeHidden) {
                        GlassNavigationRail(selection: $tab, items: Self.items) { i in
                            if i == tab { paths[i] = NavigationPath() }
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                // Keep rail animation local; never animate the player/navigation stack layout.
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showNav && metrics.useRail && !(tab == 0 && homeChromeHidden))
                TabView(selection: $tab) {
                    Stack(path: $paths[0]) { HomeView() }.tag(0)
                    Stack(path: $paths[1]) { TVBoxHubView() }.tag(1)
                    Stack(path: $paths[2]) { CategoryView() }.tag(2)
                    Stack(path: $paths[3]) { ProfileView() }.tag(3)
                }
                .tint(STVTheme.accent)
                .overlay(alignment: .bottom) {
                    let hideActiveBar = (tab == 0 && homeBottomBarHidden)
                        || (tab == 2 && categoryBottomBarHidden)
                        || (tab == 3 && profileBottomBarHidden)
                    Group {
                        if showNav && !metrics.useRail && !hideActiveBar {
                            GlassTabBar(selection: $tab, items: Self.items) { i in
                                if i == tab { paths[i] = NavigationPath() }
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .bottom).combined(with: .opacity)
                            ))
                        }
                    }
                    // Scope the spring to the bar only. Root-level implicit animation
                    // also animates NavigationStack pushes and the PiP render host.
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showNav && !metrics.useRail && !hideActiveBar)
                }
            }
            .background(STVTheme.bg.ignoresSafeArea())
            .environment(\.layoutMetrics, metrics)
        }
        .onAppear {
            Router.handler = { r in paths[tab].append(r) }
            #if DEBUG
            if ProcessInfo.processInfo.environment["STV_TD_OPEN"] == "1" { Router.push(.tdlib) }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeChromeVisibilityChanged)) { note in
            guard tab == 0, let hidden = note.object as? Bool else { return }
            homeChromeHidden = hidden
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeBottomBarVisibilityChanged)) { note in
            guard tab == 0, let hidden = note.object as? Bool else { return }
            homeBottomBarHidden = hidden
        }
        .onReceive(NotificationCenter.default.publisher(for: .categoryBottomBarVisibilityChanged)) { note in
            guard tab == 2, let hidden = note.object as? Bool else { return }
            categoryBottomBarHidden = hidden
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileBottomBarVisibilityChanged)) { note in
            guard tab == 3, let hidden = note.object as? Bool else { return }
            profileBottomBarHidden = hidden
        }
        .compatOnChange(of: tab) { selected in
            if selected != 0 {
                homeChromeHidden = false
                homeBottomBarHidden = false
                categoryBottomBarHidden = false
                profileBottomBarHidden = false
                NotificationCenter.default.post(name: .homeChromeResetRequested, object: nil)
                NotificationCenter.default.post(name: .categoryBottomBarVisibilityChanged, object: false)
                NotificationCenter.default.post(name: .profileBottomBarVisibilityChanged, object: false)
            }
        }
        // Cold start: restore a saved TDLib login (no network login, nothing is sent).
        .task { await TDLibService.shared.bootstrap() }
    }
}

private struct Stack<V: View>: View {
    @Binding var path: NavigationPath
    @ViewBuilder var content: V
    @Namespace private var ns
    var body: some View {
        NavigationStack(path: $path) {
            content
                .toolbar(.hidden, for: .tabBar)
                .routes()
        }.environment(\.zoomNS, ns)
    }
}

struct GlassTabBar: View {
    /// Vertical space reserved below root-page content for the floating tab bar.
    static let clearance: CGFloat = 72
    @Binding var selection: Int
    let items: [(String, String)]
    var onReselect: (Int) -> Void = { _ in }
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    let on = i == selection
                    Button {
                        if on { onReselect(i) } else { withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { selection = i } }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: items[i].1).font(.system(size: 17, weight: on ? .semibold : .regular)).frame(height: 20)
                            Text(items[i].0).font(.system(size: 11, weight: on ? .semibold : .medium))
                        }
                        .foregroundStyle(on ? STVTheme.text : STVTheme.secondary)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background {
                            if on { Capsule().fill(STVTheme.glassBorder).matchedGeometryEffect(id: "pill", in: ns) }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(items[i].0)
                    .accessibilityIdentifier("tab.\(i)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(6)
            .dsBar(30)

        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .padding(.bottom, -8)
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
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                ForEach(items.indices, id: \.self) { i in
                    let on = i == selection
                    Button {
                        if on { onReselect(i) } else { withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { selection = i } }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: items[i].1).font(.system(size: 17, weight: on ? .semibold : .regular)).frame(height: 20)
                            Text(items[i].0).font(.system(size: 11, weight: on ? .semibold : .medium))
                        }
                        .foregroundStyle(on ? STVTheme.text : STVTheme.secondary)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background {
                            if on { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(STVTheme.glassBorder).matchedGeometryEffect(id: "railPill", in: ns) }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(items[i].0)
                    .accessibilityIdentifier("tab.\(i)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(6)
            .dsBar(28)
            Spacer()
        }
        .frame(width: 84)
        .padding(.vertical, 16)
        .padding(.leading, 8)
    }
}


extension Notification.Name {
    static let homeChromeVisibilityChanged = Notification.Name("STV.homeChromeVisibilityChanged")
    static let homeBottomBarVisibilityChanged = Notification.Name("STV.homeBottomBarVisibilityChanged")
    static let homeChromeResetRequested = Notification.Name("STV.homeChromeResetRequested")
    static let categoryBottomBarVisibilityChanged = Notification.Name("STV.categoryBottomBarVisibilityChanged")
    static let profileBottomBarVisibilityChanged = Notification.Name("STV.profileBottomBarVisibilityChanged")
}
