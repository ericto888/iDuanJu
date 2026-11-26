import SwiftUI

struct LibraryListView: View {
    enum Kind { case favorites, history }
    let kind: Kind
    @ObservedObject private var library = LibraryStore.shared
    @State private var confirmClear = false

    var body: some View {
        let favorites = kind == .favorites ? library.favorites : []
        let history = kind == .history ? library.continueWatching : []
        Group {
            if kind == .favorites {
                ScrollView {
                    if favorites.isEmpty { DSEmptyState("还没有收藏", systemImage: "heart", message: "在详情页或播放页点 ♥，就会出现在这里。").padding(.top, 60) }
                    else { NumberedGrid(items: favorites, numbered: false).padding(.vertical, 8) }
                }
            } else if history.isEmpty {
                ScrollView { DSEmptyState("还没有观看记录", systemImage: "clock").padding(.top, 60) }
            } else {
                // Deleting a record (issue #3): ✕ on every row, swipe left, or long-press anywhere on the row;
                // 清空 in the bar removes all of them after a confirmation. (A List for its native swipe; nothing of its
                // stock look is left.)
                List {
                    ForEach(history) { p in HistoryRow(progress: p) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .dsNavigation(kind == .favorites ? "我的收藏" : "观看历史") {
            if !history.isEmpty {
                DSBarButton(title: "清空") { confirmClear = true }.accessibilityIdentifier("history.clear")
            }
        }
        .dsConfirm("清空全部观看记录？", isPresented: $confirmClear, message: "只删除本机的观看进度，收藏不受影响。", confirm: "清空 \(history.count) 条记录") {
            withAnimation { library.clearHistory() }
        }
    }
}

private struct HistoryRow: View {
    let progress: WatchProgress
    @Environment(\.zoomNS) private var ns

    var body: some View {
        let p = progress
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                CoverView(url: p.series.cover, corner: 10, maxPixelSize: CoverPixels.thumb).frame(width: 64, height: 86).zoomSource(p.series.id, ns)
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.series.title).dsFont(16, .semibold).foregroundStyle(STVTheme.text).lineLimit(1)
                    Text(p.series.source.isLongVideo ? Fmt.resume(p) : "看到第\(p.episodeNumber)集 · \(Fmt.duration(Int(p.seconds)))")
                        .dsFont(13, relativeTo: .footnote).foregroundStyle(STVTheme.secondary)
                    DSProgressBar(value: p.fraction).padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            // Whole row is the hit area, not just the cover / text (long-press used to miss the gaps).
            .contentShape(Rectangle())
            // Hidden link: a NavigationLink directly in a List row adds a disclosure chevron next to the ✕.
            .background { NavigationLink(value: Route.series(p.series)) { EmptyView() }.opacity(0) }
            Button { withAnimation { LibraryStore.shared.removeProgress(p.series) } } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(STVTheme.tertiary)
                    .frame(width: 40, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("删除观看记录")
            .accessibilityIdentifier("history.delete")
        }
        .contentShape(Rectangle())
        .contextMenu { Button("删除观看记录", systemImage: "trash", role: .destructive) { LibraryStore.shared.removeProgress(p.series) } }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { LibraryStore.shared.removeProgress(p.series) } label: { Label("删除", systemImage: "trash") }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 6))
    }
}
