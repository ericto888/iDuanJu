import SwiftUI

struct ProfileView: View {
    @State private var message: String?
    @State private var showHongguoLogin = false
    @State private var bottomBarHidden = false
    @State private var chromeScrollBehavior = HomeChromeScrollBehavior()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GeometryReader { proxy in
                    Color.clear.preference(key: TabBarScrollOffsetKey.self, value: proxy.frame(in: .named("profile.scroll")).minY)
                }
                .frame(height: 0)
                Text("我的").dsFont(32, .heavy, relativeTo: .largeTitle).foregroundStyle(STVTheme.text).padding(.horizontal, 20)
                    .accessibilityAddTraits(.isHeader)
                HongguoAccountCard(message: $message, login: $showHongguoLogin)
                ProfileLibrary()
                ProfileLinks()
                DSSection("维护", separatorInset: 58) {
                    maintenance("重置红果设备注册", "arrow.counterclockwise") { await HongguoClient.shared.resetDevice(); message = "已重置红果设备" }
                    maintenance("重置黄果访客会话", "person.badge.key") { await HuangguoClient.shared.resetSession(); message = "已清除黄果会话" }
                    maintenance("清空封面缓存", "photo.stack") { await CoverStore.shared.clear(); message = "封面缓存已清空" }
                    maintenance("清空播放缓存", "trash") {
                        await Task.detached { try? FileManager.default.removeItem(at: EpisodePlaybackLoader.cacheDir) }.value
                        await HongguoClient.shared.clearResolveCache()
                        message = "播放缓存已清空"
                    }
                }
                Text("所有数据由本机直连上游，观看记录和收藏只保存在本机。\n\(Self.versionText)")
                    .dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.tertiary).lineSpacing(3).padding(.horizontal, 20)
            }
            .padding(.top, 8).padding(.bottom, bottomBarHidden ? 0 : 96)
            .compatScrollContent()
        }
        .scrollIndicators(.hidden)
        .coordinateSpace(name: "profile.scroll")
        .onPreferenceChange(TabBarScrollOffsetKey.self) { offset in
            if #unavailable(iOS 18.0) { handleScrollOffset(offset) }
        }
        .compatOnScrollInteraction { chromeScrollBehavior.setInteracting($0) }
        .compatOnScrollMetrics { handleScrollMetrics($0) }
        .dsStatusFade()
        .dsAmbient(cool: true)
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(NotificationCenter.default.publisher(for: .profileBottomBarVisibilityChanged)) { note in
            if let hidden = note.object as? Bool { bottomBarHidden = hidden }
        }
        .onDisappear {
            chromeScrollBehavior.reset()
            setBottomBarHidden(false)
        }
        .sheet(isPresented: $showHongguoLogin) { HongguoLoginView() }
        .dsToast($message, icon: "checkmark.circle.fill", bottom: 16)
    }

    private func handleScrollMetrics(_ metrics: CompatScrollMetrics) {
        if let hidden = chromeScrollBehavior.update(
            offset: -metrics.offsetY,
            contentHeight: metrics.contentHeight,
            viewportHeight: metrics.containerHeight,
            viewportWidth: metrics.containerWidth,
            isWithinScrollRange: metrics.isWithinScrollRange,
            at: ProcessInfo.processInfo.systemUptime
        ) { setBottomBarHidden(hidden) }
    }

    private func handleScrollOffset(_ offset: CGFloat) {
        handleScrollMetrics(CompatScrollMetrics(offsetY: -offset, contentHeight: nil,
            containerHeight: nil, containerWidth: nil, isWithinScrollRange: nil))
    }

    private func setBottomBarHidden(_ hidden: Bool) {
        guard bottomBarHidden != hidden else { return }
        bottomBarHidden = hidden
        NotificationCenter.default.post(name: .profileBottomBarVisibilityChanged, object: hidden)
    }

    static var versionText: String {
        let i = Bundle.main.infoDictionary
        return "i短剧 \(i?["CFBundleShortVersionString"] as? String ?? "") (\(i?["CFBundleVersion"] as? String ?? ""))"
    }

    private func maintenance(_ t: String, _ icon: String, _ action: @escaping () async -> Void) -> some View {
        DSRow(t, icon: icon) { Task { await action() } }
    }
}

// Every block observes only what it shows: playback progress, plugin installs or a profile refresh re-render one block.

private struct HongguoAccountCard: View {
    @Binding var message: String?
    @Binding var login: Bool
    @ObservedObject private var account = HongguoWebAccount.shared

