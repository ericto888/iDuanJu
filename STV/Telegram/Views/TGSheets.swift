import SwiftUI
import UniformTypeIdentifiers

/// 长按「加入屏蔽…」: pick suggested words / domains from the post, scope global or this channel.
struct TGBlockSheet: View {
    let post: TGPost
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<Int> = []
    @State private var custom = ""
    @State private var channelOnly = false
    @State private var suggestions: [TGRule] = []

    private var empty: Bool { picked.isEmpty && custom.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        DSSheet("加入屏蔽", subtitle: "命中的消息会被折叠或隐藏") {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("自定义关键词").dsFont(13, .semibold, relativeTo: .footnote).foregroundStyle(STVTheme.secondary)
                        DSTextField("关键词（以 re: 开头为正则，domain: 为域名）", text: $custom, icon: "text.badge.minus", id: "block.custom")
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .padding(.horizontal, 20)
                    DSSection("从这条消息提取") {
                        if suggestions.isEmpty { Text("没有可提取的词或链接").dsFont(14, relativeTo: .subheadline).foregroundStyle(STVTheme.secondary).dsRow() }
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, r in
                            let on = picked.contains(i)
                            Button { DS.tick(); if on { picked.remove(i) } else { picked.insert(i) } } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 19)).foregroundStyle(on ? STVTheme.accent : STVTheme.tertiary)
                                    DSTag(text: r.kind.label)
                                    Text(r.pattern).dsFont(15, relativeTo: .subheadline).foregroundStyle(STVTheme.text).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .dsRow()
                            }
                            .buttonStyle(DSRowPress())
                            .accessibilityAddTraits(on ? .isSelected : [])
                            .accessibilityIdentifier("block.suggest.\(i)")
                        }
                    }
                    DSSection { DSToggleRow("只对 @\(post.channel) 生效", isOn: $channelOnly) }
                }
                .padding(.bottom, 12)
            }
        } footer: {
            DSSheetFooter {
                Button(action: add) { PillButtonLabel(title: "添加", expand: true) }
                    .disabled(empty).opacity(empty ? 0.4 : 1)
                    .accessibilityIdentifier("block.add")
            }
            .buttonStyle(PressScale(scale: 0.98))
        }
        .dsSheetChrome()
        .onAppear { if suggestions.isEmpty { suggestions = TGFilter.suggestions(post) } }
    }

    private func add() {
        let store = TGStore.shared, scope = channelOnly ? post.channel.lowercased() : nil
        for i in picked where suggestions.indices.contains(i) { var r = suggestions[i]; r.channel = scope; store.addRule(r) }
        if let b = TGFilter.importRules(custom) { for var r in b.rules { r.channel = scope; store.addRule(r) } }
        dismiss()
    }
}

/// Bot deep link (`t.me/<bot>?start=<payload>`): only on explicit tap, only with a TDLib session.
struct TGBotSheet: View {
    let link: TGBotLink
    @ObservedObject private var td = TDLibService.shared
    @Environment(\.openURL) private var openURL
    @State private var replies: [TGPost] = []
    @State private var running = false
    @State private var error: String?

    var body: some View {
        DSSheet("机器人链接", subtitle: "@\(link.bot)") {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("参数：\(link.payload)").font(.caption.monospaced()).foregroundStyle(STVTheme.secondary).textSelection(.enabled)
                    Text(td.state.isReady
                         ? "将以你的 Telegram 账号向该机器人发送 /start \(link.payload)，并在这里显示它的回复。不会自动批量发送。"
                         : "以账号身份与机器人交互需要先在「频道 → 管理 → TDLib 登录」登录（\(td.state.label)）。也可以直接在 Telegram 里打开。")
                        .dsFont(13, relativeTo: .footnote).foregroundStyle(STVTheme.secondary).lineSpacing(3)
                    if let error { Text(error).dsFont(13, relativeTo: .footnote).foregroundStyle(DSTone.danger) }
                    ForEach(replies) { p in TGPostCard(post: p, channel: nil).padding(.horizontal, -16) }
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
        } footer: {
            DSSheetFooter {
                Button {
                    if let u = link.tgURL { openURL(u) { ok in if !ok, let w = link.webURL { openURL(w) } } }
                } label: { PillButtonPlain(title: "在 Telegram 中打开") }
                    .accessibilityIdentifier("bot.openInTelegram")
                if td.state.isReady {
                    Button(action: start) {
                        ZStack {
                            PillButtonLabel(title: running ? "" : "发送 /start", expand: true)
                            if running { DSSpinner(size: 18, tint: STVTheme.onAccent) }
                        }
                    }
                    .disabled(running)
                }
            }
            .buttonStyle(PressScale(scale: 0.98))
        }
        .dsSheetChrome()
    }

