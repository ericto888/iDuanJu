import SwiftUI

// MARK: Tabs

/// Source strip: tone chips that keep the selected one centred.
struct TextTabStrip<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var floating = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LiquidGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(items, id: \.self) { item in
                            Button { DS.tick(); withAnimation(DS.select) { selection = item } } label: { Text(label(item)) }
                                .buttonStyle(ToneChipStyle(on: selection == item, floating: floating))
                                .accessibilityAddTraits(selection == item ? .isSelected : [])
                                .id(item)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 4)
                }
            }
            .compatScrollBounceBasedOnSize(axes: .horizontal)
            .compatOnChange(of: selection) { item in withAnimation(DS.select) { proxy.scrollTo(item, anchor: .center) } }
        }
    }
}

struct ChipFlow: View {
    let items: [String]
    var accent: (String) -> String? = { _ in nil }
    /// Non-nil → edit mode: each chip shows ✕ and tapping removes it (最近搜索单条删除).
    var onRemove: ((String) -> Void)? = nil
    let tap: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { t in
                    Button { tap(t) } label: {
                        HStack(spacing: 4) {
                            Text(t).foregroundStyle(STVTheme.text)
                            if let a = accent(t) { Text(a).font(.system(size: 11, weight: .bold)).foregroundStyle(STVTheme.accentWarm) }
                            if onRemove != nil {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(STVTheme.tertiary)
                            }
                        }
                    }
                    .buttonStyle(ToneChipStyle(on: false))
                }
            }.padding(.horizontal, 16)
        }
        .compatScrollBounceBasedOnSize(axes: .horizontal)
    }
}

// MARK: Rank numerals

enum RankStyle {
    static func color(_ r: Int) -> Color {
        switch r { case 1: Color(red: 1, green: 0.27, blue: 0.2); case 2: Color(red: 1, green: 0.55, blue: 0.15); case 3: Color(red: 1, green: 0.78, blue: 0.2); default: .white.opacity(0.85) }
    }
    static func tint(_ r: Int) -> Color {
        switch r {
        case 1: Color(red: 0.80, green: 0.14, blue: 0.22)
        case 2: Color(red: 0.18, green: 0.25, blue: 0.78)
        default: Color(red: 0.88, green: 0.32, blue: 0.18)
        }
    }
}

struct RankNumeral: View {
    let rank: Int
    var size: CGFloat = 17
    var body: some View {
        Text("\(rank)")
            .font(.system(size: size, weight: .black, design: .rounded)).italic()
            .foregroundStyle(rank <= 3 ? RankStyle.color(rank) : STVTheme.tertiary)
            .frame(minWidth: size * 0.9)
    }
}

// MARK: Grid cell with big italic rank

struct NumberedPosterCell: View {
    let series: HGSeries
    let rank: Int?
    @Environment(\.zoomNS) private var ns
    var body: some View {
        NavigationLink(value: Route.series(series)) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(series.isLandscapeCover ? 16/10 : 3/4, contentMode: .fit)
                    .overlay { CoverView(url: series.cover, corner: 0, maxPixelSize: series.isLandscapeCover ? CoverPixels.wide : CoverPixels.poster) }
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false)
                    }
                    .overlay(alignment: .topLeading) {
                        if let rank {
                            Text(String(format: "%02d", rank))
                                .font(.system(size: 26, weight: .black, design: .rounded)).italic()
                                .foregroundStyle(.white)
                                .shadow(color: rank <= 3 ? RankStyle.color(rank) : .black, radius: 0, x: 2, y: 2)
                                .padding(.leading, 5)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if series.isNew {
                            Text("新剧").font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4)).padding(5)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        let m = Fmt.meta(series)
                        if !m.isEmpty {
                            Text(m).font(.caption2).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .zoomSource(series.id, ns)
                Text(series.title).font(.subheadline.weight(.medium)).foregroundStyle(STVTheme.text).lineLimit(series.isLandscapeCover ? 2 : 1)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.97))
    }
}