    var body: some View {
        HStack(spacing: 12) {
            if let p = account.profile {
                if !p.avatarUrl.isEmpty {
                    CoverView(url: p.avatarUrl, corner: 24, maxPixelSize: CoverPixels.thumb).frame(width: 48, height: 48)
                } else {
                    Circle().fill(STVTheme.accentSoft).frame(width: 48, height: 48)
                        .overlay(Text(String(p.nickname.prefix(1))).font(.headline).foregroundStyle(STVTheme.accent))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.nickname).dsFont(17, .semibold, relativeTo: .headline).foregroundStyle(STVTheme.text).lineLimit(1)
                    Text(account.lastSyncNote ?? "已连接红果短剧，观看进度自动同步")
                        .dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    account.logout()
                    message = "已退出红果短剧账号"
                } label: { MiniButtonLabel(title: "退出", tint: STVTheme.secondary, ground: STVTheme.glass) }
                    .buttonStyle(PressScale())
            } else {
                IconWell(systemName: "qrcode.viewfinder", size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("红果短剧扫码登录").dsFont(17, .semibold, relativeTo: .headline).foregroundStyle(STVTheme.text)
                    Text("扫码连接账号，同步短剧观看进度").dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.secondary)
                }
                Spacer(minLength: 0)
                Button { login = true } label: { PillButtonLabel(title: "去扫码", small: true) }.buttonStyle(PressScale())
            }
        }
        .padding(14)
        .dsCard(20)
        .padding(.horizontal, 16)
        .task { if account.isLoggedIn { _ = await account.refreshProfile() } }
    }
}

private struct ProfileLibrary: View {
    @ObservedObject private var library = LibraryStore.shared
    var body: some View {
        let watching = Array(library.continueWatching.prefix(10)), favorites = library.favorites
        if !watching.isEmpty { ContinueRow(items: watching) }
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "我的收藏") {
                NavigationLink(value: Route.favorites) { MoreLabel(title: "全部 \(favorites.count)") }.buttonStyle(.plain)
            }
            if favorites.isEmpty {
                Text("在播放页右侧点 ♥ 收藏").dsFont(14, relativeTo: .subheadline).foregroundStyle(STVTheme.secondary).padding(.horizontal, 16)
            } else {
                NumberedGrid(items: Array(favorites.prefix(6)), numbered: false, hasMore: true)
            }
        }
        DSSection(separatorInset: 58) {
            DSLinkRow("观看历史", route: Route.history, icon: "clock.arrow.circlepath", value: watching.isEmpty ? nil : "\(library.continueWatching.count)")
            DSLinkRow("剧星榜", route: Route.actorRank, icon: "star.circle")
            DSLinkRow("我的收藏", route: Route.favorites, icon: "heart", value: "\(favorites.count)")
        }
    }
}

private struct ProfileLinks: View {
    @ObservedObject private var gate = SourceGate.shared
    /// Counts of stores that load from disk: read after the first frame instead of while 我的 is being built.
    @State private var counts = Counts()
    private struct Counts: Equatable { var channels: String?; var manga: String?; var downloads: String?; var plugins: String? }

    var body: some View {
        Group {
            DSSection(separatorInset: 58) {
                DSLinkRow("Telegram 频道", route: Route.channels, icon: "paperplane", value: counts.channels)
                DSLinkRow("漫画", route: Route.mangaHome, icon: "book", value: counts.manga)
                DSLinkRow("小说", route: Route.novel, icon: "text.book.closed")
                DSLinkRow("下载管理", route: Route.downloads, icon: "arrow.down.circle", value: counts.downloads)
            }
            DSSection(separatorInset: 58) {
                DSLinkRow("片源管理", route: Route.sources, icon: "square.stack.3d.down.right", value: gate.enabledCount > 0 ? "已启用 \(gate.enabledCount) 个" : "红果 · 黄果")
                DSLinkRow("插件", route: Route.plugins, icon: "puzzlepiece.extension", value: counts.plugins)
                DSLinkRow("开源许可", route: Route.licenses, icon: "doc.text")
            }
        }
        .task {
            await Task.yield()
            let plugins = PluginStore.shared.visiblePlugins.count + CMSStore.shared.visibleSites.count
            counts = Counts(channels: "\(TGStore.shared.visibleChannels.count) 个",
                            manga: MangaStore.shared.favorites.isEmpty ? nil : "收藏 \(MangaStore.shared.favorites.count)",
                            downloads: TGDownloads.shared.visible.isEmpty ? nil : "\(TGDownloads.shared.visible.count)",
                            plugins: plugins > 0 ? "\(plugins) 个" : nil)
        }
    }
}
