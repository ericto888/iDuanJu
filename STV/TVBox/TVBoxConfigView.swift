import SwiftUI
import UniformTypeIdentifiers

/// TVBox 配置: import, configs and depots, trust, sites and live sources of the active config, network policy, JAR bridge.
struct TVBoxConfigView: View {
    @ObservedObject private var store = TVBoxStore.shared
    @ObservedObject private var gate = SourceGate.shared
    @State private var url = ""
    @State private var busy: String?
    @State private var notice: TVBoxNotice?
    @State private var panel: Panel?
    @State private var depot: DepotPick?
    /// Runs once the open sheet is gone (one presentation at a time).
    @State private var after: (() -> Void)?
    @State private var asking: TVBoxRepo?
    @State private var renaming: TVBoxRepo?
    @State private var newName = ""
    @State private var removing: TVBoxRepo?
    @State private var picking = false
    @State private var tab: ListTab = .sites
    @State private var query = ""
    @State private var paired = BridgeClient.shared.paired

    private enum ListTab: CaseIterable { case sites, lives }

    private enum Panel: Identifiable {
        case paste, manual, depot, menu(TVBoxRepo), parse, doh
        var id: String {
            switch self {
            case .paste: return "paste"
            case .manual: return "manual"
            case .depot: return "depot"
            case .menu(let r): return "menu." + r.id
            case .parse: return "parse"
            case .doh: return "doh"
            }
        }
    }

    /// `owner`: the persisted depot the entries belong to (nested lists are not kept).
    private struct DepotPick { let depot: DepotRecord; let owner: DepotRecord; let nested: Bool }

    @MainActor private static var wantsBridge = false
    /// Opens the page at its JAR bridge section.
    @MainActor static func openBridge() {
        wantsBridge = true
        Router.push(.tvboxConfig)
    }