struct NumberedGrid: View {
    let items: [HGSeries]
    var numbered = true
    var hasMore = false
    var loading = false
    var loadMore: () -> Void = {}
    @Environment(\.layoutMetrics) private var layout
    private var landscape: Bool { items.first?.isLandscapeCover ?? false }
    private var cols: [GridItem] { landscape ? layout.wideGridItems(spacing: 10) : layout.posterGridItems(spacing: 10) }
    var body: some View {
        // Three rows early, so the next page is usually there before the end of the list is.
        let trigger = items.dropLast(max(0, min(items.count - 1, cols.count * 3))).last?.id
        LazyVGrid(columns: cols, spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                NumberedPosterCell(series: s, rank: numbered ? i + 1 : nil)
                    .onAppear { if hasMore, !loading, s.id == trigger || i == items.count - 1 { loadMore() } }
            }
            if loading {
                ForEach(0..<(items.isEmpty ? 9 : cols.count), id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        ShimmerBlock().aspectRatio(landscape ? 16/10 : 3/4, contentMode: .fit)
                        ShimmerBlock(corner: 5).frame(height: 12)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        if !hasMore && !loading && !items.isEmpty {
            Text("没有更多了").font(.caption).foregroundStyle(STVTheme.tertiary).frame(maxWidth: .infinity).padding()
        }
    }
}

// MARK: Search ranking

struct TopRankCard: View {
    let series: HGSeries
    let rank: Int
    @Environment(\.zoomNS) private var ns
    var body: some View {
        NavigationLink(value: Route.series(series)) {
            Color.clear
                .aspectRatio(0.6, contentMode: .fit)
                .overlay { CoverView(url: series.cover, corner: 0, maxPixelSize: CoverPixels.poster) }
                .overlay {
                    // Gradient with its own alpha ramp; masking a gradient per card needed an offscreen pass each.
                    LinearGradient(stops: [.init(color: RankStyle.tint(rank).opacity(0), location: 0.35), .init(color: RankStyle.tint(rank).opacity(0.94), location: 0.72),
                                           .init(color: RankStyle.tint(rank), location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 2) {
                        Text("TOP\(rank)").font(.system(size: 24, weight: .black, design: .rounded))
                        Text(series.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(Fmt.meta(series)).font(.caption2).opacity(0.8).lineLimit(1)
                    }
                    .foregroundStyle(.white).padding(.horizontal, 6).padding(.bottom, 10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .zoomSource(series.id, ns)
        }
        .buttonStyle(PressScale(scale: 0.97))
    }
}

struct CompactRankRow: View {
    @Environment(\.zoomNS) private var ns
    let series: HGSeries
    let rank: Int
    var body: some View {
        NavigationLink(value: Route.series(series)) {
            HStack(spacing: 10) {
                CoverView(url: series.cover, corner: 8, maxPixelSize: CoverPixels.thumb)
                    .frame(width: 46, height: 62)
                    .zoomSource(series.id, ns)
                    .overlay(alignment: .topTrailing) {
                        Text("\(rank)").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(rank <= 3 ? RankStyle.color(rank) : Color(red: 0.8, green: 0.15, blue: 0.25), in: RoundedRectangle(cornerRadius: 4))
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(series.title).font(.subheadline.weight(.medium)).foregroundStyle(STVTheme.text).lineLimit(1)
                    HStack(spacing: 6) {
                        if series.playCount > 0 { Text(Fmt.count(series.playCount)).foregroundStyle(STVTheme.accentWarm) }
                        Text(series.episodeCount > 0 ? "\(series.episodeCount)集" : "短剧").foregroundStyle(STVTheme.secondary)
                    }.font(.caption)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.98))
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        DSSectionHeader(title: title) { trailing }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) { self.title = title; self.trailing = EmptyView() }
}

// MARK: Continue watching

/// Poster strip of 继续观看 (我的).
struct ContinueRow: View {
    @Environment(\.zoomNS) private var ns
    let items: [WatchProgress]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "继续观看") {
                NavigationLink(value: Route.history) { MoreLabel() }.buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items.prefix(10)) { p in
                        NavigationLink(value: Route.series(p.series)) {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverView(url: p.series.cover, corner: 0, maxPixelSize: CoverPixels.poster)
                                    .frame(width: 112, height: 150)
                                    .overlay {
                                        LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false)
                                    }
                                    .overlay(alignment: .bottom) {
                                        VStack(spacing: 5) {
                                            Text(p.resumeLabel).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                            DSProgressBar(value: p.fraction, track: .white.opacity(0.25))
                                        }
                                        .padding(.horizontal, 8).padding(.bottom, 8)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .zoomSource(p.series.id, ns)
                                Text(p.series.title).font(.caption.weight(.medium)).foregroundStyle(STVTheme.text).lineLimit(1).frame(width: 112, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScale(scale: 0.97))
                        .contextMenu { Button("删除观看记录", systemImage: "trash", role: .destructive) { LibraryStore.shared.removeProgress(p.series) } }
                    }
                }.padding(.horizontal, 16)
            }
            // Content narrower than the screen → don't grab horizontal drags (首页横滑翻来源页).
            .compatScrollBounceBasedOnSize(axes: .horizontal)
        }
    }
}
