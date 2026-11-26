import Combine
import SwiftUI
import UIKit

// Pieces shared by the TVBox pages, on the design kit (docs/unified-player-tvbox.md §5).

/// The engine's message of a failure.
func tvboxErrorText(_ e: Error) -> String { SpiderErrors.text(e).nonEmptyOr("加载失败") }

/// Why a site cannot run on this device right now.
enum SiteBlock: Equatable {
    case unsupported, trust, bridge, python

    var note: String {
        switch self {
        case .unsupported: return "不支持的类型"
        case .trust: return "需要信任配置"
        case .bridge: return "需要桥接"
        case .python: return PythonRuntime.missingMessage
        }
    }
}

extension BridgeStatus {
    /// Only whether a device is paired: the status itself changes with every bridge request.
    static let pairing = BridgeClient.shared.status.$state.map { _ in BridgeClient.shared.paired }.removeDuplicates()
}

extension TVBoxRepo {
    @MainActor func block(_ kind: SiteKind) -> SiteBlock? {
        if kind == .unsupported { return .unsupported }
        if kind.isCode && !trusted { return .trust }
        if kind == .jar && !BridgeClient.shared.paired { return .bridge }
        if kind == .py && !PythonRuntime.isAvailable { return .python }
        return nil
    }
}

extension TVBoxStore {
    /// Panes of the hub belong to one state of one config: a switch, a refresh or a trust change starts over.
    static func stamp(_ r: TVBoxRepo?) -> String { r.map { "\($0.id)|\($0.record.updatedAt)|\($0.record.trust.rawValue)" } ?? "" }

    /// Sites a speed test or an aggregated search may touch.
    func runnable(_ repo: TVBoxRepo, _ sites: [TVBoxSiteRef]) -> [TVBoxSiteRef] { sites.filter { repo.block($0.site.kind) == nil } }
}

// MARK: - Labels

struct TVBoxKindBadge: View {
    let kind: SiteKind
    var body: some View { DSStatus(text: kind.badge, tone: tone) }
    private var tone: DSStatus.Tone {
        switch kind {
        case .cmsXml, .cmsJson: return .ok
        case .remote: return .accent
        case .js, .py, .jar: return .warn
        case .unsupported: return .muted
        }
    }
}

/// Measured latency of one site: the only part of a row that redraws while a speed test runs.
struct TVBoxLatency: View {
    let uid: String
    @ObservedObject var meters: TVBoxMeters
    var body: some View {
        if let ms = meters.latency[uid] {
            HStack(spacing: 5) {
                Circle().fill(tint(ms)).frame(width: 6, height: 6)
                Text(ms < 0 ? "失败" : "\(ms) ms").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(tint(ms))
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
    }
    private func tint(_ ms: Int) -> Color { ms < 0 ? STVTheme.tertiary : ms < 1500 ? STVTheme.ok : STVTheme.accentWarm }
}

/// 测速 / 停止.
struct TVBoxSpeedButton: View {
    @ObservedObject var meters: TVBoxMeters
    let start: () -> Void
    var body: some View {
        Button { DS.tick(); if meters.testing { TVBoxStore.shared.stopSpeedTest() } else { start() } } label: {
            HStack(spacing: 5) {
                if meters.testing { DSSpinner(size: 12, tint: STVTheme.accent) } else { Image(systemName: "speedometer").font(.system(size: 12, weight: .semibold)) }
                Text(meters.testing ? "停止" : "测速").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(STVTheme.accent)
            .padding(.horizontal, 12).frame(height: 30)
            .background(Capsule().fill(STVTheme.accentSoft))
            .contentShape(Capsule().inset(by: -7))
        }
        .buttonStyle(PressScale())
        .accessibilityIdentifier("tvbox.speed")
    }
}

// MARK: - Rows

/// Row of a picker or a card: badge, name, one or two lines of detail, accessories, check mark.
struct TVBoxRow<Leading: View, Trailing: View>: View {
    let title: String
    var note: String? = nil
    var warn = false
    var selected = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                Text(title).dsFont(16, selected ? .semibold : .medium).foregroundStyle(selected ? STVTheme.accent : STVTheme.text).lineLimit(1)
                if let note, !note.isEmpty {
                    Text(note).dsFont(12, relativeTo: .caption).foregroundStyle(warn ? STVTheme.accentWarm : STVTheme.secondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
            if selected { Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(STVTheme.accent).accessibilityHidden(true) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }
}

extension TVBoxRow where Leading == EmptyView {
    init(title: String, note: String? = nil, warn: Bool = false, selected: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, note: note, warn: warn, selected: selected, leading: { EmptyView() }, trailing: trailing)
    }
}

extension TVBoxRow where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, note: String? = nil, warn: Bool = false, selected: Bool = false) {
        self.init(title: title, note: note, warn: warn, selected: selected, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// One row of a long card built lazily: `DSSection` lays out all of its rows at once, which is too much for hundreds of sites.
private struct TVBoxSlice: ViewModifier {
    let first: Bool, last: Bool
    func body(content: Content) -> some View {
        content
            .background { CardSlice(first: first, last: last) }
            .overlay(alignment: .top) { if !first { Hairline().padding(.leading, 16) } }
            .padding(.horizontal, 16)
    }
}

extension View {
    func tvboxSlice(first: Bool, last: Bool) -> some View { modifier(TVBoxSlice(first: first, last: last)) }
}

// MARK: - Search field

/// Search capsule with its controls inside (scope chips), in the shape of `SearchField`. Floating: glass, plain chips on it.
struct TVBoxSearchField<Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    let id: String
    var onSubmit: () -> Void = {}
    @ViewBuilder var trailing: Trailing
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(STVTheme.secondary).accessibilityHidden(true)
            TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundColor(STVTheme.tertiary))
                .focused($focused).submitLabel(.search).onSubmit(onSubmit)
                .font(.system(size: 16)).foregroundStyle(STVTheme.text).tint(STVTheme.accent)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityIdentifier(id)
            if !text.isEmpty {
                Button { text = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(STVTheme.tertiary)
                        .frame(width: 30, height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("清除")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            trailing
        }
        .padding(.leading, 14).padding(.trailing, 6).frame(height: 44)
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .onGlassSurface()
        .liquidGlassCapsule(interactive: true)
        .animation(DS.press, value: text.isEmpty)
    }
}

extension TVBoxSearchField where Trailing == EmptyView {
    init(placeholder: String, text: Binding<String>, id: String, onSubmit: @escaping () -> Void = {}) {
        self.init(placeholder: placeholder, text: text, id: id, onSubmit: onSubmit, trailing: { EmptyView() })
    }
}

// MARK: - Layout

/// Chips that wrap onto as many lines as they need.
struct ChipWrap: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: place(subviews, width) { _, _, _ in })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        _ = place(subviews, bounds.width) { i, at, size in
            subviews[i].place(at: CGPoint(x: bounds.minX + at.x, y: bounds.minY + at.y), proposal: ProposedViewSize(size))
        }
    }

    /// Total height.
    private func place(_ subviews: Subviews, _ width: CGFloat, _ put: (Int, CGPoint, CGSize) -> Void) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for i in subviews.indices {
            let ideal = subviews[i].sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, width), height: ideal.height)
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            put(i, CGPoint(x: x, y: y), size)
            x += size.width + spacing
            line = max(line, size.height)
        }
        return y + line
    }
}

