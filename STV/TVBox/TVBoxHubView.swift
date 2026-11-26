import Combine
import SwiftUI

/// TVBox tab: 点播 / 直播, the current site or live source, search, categories and posters. Playback always goes through the
/// shared detail page and player.
struct TVBoxHubView: View {
    @ObservedObject private var store = TVBoxStore.shared
    @ObservedObject private var gate = SourceGate.shared
    @StateObject private var hub = TVBoxHubModel()
    @State private var picking = false
    @State private var asking: TVBoxRepo?
    @State private var paired = BridgeClient.shared.paired

    /// What the page is about, derived once per update.
    private struct Subject {
        let repo: TVBoxRepo?
        let stamp: String
        let sites: [TVBoxSiteRef]
        let lives: [TVBoxLiveRef]
        let site: TVBoxSiteRef?
        let live: TVBoxLiveRef?

        /// `paired`: what `SiteBlock` depends on besides the config, read here so that the page follows it.
        @MainActor init(_ store: TVBoxStore, adult: Bool, paired: Bool) {
            let repo = store.activeRepo
            let sites = repo.map { store.visibleSites($0, adult: adult) } ?? []
            let lives = repo.map { store.visibleLives($0) } ?? []
            let lastSite = repo.flatMap { store.state.lastSite[$0.id] }, lastLive = repo.flatMap { store.state.lastLive[$0.id] }
            var site = sites.first { $0.uid == lastSite }
            if site == nil { site = sites.first { repo?.block($0.site.kind) == nil } }
            self.repo = repo
            self.sites = sites
            self.lives = lives
            self.site = site ?? sites.first
            live = lives.first { $0.uid == lastLive } ?? lives.first
            stamp = TVBoxStore.stamp(repo)
        }

        /// The current site cannot run yet.
        @MainActor var block: SiteBlock? { site.flatMap { s in repo?.block(s.site.kind) } }
        @MainActor var searchable: [String] {
            guard let repo else { return [] }
            return sites.filter { $0.site.searchable && repo.block($0.site.kind) == nil }.map(\.uid)
        }
    }

