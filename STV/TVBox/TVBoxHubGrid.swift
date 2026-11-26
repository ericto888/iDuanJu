import SwiftUI

/// Poster wall; landscape sites get 16:9 cards. Header, cells and footer are all lazy; only new cells are built on an append.
struct VodGrid<Header: View>: View {
    let cells: [VodCell]
    let loading: Bool
    let error: String?
    /// Shown when there is nothing.
    let empty: String
    /// Site names printed on the posters of an aggregated search.
    var sites: [String: String] = [:]
    let hub: TVBoxHubModel
    var more: () -> Void = {}
    var retry: (() -> Void)? = nil
    @ViewBuilder let header: Header
    @Environment(\.layoutMetrics) private var layout
    @Environment(\.keptPageActive) private var active
    @State private var screen = Screen()

    /// What is on screen; bookkeeping that must not invalidate the page.
    private final class Screen {
        var cells = Set<String>()
        var tail = Set<String>()
        var footer = false
        var active = true
        var nearEnd: Bool { footer || !cells.isDisjoint(with: tail) }
    }

    var body: some View {
        let landscape = cells.first?.item.landscape ?? false
        let cols = landscape ? layout.wideGridItems(spacing: 10) : layout.posterGridItems(spacing: 10)
        // Three rows early, so the next page is usually there before the end of the list is.
        let tail = Set(cells.suffix(cols.count * 3).map(\.id))
        let _ = (screen.tail = tail, screen.active = active)
        ScrollView {
            LazyVGrid(columns: cols, spacing: 16) {
                Section {
                    ForEach(cells) { c in
                        VodCellView(item: c.item, landscape: landscape, site: sites[c.item.uid] ?? "", hub: hub)
                            .onAppear { screen.cells.insert(c.id); if screen.tail.contains(c.id) { more() } }
                            .onDisappear { screen.cells.remove(c.id) }
                    }
                    if loading && cells.isEmpty { skeleton(cols.count * 3, landscape) }
                } header: { header } footer: { footer }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        #if DEBUG
        .compatDefaultScrollAnchor(DebugScroll.anchor == .top ? nil : DebugScroll.anchor)
        #endif
        // The end may have come into view while something else (a refresh behind the cached page) was loading.
        .compatOnChange(of: [loading ? 1 : 0, cells.count, active ? 1 : 0]) { if screen.active && screen.nearEnd { more() } }
    }

    private var footer: some View {
        Group {
            if let error {
                if cells.isEmpty {
                    DSEmptyState("加载失败", systemImage: "wifi.exclamationmark", message: error, actionTitle: retry == nil ? nil : "重试", action: retry)
                } else {
                    VStack(spacing: 10) {
                        Text(error).dsFont(13, relativeTo: .footnote).foregroundStyle(STVTheme.secondary).multilineTextAlignment(.center)
                        if let retry { Button(action: retry) { MiniButtonLabel(title: "重试") }.buttonStyle(PressScale()) }
                    }
                    .padding(.vertical, 12)
                }
            } else if loading {
                if !cells.isEmpty { DSSpinner().padding(.vertical, 12) }
            } else if cells.isEmpty {
                DSEmptyState(empty, systemImage: "rectangle.stack")
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { screen.footer = true; more() }
        .onDisappear { screen.footer = false }
    }

    private func skeleton(_ n: Int, _ landscape: Bool) -> some View {
        ForEach(0..<n, id: \.self) { _ in
            VStack(alignment: .leading, spacing: 7) {
                ShimmerBlock().aspectRatio(landscape ? 16 / 9 : 3 / 4, contentMode: .fit)
                ShimmerBlock(corner: 5).frame(height: 12).frame(maxWidth: 80)
            }
        }
    }
}

/// Opens the detail page, a folder, or runs an `action`.
private struct VodCellView: View {
    let item: VodItem
    let landscape: Bool
    let site: String
    let hub: TVBoxHubModel
    @Environment(\.zoomNS) private var ns
    @Environment(\.keptPageActive) private var active

    var body: some View {
        if item.folder || !item.action.isEmpty {
            Button { hub.open(item) } label: { face("") }
                .buttonStyle(PressScale(scale: 0.97))
                .accessibilityIdentifier(item.folder ? "tvbox.folder" : "tvbox.action")
        } else {
            let s = item.series
            NavigationLink(value: Route.series(s)) { face(s.id) }
                .buttonStyle(PressScale(scale: 0.97))
                .accessibilityIdentifier("tvbox.card")
        }
    }

    private func face(_ zoom: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            art
                // A page that is only kept in memory may show the same title: one zoom source per id.
                .zoomSource(active ? zoom : "kept." + zoom, zoom.isEmpty ? nil : ns)
            Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(STVTheme.text).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var plain: Bool { item.folder && item.cover.isEmpty }

    private var art: some View {
        Color.clear
            .aspectRatio(landscape ? 16 / 9 : 3 / 4, contentMode: .fit)
            .overlay {
                if plain { STVTheme.glass.overlay { IconWell(systemName: "folder.fill", size: 44) } }
                else { CoverView(url: item.cover, corner: 0, maxPixelSize: landscape ? CoverPixels.wide : CoverPixels.poster) }
            }
            .overlay {
                if !plain {
                    LinearGradient(stops: [.init(color: .clear, location: 0.46), .init(color: .black.opacity(0.62), location: 1)],
                                   startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) { if !site.isEmpty { tag(site) } }
            .overlay(alignment: .topTrailing) { if item.folder && !plain { tag("文件夹") } }
            .overlay(alignment: .bottomTrailing) {
                if !item.remark.isEmpty {
                    Text(remark).font(.system(size: 11)).foregroundStyle(plain ? STVTheme.secondary : .white.opacity(0.92)).lineLimit(1)
                        .padding(.leading, 8).padding(.trailing, 8).padding(.bottom, 7)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var remark: String { item.remark.contains("更新至") || item.remark.hasPrefix("全") ? DS.spaced(item.remark) : item.remark }

    private func tag(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal, 6).frame(height: 18)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            .padding(6)
    }
}

/// 继续观看 of TVBox titles, straight into the player. Observes the library on its own: playback writes there.
struct TVBoxContinueRow: View {
    @ObservedObject private var library = LibraryStore.shared

    var body: some View {
        let list = library.continueWatching.lazy.filter { p in p.series.source.tvboxUID.flatMap { TVBoxStore.site($0) } != nil }.prefix(12)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                DSSectionHeader(title: "继续观看", inset: 0)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(Array(list)) { p in card(p) }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 86)
                .compatScrollBounceBasedOnSize(axes: .horizontal)
                .padding(.horizontal, -16)
            }
            .padding(.bottom, 6)
        }
    }

    private func card(_ p: WatchProgress) -> some View {
        NavigationLink(value: Route.play(p.series, p.episodeIndex)) {
            HStack(spacing: 10) {
                CoverView(url: p.series.cover, corner: 9, maxPixelSize: CoverPixels.thumb).frame(width: 48, height: 64)
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.series.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(STVTheme.text).lineLimit(1)
                    Text(Fmt.resume(p)).font(.system(size: 12)).foregroundStyle(STVTheme.secondary).lineLimit(1).padding(.top, 2)
                    DSProgressBar(value: p.fraction).padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(STVTheme.accent).padding(.trailing, 4)
            }
            .padding(10)
            .frame(width: 232, height: 84)
            .dsCard(18)
        }
        .buttonStyle(PressScale(scale: 0.98))
        .contextMenu { Button("删除观看记录", systemImage: "trash", role: .destructive) { LibraryStore.shared.removeProgress(p.series) } }
        .accessibilityLabel("继续播放 \(p.series.title)")
        .accessibilityIdentifier("tvbox.continue")
    }
}
