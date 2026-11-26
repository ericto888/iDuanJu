import SwiftUI

/// 选择站点: badges, why a site is unavailable, latency; 测速 runs on the sites that can answer.
struct SitePicker: View {
    enum Choice { case site(String), config, bridge }

    let repo: TVBoxRepo
    let sites: [TVBoxSiteRef]
    let current: String?
    let onChoice: (Choice) -> Void
    private let meters = TVBoxStore.shared.meters
    @State private var query = ""
    @State private var kind = ""

    private var kinds: [String] {
        var seen = Set<String>()
        return [""] + sites.map(\.site.kind.badge).filter { seen.insert($0).inserted }
    }

    private var shown: [TVBoxSiteRef] {
        let q = query.trimmed
        return sites.filter { s in
            (kind.isEmpty || s.site.kind.badge == kind) && (q.isEmpty || s.site.name.containsIgnoringCase(q) || s.site.key.containsIgnoringCase(q))
        }
    }

    var body: some View {
        let kinds = kinds, shown = shown
        DSSheet(title: "选择站点", subtitle: repo.name, trailing: {
            TVBoxSpeedButton(meters: meters) { TVBoxStore.shared.testSpeed(TVBoxStore.shared.runnable(repo, sites).map(\.uid)) }
            Button { onChoice(.config) } label: { MiniButtonLabel(title: "切换配置") }.buttonStyle(PressScale()).accessibilityIdentifier("tvbox.switchConfig")
        }, content: {
            VStack(spacing: 10) {
                DSTextField("搜索 \(sites.count) 个站点", text: $query, icon: "magnifyingglass", id: "tvbox.site.search")
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .padding(.horizontal, 16)
                if kinds.count > 2 {
                    ChipRow(items: kinds, selection: $kind, label: { $0.isEmpty ? "全部" : $0 }, neutral: { $0.isEmpty }, small: true, idPrefix: "tvbox.kind").frame(height: 34)
                }
                list(shown)
            }
        }, footer: { EmptyView() })
        .dsSheetChrome()
        .onAppear { TVBoxStore.shared.meters.refreshStatus(sites.map(\.uid)) }
    }

    private func list(_ shown: [TVBoxSiteRef]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { s in
                        row(s).id(s.uid)
                        if s.uid != shown.last?.uid { Hairline().padding(.leading, 16) }
                    }
                    if shown.isEmpty { DSEmptyState("没有匹配的站点", systemImage: "magnifyingglass") }
                }
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
        }
    }

    private func row(_ s: TVBoxSiteRef) -> some View {
        SitePickerRow(ref: s, block: repo.block(s.site.kind), selected: s.uid == current, meters: meters, onChoice: onChoice)
    }
}

/// Observes the meters itself, so a speed test redraws the rows on screen and nothing else.
private struct SitePickerRow: View {
    let ref: TVBoxSiteRef
    let block: SiteBlock?
    let selected: Bool
    @ObservedObject var meters: TVBoxMeters
    let onChoice: (SitePicker.Choice) -> Void

    var body: some View {
        Button { DS.tick(); onChoice(.site(ref.uid)) } label: {
            TVBoxRow(title: ref.site.name, note: note, warn: block != nil, selected: selected) {
                TVBoxKindBadge(kind: ref.site.kind).frame(minWidth: 44, alignment: .leading)
            } trailing: {
                if block == .bridge { Color.clear.frame(width: 64, height: 1) } else { TVBoxLatency(uid: ref.uid, meters: meters) }
            }
        }
        .buttonStyle(DSRowPress())
        .overlay(alignment: .trailing) {
            if block == .bridge {
                Button { onChoice(.bridge) } label: { MiniButtonLabel(title: "去配对") }
                    .buttonStyle(PressScale())
                    .padding(.trailing, selected ? 42 : 16)
                    .accessibilityIdentifier("tvbox.pair")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tvbox.site.\(ref.site.key)")
    }

    private var note: String? {
        if block == .bridge { return "需要桥接：配对一台安卓设备后可用" }
        if let block { return block.note }
        if meters.status[ref.uid] == .ready { return "已加载" }
        return ref.site.searchable ? nil : "不参与搜索"
    }
}

/// 选择直播源.
struct LivePicker: View {
    let repo: TVBoxRepo
    let lives: [TVBoxLiveRef]
    let current: String?
    let onPick: (String) -> Void

    var body: some View {
        DSSheet("选择直播源", subtitle: repo.name) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(lives) { l in
                        Button { DS.tick(); onPick(l.uid) } label: {
                            TVBoxRow(title: l.live.name, note: note(l.live), warn: block(l.live) != nil, selected: l.uid == current) {
                                if let kind = l.live.kind { TVBoxKindBadge(kind: kind) }
                            } trailing: { EmptyView() }
                        }
                        .buttonStyle(DSRowPress())
                        .accessibilityAddTraits(l.uid == current ? .isSelected : [])
                        if l.uid != lives.last?.uid { Hairline().padding(.leading, 16) }
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .dsSheetChrome(lives.count > 6 ? [.medium, .large] : [.height(CGFloat(140 + lives.count * 62)), .large])
    }

    private func block(_ l: TVBoxLive) -> SiteBlock? { l.kind.flatMap { repo.block($0) } }
    private func note(_ l: TVBoxLive) -> String {
        if let b = block(l) { return b.note }
        return l.url.nonEmptyOr(l.kind == nil ? "配置内置" : l.api)
    }
}