    var body: some View {
        let s = Subject(store, adult: gate.unlocked, paired: paired)
        content(s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidTopBar { header(s) }
            .dsAmbient(cool: hub.mode == .live)
            .toolbar(.hidden, for: .navigationBar)
            .overlay { if hub.acting { DSBusyOverlay(label: "正在执行…") } }
            .animation(DS.panel, value: hub.acting)
            .sheet(isPresented: $picking) { if let repo = s.repo { picker(repo, s) } }
            .tvboxTrustDialog($asking)
            .dsDialog("提示", isPresented: Binding(get: { hub.message != nil }, set: { if !$0 { hub.message = nil } }), message: hub.message) {
                [.primary("知道了", disabled: { false }, {})]
            }
            .compatOnChange(of: s.stamp) { hub.search.clear() }
            .task(id: "\(s.repo?.id ?? "")|\(s.sites.isEmpty)|\(s.lives.isEmpty)") {
                if s.sites.isEmpty && !s.lives.isEmpty { hub.mode = .live } else if s.lives.isEmpty && !s.sites.isEmpty { hub.mode = .vod }
            }
            .onReceive(BridgeStatus.pairing) { if $0 != paired { paired = $0 } }
            .onAppear { hub.search.resume() }
            .onDisappear { hub.search.pause() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen.tvbox")
            #if DEBUG
            .task { await TVBoxFixture.seedIfRequested() }
            #endif
            .tvboxShot("trust") { asking = store.activeRepo }
            .tvboxShot("sites") { picking = true }
            .tvboxShot("live,unlock") { hub.mode = .live }
            .tvboxShot("lives") { hub.mode = .live; picking = true }
            .tvboxShot("config,list,menu,rename,paste,manual,parse") { Router.push(.tvboxConfig) }
            .tvboxShot("bridge") { TVBoxConfigView.openBridge() }
    }

    // MARK: Header

    private func header(_ s: Subject) -> some View {
        VStack(spacing: 8) {
            topRow(s)
            if let repo = s.repo, repo.error == nil {
                if repo.needsTrust { trustBanner(repo) }
                if hub.mode == .vod {
                    if let site = s.site {
                        VodBar(pane: hub.site(site.uid, s.stamp), search: hub.search, site: site, searchable: s.searchable, blocked: s.block != nil)
                    }
                } else if let live = s.live {
                    LiveBar(pane: hub.live(live.uid, s.stamp))
                }
            }
        }
        .padding(.top, 4).padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func topRow(_ s: Subject) -> some View {
        HStack(spacing: 10) {
            SegmentedTabs(items: HubMode.allCases, selection: $hub.mode, label: \.rawValue, idPrefix: "tvbox.mode").frame(width: 128)
            LiquidGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if hub.mode == .vod {
                        if let site = s.site { source(site.site.name, site.site.kind) }
                    } else if let live = s.live { source(live.live.name, live.live.kind) }
                    NavigationLink(value: Route.tvboxConfig) { DSBarLabel(systemName: "gearshape") }
                        .buttonStyle(GlassPress())
                        .accessibilityLabel("TVBox 配置").accessibilityIdentifier("tvbox.config")
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func source(_ name: String, _ kind: SiteKind?) -> some View {
        Button { picking = true } label: {
            HStack(spacing: 6) {
                if let kind { TVBoxKindBadge(kind: kind) }
                Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(STVTheme.text).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(STVTheme.secondary)
            }
            .padding(.leading, kind == nil ? 14 : 9).padding(.trailing, 12).frame(height: 44)
            .contentShape(Capsule())
            .liquidGlassCapsule(interactive: true)
        }
        .buttonStyle(GlassPress())
        .accessibilityLabel(hub.mode == .vod ? "当前站点 \(name)" : "当前直播源 \(name)")
        .accessibilityIdentifier("tvbox.source")
    }

    private func trustBanner(_ repo: TVBoxRepo) -> some View {
        Button { asking = repo } label: {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 16, weight: .medium)).foregroundStyle(STVTheme.accentWarm)
                Text("「\(repo.name)」含 JAR / JS / Python 站点，信任后才会运行").dsFont(13, relativeTo: .footnote).foregroundStyle(STVTheme.text)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MiniButtonLabel(title: "查看")
            }
            .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .liquidGlass(corner: 20, tone: .tinted(STVTheme.warmSoft), interactive: true)
        }
        .buttonStyle(GlassPress())
        .padding(.horizontal, 16)
        .accessibilityIdentifier("tvbox.trust")
    }

    // MARK: Content

    @ViewBuilder private func content(_ s: Subject) -> some View {
        if !store.loaded {
            DSLoading()
        } else if let repo = s.repo {
            if let e = repo.error {
                HubState("配置无法读取", systemImage: "exclamationmark.triangle", message: e, actionTitle: "去配置管理") { Router.push(.tvboxConfig) }
            } else {
                KeptPages(current: hub.mode, limit: 2) { mode in
                    if mode == .vod { vod(repo, s) } else { live(repo, s) }
                }
            }
        } else {
            HubState("还没有 TVBox 配置", systemImage: "tv", message: "支持 CMS、T4、JS、Python、JAR 站点和 M3U / TXT 直播，也支持多仓与加密配置。", actionTitle: "添加配置") { Router.push(.tvboxConfig) }
        }
    }

    @ViewBuilder private func vod(_ repo: TVBoxRepo, _ s: Subject) -> some View {
        if let site = s.site {
            VodPages(pane: hub.site(site.uid, s.stamp), search: hub.search, hub: hub, repo: repo, site: site, block: s.block) { asking = repo }
        } else {
            HubState("没有可用的点播站点", systemImage: "film.stack", message: "可以在配置里启用站点，或换一个配置。", actionTitle: "去配置管理") { Router.push(.tvboxConfig) }
        }
    }

    @ViewBuilder private func live(_ repo: TVBoxRepo, _ s: Subject) -> some View {
        if let live = s.live {
            if let kind = live.live.kind, let block = repo.block(kind) {
                VodBlocked(repo: repo, kind: kind, block: block) { asking = repo }
            } else {
                LivePage(pane: hub.live(live.uid, s.stamp), live: live).id(live.uid)
            }
        } else {
            HubState("没有直播源", systemImage: "antenna.radiowaves.left.and.right", message: "当前配置没有启用的直播列表。", actionTitle: "去配置管理") { Router.push(.tvboxConfig) }
        }
    }

    // MARK: Pickers

    @ViewBuilder private func picker(_ repo: TVBoxRepo, _ s: Subject) -> some View {
        if hub.mode == .vod {
            SitePicker(repo: repo, sites: s.sites, current: s.site?.uid) { choice in
                picking = false
                switch choice {
                case .site(let uid):
                    store.setLastSite(repo.id, uid)
                    hub.search.clear()
                case .config: Router.push(.tvboxConfig)
                case .bridge: TVBoxConfigView.openBridge()
                }
            }
        } else {
            LivePicker(repo: repo, lives: s.lives, current: s.live?.uid) { uid in
                picking = false
                store.setLastLive(repo.id, uid)
            }
        }
    }
}

/// Centred message on a page of its own.
struct HubState: View {
    let title: String
    let systemImage: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    init(_ title: String, systemImage: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ScrollView {
            DSEmptyState(title, systemImage: systemImage, message: message, actionTitle: actionTitle, action: action)
                .padding(.top, 56)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("tvbox.state")
        }
        .compatScrollBounceBasedOnSize()
    }
}

/// A site that needs something from the user before it can run.
struct VodBlocked: View {
    let repo: TVBoxRepo
    let kind: SiteKind
    let block: SiteBlock
    let onTrust: () -> Void

    var body: some View {
        switch block {
        case .trust:
            HubState("\(kind.badge) 站点尚未启用", systemImage: "shield.lefthalf.filled", message: "这个站点的代码需要你先信任「\(repo.name)」才会运行。", actionTitle: "信任配置", action: onTrust)
        case .bridge:
            HubState("JAR 站点需要桥接", systemImage: "personalhotspot", message: "iOS 不能运行 JAR。把同一局域网里的安卓设备配对为桥接后，由它代为运行这个站点。", actionTitle: "去配对") { TVBoxConfigView.openBridge() }
        case .python:
            HubState(PythonRuntime.missingMessage, systemImage: "curlybraces", message: "可以换一个站点，或使用带 Python 运行时的版本。")
        case .unsupported:
            HubState("不支持的站点类型", systemImage: "questionmark.circle", message: "可以换一个站点。")
        }
    }
}