    private func start() {
        running = true; error = nil
        Task {
            do { replies = try await td.startBot(link) } catch { self.error = error.localizedDescription }
            running = false
        }
    }
}

/// 频道管理: subscribe, presets, per-channel adult / ad-block, t.me access address, rules, TDLib.
struct TGManageView: View {
    @ObservedObject private var store = TGStore.shared
    @ObservedObject private var gate = SourceGate.shared
    @State private var addText = ""
    @State private var addAdult = false
    @State private var base = UserDefaults.standard.string(forKey: TGClient.baseKey) ?? ""
    @State private var message: String?
    @State private var toast: String?
    @State private var editMode: EditMode = .inactive
    @State private var confirmClear = false

    var body: some View {
        // A List only for native swipe-to-delete and reordering of the channels; every row draws the app's own surfaces.
        List {
            plain {
                DSSection("添加公开频道", footer: "通过 t.me/s/<频道> 网页预览读取，无需登录。关闭了网页预览的频道只能用 TDLib 登录后读取。") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            DSTextField("频道用户名 / t.me 链接", text: $addText, icon: "at", id: "tg.add.field")
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button { add() } label: { PillButtonLabel(title: "订阅", height: 46) }
                                .buttonStyle(PressScale()).disabled(addText.isEmpty).opacity(addText.isEmpty ? 0.4 : 1).accessibilityIdentifier("tg.add.button")
                        }
                        if let message { Text(message).dsFont(13, .medium, relativeTo: .footnote).foregroundStyle(STVTheme.accent) }
                    }
                    .dsRow(vertical: 14)
                    DSToggleRow("标记为成人频道", isOn: $addAdult)
                }
            }
            plain { Text("已订阅（\(store.channels.count)）").dsFont(13, .semibold, relativeTo: .footnote).foregroundStyle(STVTheme.secondary).padding(.horizontal, 20).padding(.top, 8) }
            let channels = store.channels
            ForEach(channels) { c in
                let first = c.id == channels.first?.id
                Group {
                    if c.isAdult && !gate.showAdultChannels {
                        HStack(spacing: 10) { Image(systemName: "lock"); Text("成人频道（已隐藏）") }.dsFont(15).foregroundStyle(STVTheme.secondary).frame(minHeight: 52)
                    } else {
                        channelRow(c)
                    }
                }
                .overlay(alignment: .top) { if !first { Hairline() } }
                .padding(.horizontal, 14)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(CardSlice(first: first, last: c.id == channels.last?.id).padding(.horizontal, 16))
            }
            .onDelete { idx in idx.map { store.channels[$0] }.forEach(store.remove) }
            .onMove { store.move(from: $0, to: $1) }
            plain {
                VStack(alignment: .leading, spacing: 22) {
                    DSSection("过滤", separatorInset: 58) {
                        // Buttons, not NavigationLinks: a List row adds its own chevron to links and fires all of them.
                        DSRow("屏蔽规则与广告过滤", icon: "hand.raised", value: "\(store.rules.count) 条", chevron: true) { Router.push(.tgRules) }.accessibilityIdentifier("tg.rules")
                    }
                    DSSection("账号（私有频道 / 机器人）", separatorInset: 58) {
                        DSRow("TDLib 登录", icon: "person.crop.circle", value: TDLibService.shared.state.label, chevron: true) { Router.push(.tdlib) }.accessibilityIdentifier("tg.tdlib")
                        DSRow("下载管理", icon: "arrow.down.circle", chevron: true) { Router.push(.downloads) }
                    }
                    DSSection("t.me 访问地址", footer: "t.me 在部分网络不可达时，可填自建的 t.me 反向代理（路径与 t.me 相同）。留空 = https://t.me") {
                        HStack(spacing: 10) {
                            DSTextField("https://t.me", text: $base, icon: "link").textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .onSubmit { saveBase() }
                            Button { saveBase() } label: { PillButtonLabel(title: "保存", height: 46) }.buttonStyle(PressScale())
                        }
                        .dsRow(vertical: 14)
                    }
                    DSSection { DSRow("清空频道缓存", icon: "trash", role: .destructive) { confirmClear = true } }
                }
                .padding(.top, 14).padding(.bottom, 32)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
        .dsNavigation("频道管理") {
            DSBarButton(title: editMode.isEditing ? "完成" : "编辑") { withAnimation(DS.panel) { editMode = editMode.isEditing ? .inactive : .active } }
        }
        .dsToast($toast, icon: "checkmark.circle.fill")
        .dsConfirm("清空频道缓存？", isPresented: $confirmClear, message: "只删除本机缓存的消息，订阅和规则不受影响。", confirm: "清空") { store.clearCache(); toast = "已清空缓存" }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tg.manageView")
    }

    private func plain<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)).listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

    private func saveBase() { UserDefaults.standard.set(base, forKey: TGClient.baseKey); toast = "已保存" }

    private func add() {
        guard let n = store.add(addText, adult: addAdult) else { message = "无效的频道名"; return }
        addText = ""; message = "已订阅 @\(n)"
        Task { await store.refresh(n) }
    }

    private func channelRow(_ c: TGChannel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(c.displayName).dsFont(16, .medium).foregroundStyle(STVTheme.text).lineLimit(1)
                Text("@" + c.username).dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if !c.subscribers.isEmpty { Text(c.subscribers).dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.tertiary).lineLimit(1) }
            }
            if let why = c.previewUnavailable { Text(why).dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.accentWarm) }
            HStack(spacing: 8) {
                Button { var x = c; x.isAdult.toggle(); store.update(x); DS.tick() } label: { Text("成人") }
                    .buttonStyle(ToneChipStyle(on: c.isAdult, small: true)).accessibilityAddTraits(c.isAdult ? .isSelected : [])
                Button { var x = c; x.adBlock.toggle(); store.update(x); DS.tick() } label: { Text("去广告") }
                    .buttonStyle(ToneChipStyle(on: c.adBlock, small: true)).accessibilityAddTraits(c.adBlock ? .isSelected : [])
                    .accessibilityIdentifier("tg.adblock.\(c.id)")
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tg.channel.\(c.id)")
    }
}