    var body: some View {
        let repo = store.activeRepo
        // rows of JAR sites say whether a bridge is there
        let _ = paired
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    importing
                    if !store.state.depots.isEmpty { depots.padding(.top, 24) }
                    if !store.repos.isEmpty { repos(repo).padding(.top, 24) }
                    else if store.loaded {
                        DSEmptyState("还没有配置", systemImage: "tray", message: "支持明文、Base64 / AES 加密、多仓、HTTP 与 IP 地址；导入只下载配置本身，不会逐个验证站点。")
                    }
                    if let repo { active(repo) }
                    network.padding(.top, 24)
                    TVBoxBridgeSection().padding(.top, 24).id("bridge")
                }
                .padding(.top, 4).padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.immediately)
            .task { await showBridge(proxy) }
            .tvboxShot("list") { proxy.scrollTo("tabs", anchor: .top) }
        }
        .dsNavigation("TVBox 配置")
        .animation(DS.panel, value: busy)
        .sheet(item: $panel, onDismiss: { let f = after; after = nil; f?() }) { p in content(of: p, repo) }
        .tvboxTrustDialog($asking)
        .modifier(RenameDialog(repo: $renaming, name: $newName))
        .modifier(RemoveDialog(repo: $removing))
        .onReceive(BridgeStatus.pairing) { if $0 != paired { paired = $0 } }
        .tvboxShot("menu") { if let r = store.activeRepo { panel = .menu(r) } }
        .tvboxShot("rename") { newName = store.activeRepo?.name ?? ""; renaming = store.activeRepo }
        .tvboxShot("paste") { panel = .paste }
        .tvboxShot("manual") { panel = .manual }
        .tvboxShot("parse") { panel = .parse }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json, .plainText, .data, .item]) { r in
            if case .success(let u) = r { importFile(u) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.tvbox.config")
    }

    // MARK: Import

    private var importing: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                DSTextField("配置、多仓或直播列表地址", text: $url, icon: "link", id: "tvbox.url")
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .submitLabel(.go).onSubmit(submit)
                Button(action: submit) {
                    ZStack {
                        PillButtonLabel(title: "导入", height: 46).opacity(busy == nil ? 1 : 0.5)
                        if busy != nil { DSSpinner(size: 18, tint: STVTheme.onAccent) }
                    }
                }
                .buttonStyle(PressScale())
                .disabled(busy != nil || url.trimmed.isEmpty).opacity(url.trimmed.isEmpty && busy == nil ? 0.4 : 1)
                .accessibilityIdentifier("tvbox.import")
            }
            LiquidGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    source("粘贴内容", "doc.on.clipboard", "tvbox.paste") { panel = .paste }
                    source("本地文件", "doc", "tvbox.file") { picking = true }
                    source("手动加站", "plus", "tvbox.manual") { panel = .manual }
                }
            }
            if let busy {
                HStack(spacing: 8) { DSSpinner(size: 14); Text(busy).dsFont(13, relativeTo: .footnote).foregroundStyle(STVTheme.secondary) }
            }
            if let notice {
                Text(notice.text).dsFont(13, relativeTo: .footnote).foregroundStyle(notice.bad ? STVTheme.accentWarm : STVTheme.secondary)
                    .lineSpacing(3).textSelection(.enabled).accessibilityIdentifier("tvbox.notice")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    private func source(_ title: String, _ icon: String, _ id: String, _ action: @escaping () -> Void) -> some View {
        Button { DS.endEditing(); notice = nil; action() } label: { CapsuleLabel(title: title, icon: icon) }
            .buttonStyle(GlassPress())
            .accessibilityIdentifier(id)
    }

    private func submit() {
        let u = url.trimmed
        guard !u.isEmpty else { return }
        run("正在获取配置…") { try await store.importUrl(u) }
    }

    private func importFile(_ u: URL) {
        let name = u.lastPathComponent
        run("正在读取文件…") {
            let data = try await Task.detached { () throws -> Data in
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                guard let d = try? Data(contentsOf: u) else { throw ProviderError.invalid("无法读取文件") }
                return d
            }.value
            return try await store.importLocal(data, fileName: name)
        }
    }

    private func run(_ what: String, owner: DepotRecord? = nil, _ work: @escaping @MainActor () async throws -> ImportResult) {
        guard busy == nil else { return }
        DS.endEditing()
        busy = what
        notice = nil
        Task {
            do { finish(try await work(), owner) } catch is CancellationError {} catch { notice = TVBoxNotice(text: tvboxErrorText(error), bad: true) }
            busy = nil
        }
    }

    private func finish(_ r: ImportResult, _ owner: DepotRecord?) {
        switch r {
        case .imported(let repo):
            url = ""
            notice = TVBoxNotice(text: "已导入「\(repo.name)」：\(repo.sites.count) 个站点 · \(repo.lives.count) 个直播源", bad: false)
            leave { if repo.needsTrust { asking = repo } }
        case .depot(let d, let nested):
            url = ""
            let pick = DepotPick(depot: d, owner: owner ?? d, nested: nested)
            if case .depot? = panel { depot = pick } else { leave { depot = pick; panel = .depot } }
        case .attachment(let name):
            notice = TVBoxNotice(text: "已保存 \(name)，本地配置可以用 ./\(name) 引用它", bad: false)
            leave {}
        }
    }

    /// Puts the open sheet away, then goes on.
    private func leave(_ then: @escaping () -> Void) {
        if panel == nil { then() } else { after = then; panel = nil }
    }

    // MARK: Lists

    private var depots: some View {
        DSSection("多仓") {
            ForEach(store.state.depots) { d in
                HStack(spacing: 8) {
                    Button { notice = nil; depot = DepotPick(depot: d, owner: d, nested: false); panel = .depot } label: {
                        DSRowLabel(title: d.name, subtitle: "\(d.entries.count) 个配置 · \(TVBoxUrl.host(d.url))").contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale(scale: 0.99))
                    .accessibilityIdentifier("tvbox.depot.\(d.id)")
                    Button { run("正在更新多仓…") { try await store.importUrl(d.url, name: d.name) } } label: { MiniButtonLabel(title: "更新") }.buttonStyle(PressScale())
                    if !store.repos.contains(where: { $0.record.depot == d.id }) {
                        Button { withAnimation(DS.panel) { store.removeDepot(d.id) } } label: { MiniButtonLabel(title: "移除", tint: DSTone.danger, ground: DSTone.dangerSoft) }.buttonStyle(PressScale())
                    }
                }
                .dsRow()
            }
        }
    }

    private func repos(_ active: TVBoxRepo?) -> some View {
        DSSection("配置", footer: "点按切换，更多里可以刷新、改名、更改信任或删除。") {
            ForEach(store.repos) { r in repoRow(r, on: r.id == active?.id) }
        }
    }

    private func repoRow(_ r: TVBoxRepo, on: Bool) -> some View {
        HStack(spacing: 6) {
            Button { DS.tick(); withAnimation(DS.select) { store.select(r.id) } } label: {
                HStack(spacing: 10) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 19, weight: .regular)).foregroundStyle(on ? STVTheme.accent : STVTheme.tertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.name).dsFont(16, on ? .semibold : .medium).foregroundStyle(on ? STVTheme.accent : STVTheme.text).lineLimit(1)
                        Text(r.error ?? "\(r.sites.count) 站点 · \(r.lives.count) 直播 · \(Self.date(r.record.updatedAt))").dsFont(12, relativeTo: .caption)
                            .foregroundStyle(r.error == nil ? STVTheme.secondary : STVTheme.accentWarm).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if r.hasCode { DSStatus(text: r.trusted ? "已信任" : "未信任", tone: r.trusted ? .ok : .warn) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale(scale: 0.99))
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityIdentifier("tvbox.repo.\(r.id)")
            Button { panel = .menu(r) } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(STVTheme.secondary).frame(width: 36, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .accessibilityLabel("更多").accessibilityIdentifier("tvbox.more.\(r.id)")
        }
        .dsRow(vertical: 6)
    }

    @ViewBuilder private func active(_ repo: TVBoxRepo) -> some View {
        if !repo.config.notice.isEmpty {
            DSSection("公告") {
                Text(repo.config.notice).dsFont(13, relativeTo: .footnote).foregroundStyle(STVTheme.secondary).lineSpacing(3).textSelection(.enabled).dsRow(vertical: 12)
            }
            .padding(.top, 24)
        }
        DSSection("当前配置 · \(repo.name)") {
            if repo.hasCode {
                DSToggleRow("信任这个配置", isOn: Binding(get: { repo.trusted }, set: { on in if on { asking = repo } else { store.setTrust(repo.id, .denied) } }), subtitle: Self.trustNote(repo))
                    .accessibilityIdentifier("tvbox.trust.switch")
            }
            if repo.config.parses.isEmpty {
                DSRow("默认解析", subtitle: "配置没有解析，使用网页嗅探")
            } else {
                DSRow("默认解析", subtitle: repo.record.parse.nonEmptyOr("自动（超级解析）"), chevron: true) { panel = .parse }
            }
        }
        .padding(.top, 24)
        tabs(repo).padding(.top, 24).id("tabs")
        if tab == .sites { sites(repo) } else { lives(repo) }
    }

    private static func trustNote(_ repo: TVBoxRepo) -> String {
        if PythonRuntime.isAvailable || !repo.sites.contains(where: { $0.site.kind == .py }) { return "允许运行其中的 JAR / JS / Python 站点" }
        return "允许运行其中的 JAR / JS 站点（\(PythonRuntime.missingMessage)）"
    }

    private func shown(_ repo: TVBoxRepo) -> [TVBoxSiteRef] {
        let q = query.trimmed
        return repo.sites.filter { s in
            (gate.unlocked || !s.site.adult) && !s.site.hide && (q.isEmpty || s.site.name.containsIgnoringCase(q) || s.site.api.containsIgnoringCase(q))
        }
    }

    private func tabs(_ repo: TVBoxRepo) -> some View {
        VStack(spacing: 10) {
            SegmentedTabs(items: ListTab.allCases, selection: $tab, label: { $0 == .sites ? "点播站点 \(repo.sites.count)" : "直播源 \(repo.lives.count)" }, idPrefix: "tvbox.config.tab")
            if tab == .sites, !repo.sites.isEmpty {
                HStack(spacing: 10) {
                    DSTextField("搜索站点", text: $query, icon: "magnifyingglass", id: "tvbox.config.search").autocorrectionDisabled().textInputAutocapitalization(.never)
                    TVBoxSpeedButton(meters: store.meters) { store.testSpeed(store.runnable(repo, store.visibleSites(repo, adult: gate.unlocked)).map(\.uid)) }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// Straight children of the lazy stack: a config may list hundreds of sites.
    @ViewBuilder private func sites(_ repo: TVBoxRepo) -> some View {
        let list = shown(repo), first = list.first?.uid, last = list.last?.uid
        if !list.isEmpty {
            let on = list.reduce(0) { $0 + (repo.enabled($1.uid) ? 1 : 0) }
            HStack(spacing: 8) {
                Text("已启用 \(on) / \(list.count)").dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.secondary).monospacedDigit()
                Spacer(minLength: 0)
                if on < list.count { Button { DS.tick(); store.setAllEnabled(repo.id, list.map(\.uid), true) } label: { MiniButtonLabel(title: "全部启用") }.accessibilityIdentifier("tvbox.enableAll") }
                if on > 0 {
                    Button { DS.tick(); store.setAllEnabled(repo.id, list.map(\.uid), false) } label: { MiniButtonLabel(title: "全部停用", tint: STVTheme.secondary, ground: STVTheme.glass) }
                        .accessibilityIdentifier("tvbox.disableAll")
                }
            }
            .buttonStyle(PressScale())
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
        ForEach(list) { s in
            TVBoxSiteRow(ref: s, block: repo.block(s.site.kind), meters: store.meters, isOn: Binding(get: { repo.enabled(s.uid) }, set: { store.setEnabled(repo.id, s.uid, $0) }))
                .tvboxSlice(first: s.uid == first, last: s.uid == last)
        }
        if list.isEmpty, !repo.sites.isEmpty { DSEmptyState("没有匹配的站点", systemImage: "magnifyingglass") }
    }

    @ViewBuilder private func lives(_ repo: TVBoxRepo) -> some View {
        let first = repo.lives.first?.uid, last = repo.lives.last?.uid
        Color.clear.frame(height: 10)
        ForEach(repo.lives) { l in
            TVBoxRow(title: l.live.name, note: l.live.url.nonEmptyOr(l.live.api.nonEmptyOr("配置内置"))) {
                if let kind = l.live.kind { TVBoxKindBadge(kind: kind) }
            } trailing: {
                DSSwitchControl(isOn: Binding(get: { repo.enabled(l.uid) }, set: { store.setEnabled(repo.id, l.uid, $0) }), label: "启用 \(l.live.name)")
            }
            .tvboxSlice(first: l.uid == first, last: l.uid == last)
        }
        if repo.lives.isEmpty { DSEmptyState("没有直播源", systemImage: "antenna.radiowaves.left.and.right") }
    }

    private var network: some View {
        DSSection("网络", footer: "默认只允许访问公网地址；配置本身来自局域网时，它也可以访问局域网里的资源。本机端口始终只开放给应用自己的代理。") {
            DSToggleRow("允许访问局域网", isOn: Binding(get: { store.state.allowLan }, set: { store.setAllowLan($0) }), subtitle: "家里的 NAS、局域网播放源需要打开")
                .accessibilityIdentifier("tvbox.lan")
            DSRow("安全 DNS", subtitle: store.dohError, value: store.state.doh.nonEmptyOr("系统默认"), chevron: true) { panel = .doh }
                .accessibilityIdentifier("tvbox.doh")
        }
    }

    // MARK: Sheets

    @ViewBuilder private func content(of p: Panel, _ repo: TVBoxRepo?) -> some View {
        switch p {
        case .paste:
            TVBoxPasteSheet(busy: busy, error: notice) { text in run("正在解析…") { try await store.importText(text) } }
        case .manual:
            TVBoxManualSheet(adult: gate.unlocked, busy: busy, error: notice) { name, api, adult in run("正在添加…") { try await store.addManualSite(name: name, api: api, adult: adult) } }
        case .depot:
            if let d = depot {
                TVBoxDepotSheet(depot: d.depot, current: repo?.record.url, busy: busy, error: notice) { e in
                    run("正在获取「\(e.name)」…", owner: d.owner) { try await store.openDepot(d.owner, e, nested: d.nested) }
                }
            }
        case .menu(let r):
            TVBoxRepoSheet(repo: r) { choice in choose(choice, r) }
        case .parse:
            if let repo {
                TVBoxParseSheet(repo: repo) { name in
                    store.setParse(repo.id, name)
                    panel = nil
                }
            }
        case .doh:
            TVBoxDohSheet(options: store.dohOptions(), current: store.state.doh) { name in
                store.setDoh(name)
                panel = nil
            }
        }
    }

    private func choose(_ c: TVBoxRepoSheet.Choice, _ r: TVBoxRepo) {
        switch c {
        case .refresh: leave { run("正在刷新…") { try await store.refresh(r.id) } }
        case .rename: leave { newName = r.name; renaming = r }
        case .trust: leave { if r.trusted { store.setTrust(r.id, .denied) } else { asking = r } }
        case .remove: leave { removing = r }
        }
    }

    // MARK: Helpers

    /// The section sits below hundreds of lazy rows: the first jump lands near it, the second one on it.
    private func showBridge(_ proxy: ScrollViewProxy) async {
        guard Self.wantsBridge else { return }
        Self.wantsBridge = false
        tab = .lives
        for wait in [350, 250] {
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
            withAnimation(DS.panel) { proxy.scrollTo("bridge", anchor: .top) }
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
    private static func date(_ ms: Int64) -> String { ms <= 0 ? "未更新" : clock.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }
}

/// One site of the active config.
private struct TVBoxSiteRow: View {
    let ref: TVBoxSiteRef
    let block: SiteBlock?
    let meters: TVBoxMeters
    @Binding var isOn: Bool

    var body: some View {
        TVBoxRow(title: ref.site.name, note: note, warn: block != nil) {
            TVBoxKindBadge(kind: ref.site.kind).frame(minWidth: 44, alignment: .leading)
        } trailing: {
            TVBoxLatency(uid: ref.uid, meters: meters)
            DSSwitchControl(isOn: $isOn, label: "启用 \(ref.site.name)").accessibilityIdentifier("tvbox.enable.\(ref.site.key)")
        }
    }

    private var note: String {
        switch block {
        case .bridge: return "需要桥接 · \(ref.site.api)"
        case .python, .unsupported: return "\(block?.note ?? "") · \(ref.site.api)"
        case .trust, nil: return ref.site.api
        }
    }
}

private struct RenameDialog: ViewModifier {
    @Binding var repo: TVBoxRepo?
    @Binding var name: String
    func body(content: Content) -> some View {
        let r = repo
        content.dsDialog("重命名", isPresented: Binding(get: { repo != nil }, set: { if !$0 { repo = nil } })) {
            [.cancel(), .primary("保存", disabled: { name.trimmed.isEmpty }) { if let r { TVBoxStore.shared.rename(r.id, name) } }]
        } extra: {
            DSTextField("配置名称", text: $name, id: "tvbox.rename")
        }
    }
}

private struct RemoveDialog: ViewModifier {
    @Binding var repo: TVBoxRepo?
    func body(content: Content) -> some View {
        let r = repo
        content.dsDialog("删除「\(r?.name ?? "")」？", isPresented: Binding(get: { repo != nil }, set: { if !$0 { repo = nil } }), message: "站点、直播源和它们的缓存会一起移除，观看记录保留。") {
            [.cancel(), .destructive("删除") { if let r { TVBoxStore.shared.remove(r.id) } }]
        }
    }
}
