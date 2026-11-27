import SwiftUI

struct LibraryListView: View {
    enum Kind { case favorites, history }
    let kind: Kind
    @ObservedObject private var library = LibraryStore.shared
    @Environment(\.layoutMetrics) private var layout
    @State private var confirmClear = false
    @State private var managingFavorites = false
    @State private var selectedFavIDs: Set<String> = []
    @State private var confirmClearFavorites = false

    var body: some View {
        let favorites = kind == .favorites ? library.favorites : []
        let history = kind == .history ? library.continueWatching : []
        Group {
            if kind == .favorites {
                favoritesBody(favorites)
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
            if kind == .favorites, !favorites.isEmpty {
                DSBarButton(title: managingFavorites ? "完成" : "管理") {
                    withAnimation(DS.select) {
                        managingFavorites.toggle()
                        if !managingFavorites { selectedFavIDs.removeAll() }
                    }
                }
                .accessibilityIdentifier("favorites.manage")
            } else if !history.isEmpty {
                DSBarButton(title: "清空") { confirmClear = true }.accessibilityIdentifier("history.clear")
            }
        }
        .dsConfirm("清空全部观看记录？", isPresented: $confirmClear, message: "只删除本机的观看进度，收藏不受影响。", confirm: "清空 \(history.count) 条记录") {
            withAnimation { library.clearHistory() }
        }
        .dsConfirm("清空全部收藏？", isPresented: $confirmClearFavorites, message: "将移除当前可见的 \(favorites.count) 部收藏，观看记录不受影响。", confirm: "清空 \(favorites.count) 部收藏") {
            withAnimation {
                library.clearFavorites()
                selectedFavIDs.removeAll()
                managingFavorites = false
            }
        }
    }

    @ViewBuilder
    private func favoritesBody(_ favorites: [HGSeries]) -> some View {
        if favorites.isEmpty {
            ScrollView {
                DSEmptyState("还没有收藏", systemImage: "heart", message: "在详情页或播放页点 ♥，就会出现在这里。").padding(.top, 60)
            }
        } else {
            let landscape = favorites.first?.isLandscapeCover ?? false
            let cols = landscape ? layout.wideGridItems(spacing: 10) : layout.posterGridItems(spacing: 10)
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !managingFavorites {
                            Text("长按任意封面可快速删除，或点右上角「管理」批量移除")
                                .dsFont(12, relativeTo: .caption)
                                .foregroundStyle(STVTheme.tertiary)
                                .padding(.horizontal, 16)
                        }
                        LazyVGrid(columns: cols, spacing: 16) {
                            ForEach(favorites) { s in
                                FavoriteManageCell(
                                    series: s,
                                    landscape: landscape,
                                    managing: managingFavorites,
                                    selected: selectedFavIDs.contains(s.id),
                                    onToggleSelect: {
                                        DS.tick()
                                        if selectedFavIDs.contains(s.id) { selectedFavIDs.remove(s.id) }
                                        else { selectedFavIDs.insert(s.id) }
                                    },
                                    onDelete: {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        withAnimation(DS.select) {
                                            selectedFavIDs.remove(s.id)
                                            library.removeFavorite(s)
                                            if library.favorites.isEmpty { managingFavorites = false }
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 8)
                    .padding(.bottom, managingFavorites ? 84 : 16)
                }

                if managingFavorites {
                    favoritesManageBar(favorites)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private func favoritesManageBar(_ favorites: [HGSeries]) -> some View {
        let allSelected = !favorites.isEmpty && selectedFavIDs.count == favorites.count
        return HStack(spacing: 10) {
            Button {
                DS.tick()
                if allSelected { selectedFavIDs.removeAll() }
                else { selectedFavIDs = Set(favorites.map(\.id)) }
            } label: {
                Text(allSelected ? "取消全选" : "全选")
                    .dsFont(14, .semibold)
                    .foregroundStyle(STVTheme.text)
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(STVTheme.glass, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressScale())

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(DS.select) {
                    library.removeFavorites(selectedFavIDs)
                    selectedFavIDs.removeAll()
                    if library.favorites.isEmpty { managingFavorites = false }
                }
            } label: {
                Text(selectedFavIDs.isEmpty ? "删除所选" : "删除所选 (\(selectedFavIDs.count))")
                    .dsFont(14, .semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(selectedFavIDs.isEmpty ? DSTone.danger.opacity(0.35) : DSTone.danger, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressScale())
            .disabled(selectedFavIDs.isEmpty)

            Button { confirmClearFavorites = true } label: {
                Text("清空")
                    .dsFont(14, .semibold)
                    .foregroundStyle(DSTone.danger)
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(DSTone.danger.opacity(0.12), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressScale())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .liquidGlass(corner: 26, tone: .panel)
        .padding(.horizontal, 16).padding(.bottom, 12)
    }
}

/// Poster cell for Favorites with native long-press direct delete & batch management overlay.
struct FavoriteManageCell: View {
    let series: HGSeries
    var landscape: Bool = false
    var managing: Bool = false
    var selected: Bool = false
    var onToggleSelect: () -> Void = {}
    var onDelete: () -> Void

    @Environment(\.zoomNS) private var ns

    var body: some View {
        Group {
            if managing {
                Button(action: onToggleSelect) { cardContent }
                    .buttonStyle(PressScale(scale: 0.97))
            } else {
                NavigationLink(value: Route.series(series)) { cardContent }
                    .buttonStyle(PressScale(scale: 0.97))
                    .contextMenu {
                        NavigationLink(value: Route.play(series, LibraryStore.shared.progress(for: series)?.episodeIndex)) {
                            Label("立即播放", systemImage: "play.fill")
                        }
                        NavigationLink(value: Route.series(series)) {
                            Label("查看详情", systemImage: "info.circle")
                        }
                        Divider()
                        Button("移出收藏", systemImage: "trash", role: .destructive, action: onDelete)
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            if managing {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.black.opacity(0.68), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("删除 \(series.title)")
            }
        }
        .overlay(alignment: .topLeading) {
            if managing {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? STVTheme.accent : .white.opacity(0.85))
                    .background(Circle().fill(selected ? .white : Color.black.opacity(0.42)).padding(2))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(landscape ? 16 / 10 : 3 / 4, contentMode: .fit)
                .overlay { CoverView(url: series.cover, corner: 12, maxPixelSize: CoverPixels.poster) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    if managing && selected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(STVTheme.accent, lineWidth: 2.5)
                    }
                }
                .zoomSource(series.id, ns)
            Text(series.title)
                .dsFont(13, .semibold, relativeTo: .footnote)
                .foregroundStyle(STVTheme.text)
                .lineLimit(1)
            let meta = Fmt.meta(series)
            if !meta.isEmpty {
                Text(meta)
                    .dsFont(11, relativeTo: .caption2)
                    .foregroundStyle(STVTheme.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
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