/// 屏蔽规则: mode, built-in heuristics, rules (global / per channel), import / export.
struct TGRulesView: View {
    @ObservedObject private var store = TGStore.shared
    @ObservedObject private var feed = TGFeedModel.shared
    @State private var kind: TGRule.Kind = .keyword
    @State private var pattern = ""
    @State private var scope = ""
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DSSection("过滤方式", footer: "内置识别：#广告/#推广 等标记、博彩/引流类词、外链按钮、纯推广链接（短文 + 外链/邀请链接）、置顶推广。每个频道可在频道管理里单独关闭。") {
                    SegmentedTabs(items: Array(TGFilterMode.allCases), selection: Binding(get: { store.mode }, set: { store.mode = $0 }), label: \.label, idPrefix: "rules.mode").dsRow(vertical: 14)
                    DSToggleRow("内置广告识别", isOn: Binding(get: { store.heuristics }, set: { store.heuristics = $0 }))
                    let c = feed.counts(nil)
                    Text("当前缓存 \(c.total) 条，命中 \(c.blocked) 条").dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.secondary).accessibilityIdentifier("rules.stats").dsRow()
                }
                DSSection("添加规则") {
                    VStack(alignment: .leading, spacing: 12) {
                        SegmentedTabs(items: Array(TGRule.Kind.allCases), selection: $kind, label: \.label, idPrefix: "rules.kind")
                        HStack(spacing: 10) {
                            DSTextField(kind == .domain ? "example.com" : kind == .regex ? "正则表达式" : "关键词", text: $pattern, mono: kind == .regex, id: "rules.pattern")
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            let empty = pattern.trimmingCharacters(in: .whitespaces).isEmpty
                            Button(action: add) { PillButtonLabel(title: "添加", height: 46) }.buttonStyle(PressScale())
                                .disabled(empty).opacity(empty ? 0.4 : 1).accessibilityIdentifier("rules.add")
                        }
                    }
                    .dsRow(vertical: 14)
                    DSPicker("范围", options: [""] + store.channels.map(\.id), selection: $scope, style: .row) { id in
                        id.isEmpty ? "全部频道" : "@" + (store.channel(id)?.username ?? id)
                    }
                }
                if !store.rules.isEmpty {
                    DSSection("规则（\(store.rules.count)）", separatorInset: 50) {
                        ForEach(store.rules) { r in ruleRow(r) }
                    }
                }
                DSSection("导入 / 导出", separatorInset: 58) {
                    ShareLink(item: store.exportText, preview: SharePreview("i短剧 频道屏蔽规则")) {
                        DSRowLabel(title: "导出（JSON）", icon: "square.and.arrow.up", chevron: true).dsRow()
                    }
                    .buttonStyle(DSRowPress())
                    DSRow("复制规则 JSON", icon: "doc.on.doc") { UIPasteboard.general.string = store.exportText; message = "已复制到剪贴板" }
                    DSRow("从剪贴板导入", icon: "doc.on.clipboard") {
                        let n = store.importText(UIPasteboard.general.string ?? ""); message = n > 0 ? "已导入 \(n) 条" : "剪贴板里没有可识别的规则"
                    }
                    DSRow("从文件导入", icon: "folder") { importing = true }
                }
            }
            .padding(.top, 4).padding(.bottom, 32)
        }
        .dsNavigation("屏蔽规则")
        .dsToast($message)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { r in
            guard let u = try? r.get() else { return }
            let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let n = store.importText((try? String(contentsOf: u, encoding: .utf8)) ?? "")
            message = "已导入 \(n) 条"
        }
    }

    private func add() {
        if kind == .regex, (try? NSRegularExpression(pattern: pattern)) == nil { message = "正则无效"; return }
        store.addRule(TGRule(kind: kind, pattern: pattern.trimmingCharacters(in: .whitespaces), channel: scope.isEmpty ? nil : scope))
        pattern = ""; message = "已添加"
    }

    private func ruleRow(_ r: TGRule) -> some View {
        HStack(spacing: 12) {
            Button { DS.tick(); store.toggleRule(r) } label: {
                HStack(spacing: 12) {
                    Image(systemName: r.enabled ? "checkmark.circle.fill" : "circle").font(.system(size: 20)).foregroundStyle(r.enabled ? STVTheme.accent : STVTheme.tertiary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.pattern).dsFont(15).foregroundStyle(STVTheme.text).lineLimit(1)
                        Text(r.kind.label + " · " + (r.channel.map { "@" + $0 } ?? "全部频道")).dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale(scale: 0.99)).accessibilityAddTraits(r.enabled ? .isSelected : [])
            Button { withAnimation(DS.panel) { store.removeRule(r) } } label: {
                Image(systemName: "trash").font(.system(size: 15, weight: .medium)).foregroundStyle(DSTone.danger).frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(PressScale()).accessibilityLabel("删除规则 \(r.pattern)")
        }
        .dsRow()
    }
}

/// Search: online (t.me/s ?q=, paged) or local full-text over cached posts; one channel or all.
struct TGSearchView: View {
    @State var channel: String?
    @ObservedObject private var store = TGStore.shared
    @State private var q = ""
    @State private var online = true
    @State private var results: [TGPost] = []
    @State private var cursors: [String: Int] = [:]
    @State private var errors: [String] = []
    @State private var searching = false
    @State private var searched = false
    @State private var viewer: ChannelFeedView.ViewerPayload?
    @State private var actions = TGActions()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 12) {
                    SearchField(text: $q, placeholder: "搜索频道消息", id: "tgsearch.field", onSubmit: run)
                    HStack(spacing: 10) {
                        SegmentedTabs(items: [true, false], selection: $online, label: { $0 ? "在线" : "本地缓存" }, idPrefix: "tgsearch.mode").frame(width: 190)
                        Spacer(minLength: 0)
                        DSPicker("频道", options: [""] + store.visibleChannels.map(\.id), selection: Binding(get: { channel ?? "" }, set: { channel = $0.isEmpty ? nil : $0 }), style: .menu) { id in
                            id.isEmpty ? "全部订阅" : store.channel(id)?.displayName ?? id
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14)
                ForEach(errors, id: \.self) { Text($0).dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.accentWarm).padding(.horizontal, 16).padding(.bottom, 6) }
                if searched && results.isEmpty && !searching { DSEmptyState("没有结果", systemImage: "magnifyingglass") }
                ForEach(results) { p in
                    TGPostCard(post: p, channel: store.channel(p.channel), actions: actions)
                    Hairline().padding(.leading, 66)
                }
                if searching { DSLoading() }
                else if online && !cursors.isEmpty && !results.isEmpty {
                    Button { more() } label: { MiniButtonLabel(title: "加载更多") }.buttonStyle(PressScale()).frame(maxWidth: .infinity).padding(20).accessibilityIdentifier("tgsearch.more")
                }
            }
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.immediately)
        .dsNavigation("搜索频道")
        .compatOnChange(of: online) { if searched { run() } }
        .compatOnChange(of: channel) { if searched { run() } }
        .fullScreenCover(item: $viewer) { v in ImageViewer(items: v.urls.map { .init(url: $0) }, index: v.index) }
        .onAppear {
            actions.openImages = { p, _ in viewer = .init(urls: p.media.filter { $0.kind == .photo }.map(\.thumb), index: 0) }
            actions.playVideo = { p, i in if let s = TGVideoProvider.series(p, media: i, channel: store.channel(p.channel)) { Router.push(.play(s, 0)) } }
            actions.download = { p, i in TGDownloads.shared.enqueue(post: p, media: i, channel: store.channel(p.channel)) }
        }
    }

    private func run() {
        let t = q.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
        searched = true; errors = []; cursors = [:]
        if !online { results = store.localSearch(t, channel: channel); return }
        searching = true
        Task {
            let r = await store.remoteSearch(t, channel: channel)
            results = r.posts; cursors = r.cursors; errors = r.errors; searching = false
        }
    }

    private func more() {
        searching = true
        Task {
            let r = await store.remoteSearch(q, channel: channel, cursors: cursors)
            let seen = Set(results.map(\.id))
            results += r.posts.filter { !seen.contains($0.id) }
            cursors = r.cursors; searching = false
        }
    }
}