private struct KeptPageActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// False on a page that `KeptPages` only keeps in memory.
    var keptPageActive: Bool {
        get { self[KeptPageActiveKey.self] }
        set { self[KeptPageActiveKey.self] = newValue }
    }
}

/// Shows one page and keeps the last few alive behind it: going back to one is instant and lands where it was left.
struct KeptPages<Key: Hashable, Page: View>: View {
    let current: Key
    var limit = 3
    @ViewBuilder let page: (Key) -> Page
    @State private var recent: [Key] = []

    var body: some View {
        let shown = recent.contains(current) ? recent : recent + [current]
        ZStack {
            ForEach(shown, id: \.self) { k in
                let on = k == current
                page(k)
                    .environment(\.keptPageActive, on)
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(on)
                    .accessibilityHidden(!on)
                    .zIndex(on ? 1 : 0)
            }
        }
        .onAppear { touch(current) }
        .compatOnChange(of: current) { k in touch(k) }
    }

    private func touch(_ k: Key) {
        let next = Array((recent.filter { $0 != k } + [k]).suffix(limit))
        if next != recent { recent = next }
    }
}

// MARK: - Dialogs

extension View {
    /// Asked once per config before any of its code runs; leaving it unanswered means 暂不.
    func tvboxTrustDialog(_ repo: Binding<TVBoxRepo?>) -> some View {
        let r = repo.wrappedValue
        return dsDialog("信任「\(r?.name ?? "")」？", isPresented: Binding(get: { repo.wrappedValue != nil }, set: { if !$0 { repo.wrappedValue = nil } }),
                        message: r.map(trustMessage)) {
            [.cancel("暂不") { if let r { TVBoxStore.shared.setTrust(r.id, .denied) } },
             .primary("信任并启用", disabled: { false }) { if let r { TVBoxStore.shared.setTrust(r.id, .trusted) } }]
        }
    }
}

private func trustMessage(_ r: TVBoxRepo) -> String {
    var counts: [SiteKind: Int] = [:]
    for s in r.config.sites { counts[s.kind, default: 0] += 1 }
    let kinds: [SiteKind] = [.jar, .js, .py]
    let parts = kinds.compactMap { k in counts[k].map { "\(k.badge) \($0) 个" } }
    let what = parts.joined(separator: "、").nonEmptyOr("扩展解析或直播脚本")
    let jar = counts[.jar] == nil ? "" : "JAR 站点由配对的安卓设备代为运行。"
    return "这个配置包含会在你的设备上运行的代码：\(what)。\(jar)请只信任来源可靠的配置。\n\n不信任时这些站点不会加载，CMS、T4 和直播照常使用；之后可以在配置管理里随时更改。"
}