/// 下载管理: queue, progress, pause/resume, delete, offline play, save to Photos.
struct DownloadsView: View {
    @ObservedObject private var dl = TGDownloads.shared
    @State private var viewer: ChannelFeedView.ViewerPayload?
    @State private var message: String?

    var body: some View {
        let items = dl.visible
        Group {
            if items.isEmpty {
                ScrollView { DSEmptyState("还没有下载", systemImage: "arrow.down.circle", message: "在频道消息上点 ⬇︎ 或长按 → 下载。").padding(.top, 60) }
            } else {
                List {
                    ForEach(items) { d in
                        row(d)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12)).listRowBackground(Color.clear).listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) { Button(role: .destructive) { dl.delete(d) } label: { Label("删除", systemImage: "trash") } }
                            .contextMenu { Button("删除", systemImage: "trash", role: .destructive) { dl.delete(d) } }
                    }
                    if dl.totalBytes > 0 {
                        Text("已下载 \(ByteCountFormatter.string(fromByteCount: dl.totalBytes, countStyle: .file))，保存在本机「文稿/Downloads」。左滑可删除。")
                            .dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.tertiary)
                            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 24, trailing: 20)).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .dsNavigation("下载管理")
        .dsToast($message)
        .fullScreenCover(item: $viewer) { v in ImageViewer(items: v.urls.map { .init(url: $0) }, index: v.index) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads.view")
    }

    private func row(_ d: TGDownload) -> some View {
        HStack(spacing: 12) {
            CoverView(url: d.state == .done && d.kind == .photo ? (d.localURL?.absoluteString ?? d.thumb) : d.thumb, corner: 10, maxPixelSize: CoverPixels.thumb)
                .frame(width: 80, height: 60)
                .overlay { if d.kind == .video { Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(.white).frame(width: 30, height: 30).background(.black.opacity(0.4), in: Circle()) } }
            VStack(alignment: .leading, spacing: 5) {
                Text(d.title).dsFont(15, .medium, relativeTo: .subheadline).foregroundStyle(STVTheme.text).lineLimit(1)
                Text(d.channel).dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.secondary).lineLimit(1)
                switch d.state {
                case .done: Text("已完成 · " + ByteCountFormatter.string(fromByteCount: d.received, countStyle: .file)).dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.ok)
                case .failed: Text(d.error ?? "失败").dsFont(12, relativeTo: .caption).foregroundStyle(DSTone.danger).lineLimit(2)
                default:
                    DSProgressBar(value: d.progress)
                    Text(stateText(d)).font(.caption2.monospacedDigit()).foregroundStyle(STVTheme.secondary)
                }
            }
            Spacer(minLength: 0)
            actions(d)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads.row.\(d.id)")
    }

    private func stateText(_ d: TGDownload) -> String {
        let got = ByteCountFormatter.string(fromByteCount: d.received, countStyle: .file)
        let tot = d.expected > 0 ? " / " + ByteCountFormatter.string(fromByteCount: d.expected, countStyle: .file) : ""
        switch d.state { case .queued: return "排队中"; case .paused: return "已暂停 · \(got)\(tot)"; default: return "\(got)\(tot) · \(Int(d.progress * 100))%" }
    }

    @ViewBuilder private func actions(_ d: TGDownload) -> some View {
        HStack(spacing: 2) {
            switch d.state {
            case .running, .queued:
                icon("pause.circle", "暂停") { dl.pause(d) }.accessibilityIdentifier("downloads.pause.\(d.id)")
            case .paused, .failed:
                icon("arrow.clockwise.circle", "继续") { dl.resume(d) }.accessibilityIdentifier("downloads.resume.\(d.id)")
            case .done:
                icon(d.kind == .video ? "play.circle" : "photo", "离线打开") { open(d) }.accessibilityIdentifier("downloads.open.\(d.id)")
                icon("square.and.arrow.down", "保存到相册") {
                    guard let u = d.localURL else { return }
                    Task {
                        do { try await TGDownloads.saveToPhotos(u, video: d.kind == .video); message = "已保存到相册" }
                        catch { message = error.localizedDescription }
                    }
                }
                .accessibilityIdentifier("downloads.save.\(d.id)")
            }
        }
    }

    private func icon(_ name: String, _ label: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) { Image(systemName: name).font(.system(size: 20)).foregroundStyle(STVTheme.accent).frame(width: 40, height: 44).contentShape(Rectangle()) }
            .buttonStyle(PressScale()).accessibilityLabel(label)
    }

    private func open(_ d: TGDownload) {
        if d.kind == .video { Router.push(.play(TGVideoProvider.series(download: d), 0)) }
        else if let u = d.localURL { viewer = .init(urls: [u.absoluteString], index: 0) }
    }
}

/// TDLib login: the user's own api_id / api_hash (Keychain), phone → code → 2FA password.
/// Leaving this page never logs out; only 「退出登录」 (with confirmation) ends the session.
struct TDLibSettingsView: View {
    @ObservedObject private var td = TDLibService.shared
    @State private var apiId = TDCredentials.load()?.apiId ?? ""
    @State private var apiHash = TDCredentials.load()?.apiHash ?? ""
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var message: String?
    @State private var confirmLogout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DSSection("状态", footer: "登录状态保存在本机（应用支持目录 + 钥匙串），杀掉 App 重进会自动恢复。") {
                    HStack(spacing: 10) {
                        Circle().fill(td.state.isReady ? STVTheme.ok : STVTheme.tertiary).frame(width: 8, height: 8)
                        Text(td.state.label).dsFont(16, .medium).foregroundStyle(STVTheme.text).accessibilityIdentifier("tdlib.state")
                        Spacer(minLength: 0)
                        if td.state.isStarting { DSSpinner(size: 18) }
                    }
                    .dsRow()
                    if case .unavailable = td.state {
                        Text("当前安装包没有链接 TDLib 原生库（TDLibKit）。频道的公开网页预览、搜索、下载不受影响；私有频道、搜索私有消息和机器人 /start 需要带 TDLib 的构建。")
                            .dsFont(13, relativeTo: .footnote).foregroundStyle(STVTheme.secondary).lineSpacing(3).dsRow()
                    }
                    if case .failed = td.state, td.hasLocalSession {
                        DSRow("重置本地会话", subtitle: "只删本机数据，需重新登录", role: .destructive) { td.resetLocalSession() }
                            .accessibilityIdentifier("tdlib.reset")
                    }
                }
                DSSection("API 凭据", footer: "在 my.telegram.org → API development tools 用你自己的账号申请。应用不内置任何人的 api_id / api_hash。") {
                    VStack(spacing: 10) {
                        DSTextField("api_id（数字）", text: $apiId, icon: "number", id: "tdlib.apiId").keyboardType(.numberPad)
                        DSTextField("api_hash（32 位十六进制）", text: $apiHash, icon: "key", secure: true, id: "tdlib.apiHash").textInputAutocapitalization(.never)
                        Button(action: saveCredentials) { PillButtonLabel(title: "保存到钥匙串", height: 46, expand: true) }
                            .buttonStyle(PressScale(scale: 0.98)).accessibilityIdentifier("tdlib.saveCreds")
                    }
                    .dsRow(vertical: 14)
                    if !td.state.isReady {
                        DSRow("清除凭据", role: .destructive) { TDCredentials.clear(); apiId = ""; apiHash = ""; message = "已清除" }
                    }
                }
                if TDEngineFactory.available {
                    DSSection("登录") { login }
                    if td.state.isReady {
                        DSSection("受限频道", footer: td.sensitive.canChange
                                  ? "对应 Telegram 账号设置「显示敏感内容」（会同步到你的账号）。受限频道读不到时打开它。"
                                  : "Telegram 暂不允许此账号在第三方客户端更改。请在 web.telegram.org 或桌面版 设置 → 隐私与安全 → 敏感内容 打开「显示敏感内容」，然后回来刷新。") {
                            DSToggleRow("显示敏感内容", isOn: Binding(get: { td.sensitive.enabled }, set: { on in
                                Task { do { try await td.setSensitive(on) } catch { message = "Telegram 不允许此账号更改：\(error.localizedDescription)" } }
                            }))
                            .disabled(!td.sensitive.canChange).accessibilityIdentifier("tdlib.sensitive")
                        }
                    }
                }
            }
            .padding(.top, 4).padding(.bottom, 32)
        }
        .accessibilityIdentifier("tdlib.view")
        .scrollDismissesKeyboard(.interactively)
        .dsNavigation("TDLib 登录")
        .dsToast($message)
        // Entering the page restores a saved session if launch-time bootstrap hasn't yet.
        .task { if case .idle = td.state, td.hasLocalSession { await td.start() } else { await td.refreshSensitive() } }
        .dsConfirm("退出 Telegram 登录？", isPresented: $confirmLogout,
                   message: "会在 Telegram 端结束这个登录设备，下次需要重新收验证码。只是离开页面或关掉 App 不需要退出。",
                   confirm: "退出登录并删除本机会话") { Task { await td.logOut() } }
    }

    @ViewBuilder private var login: some View {
        switch td.state {
        case .idle, .needsCredentials, .failed, .closed:
            action("启动 TDLib", id: "tdlib.start") { await td.start() }
        case .starting:
            HStack(spacing: 10) { DSSpinner(size: 18); Text("正在连接…").dsFont(15).foregroundStyle(STVTheme.secondary) }.dsRow()
        case .waitPhone:
            field { DSTextField("+86 手机号", text: $phone, icon: "phone", id: "tdlib.phone").keyboardType(.phonePad) }
            action("发送验证码", id: "tdlib.sendPhone", disabled: phone.isEmpty) { await td.submit(phone: phone) }
        case .waitCode:
            field { DSTextField("验证码", text: $code, icon: "ellipsis.message", id: "tdlib.code").keyboardType(.numberPad) }
            action("登录", id: "tdlib.sendCode") { await td.submit(code: code) }
        case .waitPassword:
            field { DSTextField("两步验证密码", text: $password, icon: "lock", secure: true) }
            action("提交", id: "tdlib.sendPassword") { await td.submit(password: password) }
        case .ready:
            DSRow("刷新已加入的频道/群", icon: "arrow.clockwise") { Task { await td.loadChats() } }
            ForEach(td.chats) { c in DSLinkRow(c.title, route: Route.tdChat(c.id, c.title), icon: c.isChannel ? "megaphone" : "person.2") }
            DSRow("退出登录", icon: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLogout = true }.accessibilityIdentifier("tdlib.logout")
        default: EmptyView()
        }
    }

    private func field<C: View>(@ViewBuilder _ c: () -> C) -> some View { c().dsRow(vertical: 12) }

    private func action(_ title: String, id: String, disabled: Bool = false, _ f: @escaping () async -> Void) -> some View {
        Button { Task { await f() } } label: { PillButtonLabel(title: title, height: 46, expand: true) }
            .buttonStyle(PressScale(scale: 0.98)).disabled(disabled).opacity(disabled ? 0.4 : 1)
            .accessibilityIdentifier(id)
            .dsRow(vertical: 12)
    }

    private func saveCredentials() {
        let c = TDCredentials(apiId: apiId.trimmingCharacters(in: .whitespaces), apiHash: apiHash.trimmingCharacters(in: .whitespaces).lowercased())
        guard c.isValid else { message = "api_id 应为数字，api_hash 应为 32 位十六进制"; return }
        td.saveCredentials(c); message = "已保存（仅本机钥匙串）"
    }
}

/// A joined (private) channel / group read through TDLib: history with paging + searchChatMessages.
struct TDChatView: View {
    let chatId: Int64
    let title: String
    @ObservedObject private var td = TDLibService.shared
    @State private var posts: [TGPost] = []
    @State private var q = ""
    @State private var error: String?
    @State private var loading = false
    @State private var viewer: ChannelFeedView.ViewerPayload?
    @State private var actions = TGActions()

    var body: some View {
        let channel = TGChannel(username: title)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SearchField(text: $q, placeholder: "搜索本频道（searchChatMessages）", onSubmit: { Task { await search() } }).padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
                if let error { Text(error).dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.accentWarm).padding(.horizontal, 16) }
                ForEach(posts) { p in
                    TGPostCard(post: p, channel: channel, actions: actions)
                    Hairline().padding(.leading, 66)
                }
                if loading { DSLoading() }
                else if !posts.isEmpty && q.isEmpty {
                    Color.clear.frame(height: 20).onAppear { Task { await more() } }
                }
            }
        }
        .dsNavigation(title)
        .task { await more() }
        .fullScreenCover(item: $viewer) { v in ImageViewer(items: v.urls.map { .init(url: $0) }, index: v.index) }
        .onAppear {
            actions.openImages = { p, _ in viewer = .init(urls: p.media.filter { $0.kind == .photo }.map(\.thumb), index: 0) }
            actions.playVideo = { p, i in
                guard let v = p.media[i].video else { return }
                Router.push(.play(HGSeries(source: .telegram, seriesId: "td/\(p.channel)/\(p.msgId)/\(i)", title: title, cover: p.media[i].thumb,
                                           duration: p.media[i].duration, orientation: "landscape", page: v), 0))
            }
        }
    }

    private func more() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let r = try await td.history(chatId, channel: "td\(chatId)", before: posts.last?.msgId ?? 0)
            let seen = Set(posts.map(\.id)); posts += r.filter { !seen.contains($0.id) }
        } catch { self.error = error.localizedDescription }
    }

    private func search() async {
        if q.isEmpty { posts = []; await more(); return }
        loading = true; defer { loading = false }
        do { posts = try await td.search(chatId, channel: "td\(chatId)", q) } catch { self.error = error.localizedDescription }
    }
}
