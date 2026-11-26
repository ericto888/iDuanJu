import SwiftUI
import UIKit

struct EpisodeRange: Hashable {
    let start: Int
    let end: Int
    init(_ start: Int, _ end: Int) { self.start = start; self.end = end }
}

enum EpisodeGroups {
    /// Group size: 30 (≤300 eps), 50 (≤600), 60 (more). Tablet portrait uses 50 per tab so 8–10 col grids fill naturally.
    static func size(for total: Int, groupLimit: Int = 30) -> Int {
        if total <= groupLimit { return max(total, 1) }
        if total <= 300 { return groupLimit }
        if total <= 600 { return max(groupLimit, 50) }
        return 60
    }
    static func ranges(total: Int, groupLimit: Int = 30) -> [EpisodeRange] {
        guard total > 0 else { return [] }
        let g = size(for: total, groupLimit: groupLimit)
        if total <= g { return [EpisodeRange(0, total - 1)] }
        var out: [EpisodeRange] = []
        var i = 0
        while i < total {
            out.append(EpisodeRange(i, min(i + g - 1, total - 1)))
            i += g
        }
        return out
    }
    static func label(_ r: EpisodeRange, episodes: [HGEpisode]) -> String {
        let a = episodes.indices.contains(r.start) ? episodes[r.start].ep : r.start + 1
        let b = episodes.indices.contains(r.end) ? episodes[r.end].ep : r.end + 1
        return a == b ? "\(a)" : "\(a)-\(b)"
    }
    /// Sources that name their episodes ("20240105期", "正片", "番外") need the names; plain "第 12 集" lists read better as numbers.
    static func named(_ episodes: [HGEpisode]) -> Bool {
        episodes.contains { e in
            let t = e.title.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return false }
            let core = t.replacingOccurrences(of: "第", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " 集话期回EePp."))
            return Int(core) != e.ep
        }
    }
}

struct DramaDetailView: View {
    let series: HGSeries
    var seededDetail: HGSeriesDetail? = nil
    @State private var detail: HGSeriesDetail?
    @State private var error: Error?
    @State private var group = 0
    @State private var ascending = true
    /// Selected 线路 (`HGPlayLine.id`).
    @State private var lineID: String?
    /// Episode cells show names instead of numbers (computed once per line).
    @State private var namedEpisodes = false
    @State private var seasons: [HGSeries] = []
    /// Long-video sites: resolved 播放源 list (preloaded so the player starts instantly).
    @State private var sources: [HGStream] = []
    @State private var sourcesError: String?
    @State private var sourcesVerify: VerifyTarget?
    @State private var verifySheet: VerifyTarget?
    @Environment(\.zoomNS) private var ns

    @State private var detailPinned = false
    @State private var actionsOut = false
    @State private var barCompact = false
    @State private var scrollTrack = ScrollTrack()
    @State private var introOpen = false
    @State private var introClamped = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutMetrics) private var layout

    /// Scroll bookkeeping that must not invalidate the page.
    private final class ScrollTrack { var turn: CGFloat = 0 }

    private var pinned: Bool { detailPinned }
    private var title: String { detail?.title ?? series.title }

    private var useTwoPane: Bool { layout.tier == .expanded && layout.isLandscape && detail != nil }
    private var usePortraitEditorial: Bool { !useTwoPane && !layout.isLandscape && layout.tier != .compact && detail != nil }
    private var isTabletLayout: Bool { useTwoPane || usePortraitEditorial }
    private var epGroupLimit: Int { usePortraitEditorial ? 50 : 30 }

    /// Episodes of the selected line (the default line when there is only one).
    private func episodes(_ d: HGSeriesDetail) -> [HGEpisode] {
        guard let id = lineID, let line = d.lines.first(where: { $0.id == id }) else { return d.episodes }
        return line.episodes
    }
    /// Single long videos pick a 播放源; anything with several episodes (短剧, TVBox, 采集站) picks an episode.
    private func showsEpisodes(_ d: HGSeriesDetail) -> Bool { !series.source.isLongVideo || episodes(d).count > 1 }

    /// ui-redesign 12 / 13: artwork hero running under the bars, floating glass back / favourite / share, stats card, actions,
    /// tags, folding intro, 线路 + 选集 before 系列 / 演员; a pinned title once the hero scrolls away and a floating glass
    /// play bar once the main button does.
    var body: some View {
        Group {
            if useTwoPane, let d = detail {
                twoPane(d)
            } else if usePortraitEditorial, let d = detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        portraitEditorialHero(d)
                        detailBody(d, showActions: false)
                    }
                    .padding(.top, 60)
                    .padding(.bottom, 64)
                    .compatScrollContent()
                }
                .compatOnScrolled(threshold: 236) { if detailPinned != $0 { detailPinned = $0 } }
                .scrollIndicators(.hidden)
            } else {
                phone
            }
        }
        .accessibilityIdentifier("screen.detail")
        .ignoresSafeArea(edges: .top)
        .background(STVTheme.bg.ignoresSafeArea())
        .overlay(alignment: .top) { navBar }
        .overlay(alignment: .bottom) { if !isTabletLayout { playBar } }
        .toolbar(.hidden, for: .navigationBar)
        .zoomDestination(series.id, ns)
        .task {
            if let seededDetail { detail = seededDetail; settle() }
            else if detail == nil { await load() }
        }
        .compatOnChange(of: detail?.episodes.count) { settle() }
        .task(id: detail?.seriesId) {
            guard let d = detail else { return }
            if series.source.isTVBox {
                return // lines and episodes come with the detail
            } else if series.source.isLongVideo {
                if d.episodes.count <= 1 { await loadSources(d) }
            } else {
                seasons = await SeasonStore.seasons(for: d, series: series)
            }
        }
    }

    private var phone: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                if let d = detail { detailBody(d) }
                else if let error { ErrorStateView(error: error) { Task { await load() } }.padding(.top, 24) }
                else {
                    VStack(alignment: .leading, spacing: 12) {
                        ShimmerBlock(corner: 16).frame(height: 63)
                        ShimmerBlock(corner: 25).frame(height: 50)
                        ForEach(0..<3, id: \.self) { i in ShimmerBlock(corner: 6).frame(height: 14).frame(maxWidth: i == 2 ? 180 : .infinity) }
                    }.padding(.horizontal, 20).padding(.top, 18)
                }
            }
            .frame(maxWidth: layout.detailMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 110)
            .compatScrollContent()
        }
        .coordinateSpace(name: "detail")
        .compatOnScrolled(threshold: 236) { if detailPinned != $0 { detailPinned = $0 } }
        .compatOnScrollY { y in
            // Direction with hysteresis: the play bar shrinks while reading down and opens again on the way up.
            if y > scrollTrack.turn + 36 { scrollTrack.turn = y; if !barCompact { barCompact = true } }
            else if y < scrollTrack.turn - 36 { scrollTrack.turn = y; if barCompact { barCompact = false } }
        }
        .scrollIndicators(.hidden)
        .compatDefaultScrollAnchor(DebugScroll.anchor)
    }

    private func twoPane(_ d: HGSeriesDetail) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CoverView(url: cover, corner: 20, maxPixelSize: CoverPixels.hero, fallback: series.cover)
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .frame(maxHeight: 420)
                        .modifier(PosterLift(corner: 20))
                    DSStatus(text: series.source.label, tone: .accent)
                    Text(title).dsFont(24, .heavy, relativeTo: .title).foregroundStyle(STVTheme.text)
                    if !heroMeta.isEmpty { Text(heroMeta).dsFont(13, relativeTo: .footnote).foregroundStyle(STVTheme.secondary) }
                    HStack(spacing: 10) {
                        DetailPlayButton(series: series, multi: episodes(d).count > 1, height: 48, enabled: !d.episodes.isEmpty)
                        DetailHeart(series: series, size: 48)
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .frame(width: 340)

            ScrollView { detailBody(d, showActions: false).padding(.bottom, 48) }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 72)
        .padding(.horizontal, 28)
        .frame(maxWidth: 1160)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: nav + play bar

    private var navBar: some View {
        LiquidGlassGroup(spacing: 12) {
            ZStack {
                Text(title).dsFont(17, .semibold, relativeTo: .headline).foregroundStyle(STVTheme.text).lineLimit(1)
                    .padding(.horizontal, actionsOut ? 64 : 112)
                    .opacity(pinned ? 1 : 0).offset(y: pinned ? 0 : 6)
                    .accessibilityHidden(!pinned)
                HStack(spacing: 0) {
                    DSBackButton(tone: overArt ? .overlay : .glass) { dismiss() }
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        // Moves down into the play bar once that is on screen.
                        if !actionsOut { DetailHeart(series: series, size: 46, bare: true, onMedia: overArt, id: "detail.nav.favorite").transition(.opacity) }
                        ShareLink(item: shareText) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .medium))
                                .foregroundStyle(overArt ? .white : STVTheme.text)
                                .frame(width: 46, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(GlassPress())
                        .accessibilityLabel("分享").accessibilityIdentifier("detail.share")
                    }
                    .liquidGlassCapsule(tone: overArt ? .clear : .regular, interactive: true, onMedia: overArt)
                }
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 8)
        .background { LiquidEdgeFade(visible: pinned) }
        .animation(.easeOut(duration: 0.2), value: pinned)
        .animation(DS.panel, value: actionsOut)
    }

    /// Bars sit on the artwork (phone layout, before it scrolls away).
    private var overArt: Bool { !pinned && !isTabletLayout }

    private var shareText: String {
        let page = series.page.flatMap { $0.hasPrefix("http") ? "\n" + $0 : nil } ?? ""
        return "《\(title)》 · \(series.source.label)\(page)"
    }

    /// Sticky glass actions: play capsule + favourite, one glass group, shrinking while the page scrolls down.
    private var playBar: some View {
        ZStack(alignment: .bottom) {
            if let d = detail, !d.episodes.isEmpty, actionsOut {
                LiquidGlassGroup(spacing: 14) {
                    HStack(spacing: 10) {
                        DetailPlayButton(series: series, multi: episodes(d).count > 1, height: 54, expand: !barCompact, id: "detail.playbar")
                        DetailHeart(series: series, size: 54, id: "detail.bar.favorite")
                        if barCompact { Spacer(minLength: 0) }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DS.panel, value: barCompact)
        .animation(DS.panel, value: actionsOut)
    }

    // MARK: hero

    private var cover: String { DetailCover.pick(detail: detail?.cover ?? "", list: series.cover) }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if series.isLandscapeCover {
                    CoverView(url: cover, corner: 0, maxPixelSize: CoverPixels.hero, fallback: series.cover, a11yID: "detail.poster", showPlaceholder: false)
                } else {
                    // `.bd`: the poster's own colours, pre-blurred (a live `.blur` here was redone by the GPU on every scroll frame).
                    CoverBackdrop(url: cover, fallback: series.cover)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 316)
            .liquidBackgroundExtension()
            .modifier(StretchyTop(height: 316))
            .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.34), location: 0), .init(color: .black.opacity(0.06), location: 0.36),
                                           .init(color: STVTheme.bg.opacity(0.74), location: 0.78), .init(color: STVTheme.bg, location: 1)],
                                    startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: 16) {
                if !series.isLandscapeCover {
                    CoverView(url: cover, corner: 14, maxPixelSize: CoverPixels.poster, fallback: series.cover, a11yID: "detail.poster")
                        .frame(width: 116, height: 155)
                        .overlay(alignment: .bottom) {
                            if let e = DS.episodes(series) ?? detail.map({ "全 \(max($0.totalEps, $0.episodes.count)) 集" }) {
                                Text(e).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 14)
                                    .frame(maxWidth: .infinity, alignment: .bottom)
                                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                                    .clipShape(CompatUnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
                            }
                        }
                        .modifier(PosterLift(corner: 14))
                }
                VStack(alignment: .leading, spacing: 0) {
                    DSHeroTag(text: series.source.label)
                    Text(title).dsFont(23, .heavy, relativeTo: .title2).foregroundStyle(STVTheme.text).lineLimit(series.isLandscapeCover ? 3 : 2)
                        .padding(.top, 8)
                        .contextMenu { Button("复制剧名", systemImage: "doc.on.doc") { UIPasteboard.general.string = title } }
                    if !heroMeta.isEmpty { Text(heroMeta).dsFont(13, relativeTo: .footnote).foregroundStyle(STVTheme.secondary).lineLimit(1).padding(.top, 6) }
                }
                .padding(.bottom, 2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.bottom, 2)
        }
        .frame(height: 316)
    }

    private var heroMeta: String {
        let count = detail.map { max($0.totalEps, $0.episodes.count) } ?? 0
        let single = series.source.isLongVideo && count <= 1
        let eps: String? = detail.flatMap { d in
            if !d.episodeLabel.isEmpty { return DS.spaced(d.episodeLabel) }
            if single { return series.duration > 0 ? Fmt.clock(series.duration) : nil }
            return count > 0 ? "全 \(count) 集" : nil
        }
        return [eps, detail?.author].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: body

    @ViewBuilder private func portraitEditorialHero(_ d: HGSeriesDetail) -> some View {
        HStack(alignment: .center, spacing: 22) {
            CoverView(url: cover, corner: 16, maxPixelSize: CoverPixels.wide, fallback: series.cover, a11yID: "detail.poster")
                .frame(width: 176, height: 235)
                .modifier(PosterLift(corner: 16))

            VStack(alignment: .leading, spacing: 10) {
                DSStatus(text: series.source.label, tone: .accent)
                Text(title).dsFont(26, .heavy, relativeTo: .title).foregroundStyle(STVTheme.text).lineLimit(2)
                if !heroMeta.isEmpty { Text(heroMeta).dsFont(14, relativeTo: .subheadline).foregroundStyle(STVTheme.secondary).lineLimit(1) }
                LiquidGlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        DetailPlayButton(series: series, multi: episodes(d).count > 1, height: 48, id: "detail.play", enabled: !d.episodes.isEmpty)
                        DetailHeart(series: series, size: 48, id: "detail.favorite")
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .background {
            CoverBackdrop(url: cover, fallback: series.cover).opacity(0.34)
                .overlay(LinearGradient(stops: [.init(color: STVTheme.surface.opacity(0.20), location: 0), .init(color: STVTheme.surface.opacity(0.76), location: 0.42),
                                               .init(color: STVTheme.surface.opacity(0.92), location: 1)], startPoint: .leading, endPoint: .trailing))
        }
        .background(STVTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(STVTheme.hairline, lineWidth: 1))
        .padding(.horizontal, 20)
    }

    @ViewBuilder private func detailBody(_ d: HGSeriesDetail, showActions: Bool = true) -> some View {
        stats(d).padding(.top, 18)

        if showActions {
            DetailPlayButton(series: series, multi: episodes(d).count > 1, height: 52, id: "detail.play", enabled: !d.episodes.isEmpty)
                .padding(.horizontal, 20).padding(.top, 16)
                .compatOnFrame(in: .named("detail")) { f in let out = f.maxY < 100
                    if actionsOut != out { actionsOut = out }
                }
        }

        if !d.tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(d.tags, id: \.self) { t in
                        Text(t).dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.secondary)
                            .padding(.horizontal, 10).frame(minHeight: 26)
                            .background(Capsule().fill(STVTheme.glass))
                    }
                }.padding(.horizontal, 20)
            }
            .compatScrollBounceBasedOnSize(axes: .horizontal)
            .padding(.top, 16)
        }
        if d.cast.isEmpty && !d.actors.isEmpty {
            let names = d.actors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !names.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("主演").dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.secondary)
                        ForEach(names, id: \.self) { name in
                            NavigationLink(value: Route.searchFor(name)) {
                                Text(name).dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.text).lineLimit(1)
                                    .padding(.horizontal, 10).frame(minHeight: 26)
                                    .background(STVTheme.glass, in: Capsule())
                                    .contentShape(Capsule().inset(by: -9))
                            }
                            .buttonStyle(PressScale())
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .compatScrollBounceBasedOnSize(axes: .horizontal)
                .padding(.top, 12)
            }
        }
        if !d.desc.isEmpty { intro(d.desc).padding(.top, 14) }

        if showsEpisodes(d) {
            if d.lines.count > 1 { lineSection(d).padding(.top, 24) }
            VStack(alignment: .leading, spacing: 0) { episodeSection(d) }.padding(.top, d.lines.count > 1 ? 20 : 24)
        } else {
            if d.lines.count > 1 { lineSection(d).padding(.top, 24) }
            if !series.source.isTVBox { VStack(alignment: .leading, spacing: 0) { sourcesSection }.padding(.top, 24) }
        }

        let shelf = d.relatedSeries.count > 1 ? d.relatedSeries : seasons
        if shelf.count > 1 { relatedShelf(shelf, currentId: d.seriesId).padding(.top, 26) }
        if !d.cast.isEmpty { castRow(d.cast).padding(.top, 24) }
    }

    private func stats(_ d: HGSeriesDetail) -> some View {
        var cells: [(icon: String?, value: String, label: String)] = []
        if d.rating > 0 { cells.append(("star.fill", String(format: "%.1f", d.rating), "观众评分" + (d.ratingCount.isEmpty ? "" : " · " + DS.spaced(d.ratingCount) + "人"))) }
        if d.favoriteCount > 0 { cells.append((nil, DS.count(d.favoriteCount), "收藏")) }
        if !d.hotText.isEmpty { cells.append(("flame.fill", DS.spaced(d.hotText), "全网热度")) }
        // Preserve the spec's three-column density when upstream only supplies one/two metrics.
        // Missing metrics are absent, never fabricated; the card hugs its occupied columns.
        return GeometryReader { geo in
          HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        if let icon = c.icon { Image(systemName: icon).font(.system(size: 13)).foregroundStyle(STVTheme.accentWarm) }
                        Text(c.value).font(.system(size: 17, weight: .bold)).foregroundStyle(STVTheme.text).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(height: 22)
                    Text(c.label).font(.system(size: 11)).foregroundStyle(STVTheme.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) { if i > 0 { STVTheme.hairline.frame(width: 1) } }
            }
        }
          .frame(width: geo.size.width * CGFloat(min(3, cells.count)) / 3, height: 63)
          .dsCard(16)
        }
        .frame(height: cells.isEmpty ? 0 : 63)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.stats")
    }

    private func intro(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(STVTheme.secondary).lineSpacing(5)
            .lineLimit(introOpen ? nil : 3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // Measure the full height once to know whether 展开 is needed.
                Text(text).font(.system(size: 14)).lineSpacing(5).fixedSize(horizontal: false, vertical: true).hidden()
                    .compatOnSize { introClamped = $0.height > 70 }
            }
            .overlay(alignment: .bottomTrailing) {
                if introClamped && !introOpen {
                    Text("展开").font(.system(size: 14, weight: .semibold)).foregroundStyle(STVTheme.accent)
                        .padding(.leading, 36)
                        .background(LinearGradient(stops: [.init(color: STVTheme.bg.opacity(0), location: 0), .init(color: STVTheme.bg, location: 0.42)],
                                                   startPoint: .leading, endPoint: .trailing))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if introClamped { withAnimation(DS.panel) { introOpen.toggle() } } }
            .padding(.horizontal, 20)
            .accessibilityIdentifier("detail.intro")
    }

    // MARK: 线路 + 选集

    private func lineSection(_ d: HGSeriesDetail) -> some View {
        let current = d.lines.contains { $0.id == lineID } ? lineID : d.lines.first?.id
        return VStack(alignment: .leading, spacing: 12) {
            DSSectionHeader(title: "线路", note: "共 \(d.lines.count) 条", inset: 20)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(d.lines) { line in
                            let on = line.id == current
                            Button { pick(line) } label: {
                                CountLabel(title: line.name, count: line.episodes.count)
                            }
                            .buttonStyle(ToneChipStyle(on: on))
                            .accessibilityAddTraits(on ? .isSelected : [])
                            .accessibilityIdentifier("detail.line.\(line.id)")
                            .id(line.id)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .compatScrollBounceBasedOnSize(axes: .horizontal)
                .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.lines")
    }

    private func pick(_ line: HGPlayLine) {
        guard line.id != lineID else { return }
        DS.tick()
        // The player reads the same store, so playback starts on this line.
        PlayLinePrefs.set(line.id, for: series)
        withAnimation(DS.select) { lineID = line.id; namedEpisodes = series.source.isLongVideo && EpisodeGroups.named(line.episodes) }
        selectResumeGroup()
    }

    @ViewBuilder private func episodeSection(_ d: HGSeriesDetail) -> some View {
        let list = episodes(d)
        let ranges = EpisodeGroups.ranges(total: list.count, groupLimit: epGroupLimit)
        let g = ranges.indices.contains(group) ? group : 0
        let range = ranges.isEmpty ? EpisodeRange(0, -1) : ranges[g]
        DSSectionHeader(title: "选集", note: "共 \(max(d.lines.count > 1 ? 0 : d.totalEps, list.count)) 集", inset: 20) {
            if list.count > 1 { DSOrderToggle(ascending: $ascending, id: "detail.order") }
        }
        if ranges.count > 1 {
            let order = ascending ? Array(ranges.indices) : Array(ranges.indices.reversed())
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(order, id: \.self) { i in
                            Button { DS.tick(); withAnimation(DS.select) { group = i } } label: { Text(EpisodeGroups.label(ranges[i], episodes: list)) }
                                .buttonStyle(ToneChipStyle(on: i == g, neutral: true, small: true))
                                .accessibilityAddTraits(i == g ? .isSelected : [])
                                .accessibilityIdentifier("detail.range.\(i)")
                                .id(i)
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 4)
                }
                .compatScrollBounceBasedOnSize(axes: .horizontal)
                .onAppear { proxy.scrollTo(g, anchor: .center) }
            }
            .padding(.top, 8)
        }
        if range.end >= range.start {
            DetailEpisodeGrid(series: series, episodes: list, range: range, ascending: ascending, named: namedEpisodes,
                              columns: namedEpisodes ? max(2, layout.episodeCols / 2) : layout.episodeCols)
                .padding(.horizontal, 20).padding(.top, 12)
                .id("\(lineID ?? "")-\(g)-\(ascending)")
                .transition(.opacity)
        }
    }

    private func castRow(_ cast: [HGCelebrity]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSectionHeader(title: "演员", inset: 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { c in
                        let cell = VStack(spacing: 0) {
                            Group {
                                if c.avatar.isEmpty {
                                    Text(String(c.name.prefix(1)))
                                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                                        .frame(width: 56, height: 56)
                                        .background(LinearGradient(colors: [STVTheme.accent, STVTheme.accentWarm], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                                } else { ActorAvatar(url: c.avatar, size: 56) }
                            }
                            Text(c.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(STVTheme.text).lineLimit(1).padding(.top, 6)
                            if !c.role.isEmpty { Text(c.role).font(.system(size: 11)).foregroundStyle(STVTheme.secondary).lineLimit(1) }
                        }.frame(width: 64)
                        if !c.id.isEmpty {
                            NavigationLink(value: Route.actor(c)) { cell }.buttonStyle(PressScale())
                        } else if !c.name.isEmpty {
                            NavigationLink(value: Route.searchFor(c.name)) { cell }.buttonStyle(PressScale())
                        } else {
                            cell
                        }
                    }
                }.padding(.horizontal, 20)
            }
        }
    }

    /// 播放源 — same look as the 选集 buttons, 3 columns, small status line under the name.
    @ViewBuilder private var sourcesSection: some View {
        DSSectionHeader(title: series.source.streamSectionTitle, inset: 20).padding(.bottom, 12)
        if sources.isEmpty {
            if let sourcesError {
                Text(sourcesError).dsFont(13, relativeTo: .footnote).foregroundStyle(STVTheme.secondary).padding(.horizontal, 20)
                if let t = sourcesVerify {
                    Button { verifySheet = t } label: { PillButtonLabel(title: "去验证", small: true) }.buttonStyle(PressScale())
                        .padding(.horizontal, 20).padding(.top, 10)
                        .sheet(item: $verifySheet) { t in SiteVerifySheet(target: t, onDone: retrySources) }
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in ShimmerBlock().frame(height: 52) }
                }.padding(.horizontal, 20)
            }
        } else {
            let current = SitePrefs.preferredStream[series.id] ?? sources.first?.id
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(sources) { s in
                    let on = s.id == current
                    NavigationLink(value: Route.play(series, 0)) {
                        VStack(spacing: 3) {
                            Text(s.quality ?? "默认").dsFont(15, .semibold, relativeTo: .subheadline).lineLimit(1).minimumScaleFactor(0.8)
                            Text(s.kind == .hls || s.kind == .hlsAES ? "HLS" : "MP4").font(.caption2)
                                .foregroundStyle(on ? STVTheme.accent.opacity(0.8) : STVTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(on ? STVTheme.accentSoft : STVTheme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay { if on { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(STVTheme.accentLine, lineWidth: 1) } }
                        .foregroundStyle(on ? STVTheme.accent : STVTheme.text)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale(scale: 0.97))
                    .simultaneousGesture(TapGesture().onEnded { SitePrefs.preferredStream[series.id] = s.id })
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func retrySources() {
        guard let d = detail else { return }
        sourcesError = nil
        sourcesVerify = nil
        Task { await loadSources(d) }
    }

    private func loadSources(_ d: HGSeriesDetail) async {
        guard let ep = d.episodes.first else { return }
        do {
            let r = try await Catalog.resolve(series, ep)
            sources = r.streams
            sourcesError = r.streams.isEmpty ? (r.err ?? "暂无可用播放源") : nil
            sourcesVerify = nil
        } catch { sourcesError = error.localizedDescription; sourcesVerify = error.verifyTarget }
    }

    /// `系列` shelf: 104 pt posters, the current season ringed in accent with a 当前 badge.
    @ViewBuilder private func relatedShelf(_ items: [HGSeries], currentId: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSectionHeader(title: "系列", note: "共 \(items.count) 季", inset: 20) {
                NavigationLink(value: Route.searchFor(SeasonParser.parse(detail?.title ?? series.title).base)) {
                    MoreLabel(title: "搜全系列", icon: "magnifyingglass")
                }
                .accessibilityIdentifier("detail.series.search")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { s in
                        let on = s.seriesId == currentId
                        if on { relatedPoster(s, current: true, label: SeasonStore.label(s, in: items)) }
                        else {
                            NavigationLink(value: Route.series(s)) { relatedPoster(s, current: false, label: SeasonStore.label(s, in: items)) }
                                .buttonStyle(PressScale(scale: 0.97))
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 4)
            }
        }
    }

    private func relatedPoster(_ s: HGSeries, current: Bool, label: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverView(url: s.cover, corner: 12, maxPixelSize: CoverPixels.poster)
                .frame(width: 104, height: 139)
                .zoomSource(s.id, ns)
                .overlay(alignment: .topLeading) {
                    if current {
                        Text("当前").font(.system(size: 10.5, weight: .bold)).foregroundStyle(STVTheme.onAccent)
                            .padding(.horizontal, 6).frame(height: 18)
                            .background(STVTheme.accent, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .padding(6)
                    }
                }
                .background {
                    if current {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(STVTheme.accent, lineWidth: 2).padding(-4)
                    }
                }
            Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(STVTheme.text).lineLimit(1).padding(.top, 8)
            Text([label, s.episodeCount > 0 ? "\(s.episodeCount) 集" : nil].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(STVTheme.secondary).lineLimit(1).padding(.top, 2)
        }
        .frame(width: 104, alignment: .leading)
    }

    /// Once per loaded detail: remembered line, episode naming, resume group.
    private func settle() {
        guard let d = detail else { return }
        if lineID == nil, let id = PlayLinePrefs.preferred(series), d.lines.contains(where: { $0.id == id }) { lineID = id }
        namedEpisodes = series.source.isLongVideo && EpisodeGroups.named(episodes(d))
        selectResumeGroup()
    }

    private func selectResumeGroup() {
        guard let d = detail, let r = LibraryStore.shared.progress(for: series) else { return }
        let ranges = EpisodeGroups.ranges(total: episodes(d).count, groupLimit: epGroupLimit)
        if let i = ranges.firstIndex(where: { r.episodeIndex >= $0.start && r.episodeIndex <= $0.end }) {
            group = i
        }
    }

    private func load() async {
        do {
            let d = try await Catalog.detail(series)
            detail = d
            error = nil
            settle()
            if series.source == .hongguo {
                // Warm the play URL of the episode a tap would open (resume point, else episode 1).
                let i = LibraryStore.shared.progress(for: series)?.episodeIndex ?? 0
                if d.episodes.indices.contains(i) { HongguoClient.shared.prefetch(vids: [d.episodes[i].vid]) }
                // Second pass: cast / tags / rating from the official site.
                if let e = await Catalog.enriched(series, d), detail?.seriesId == e.seriesId { detail = e }
            }
        } catch { self.error = error }
    }
}



// MARK: - Leaves observing the library
// Playback writes progress every few seconds; only these re-render then, not the whole page under the player.

/// Primary action: tinted Liquid Glass capsule, "开始播放" / "继续第 N 集" / "继续 12:34".
private struct DetailPlayButton: View {
    let series: HGSeries
    /// Several episodes: resume by episode, not by time.
    let multi: Bool
    var height: CGFloat = 50
    var expand = true
    var id: String? = nil
    var enabled = true
    @ObservedObject private var library = LibraryStore.shared

    private var title: String {
        guard let r = library.progress(for: series) else { return "开始播放" }
        return series.source.isLongVideo && !multi ? "继续 " + Fmt.clock(Int(r.seconds)) : "继续第 \(r.episodeNumber) 集"
    }

    var body: some View {
        NavigationLink(value: Route.play(series, library.progress(for: series)?.episodeIndex)) {
            PillButtonLabel(title: title, icon: "play.fill", tone: .accent, height: height, expand: expand, glass: true)
        }
        .buttonStyle(GlassPress())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityIdentifier(id ?? "detail.play")
    }
}

private struct DetailHeart: View {
    let series: HGSeries
    var size: CGFloat = 50
    /// No own glass: part of a shared glass capsule.
    var bare = false
    var onMedia = false
    var id = "detail.favorite"
    @ObservedObject private var library = LibraryStore.shared

    var body: some View {
        let on = library.isFavorite(series)
        Button { DS.tick(); withAnimation(DS.press) { library.toggleFavorite(series) } } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .font(.system(size: bare ? 18 : 20, weight: .medium))
                .foregroundStyle(on ? (onMedia ? Color(red: 1, green: 0.38, blue: 0.42) : STVTheme.accent) : (onMedia ? .white : STVTheme.text))
                .compatSymbolReplace()
                .frame(width: size, height: bare ? 44 : size)
                .modifier(Ground(bare: bare))
                .contentShape(Rectangle())
        }
        .buttonStyle(GlassPress())
        .accessibilityLabel(on ? "取消收藏" : "收藏")
        .accessibilityIdentifier(id)
    }

    private struct Ground: ViewModifier {
        let bare: Bool
        func body(content: Content) -> some View {
            if bare { content } else { content.liquidGlass(Circle(), interactive: true) }
        }
    }
}

/// 选集 cells. Inputs are plain values, so a progress write that does not move the resume episode re-renders nothing.
private struct DetailEpisodeGrid: View {
    let series: HGSeries
    let episodes: [HGEpisode]
    let range: EpisodeRange
    let ascending: Bool
    let named: Bool
    let columns: Int
    @ObservedObject private var library = LibraryStore.shared
    var body: some View {
        EpisodeCells(series: series, episodes: episodes, range: range, ascending: ascending, named: named, columns: columns,
                     resume: library.progress(for: series)?.episodeIndex)
    }

    private struct EpisodeCells: View {
        let series: HGSeries
        let episodes: [HGEpisode]
        let range: EpisodeRange
        let ascending: Bool
        let named: Bool
        let columns: Int
        let resume: Int?
        var body: some View {
            let order = ascending ? Array(range.start...range.end) : Array((range.start...range.end).reversed())
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(order, id: \.self) { i in
                    if episodes.indices.contains(i) { cell(i, episodes[i]) }
                }
            }
        }

        private func cell(_ i: Int, _ e: HGEpisode) -> some View {
            let on = resume == i
            return NavigationLink(value: Route.play(series, i)) {
                Text(named && !e.title.isEmpty ? e.title : "\(e.ep)")
                    .dsFont(named ? 13 : 15, .semibold, relativeTo: .subheadline)
                    .lineLimit(named ? 2 : 1).minimumScaleFactor(0.8).multilineTextAlignment(.center)
                    .foregroundStyle(on ? STVTheme.accent : STVTheme.text)
                    .padding(.horizontal, named ? 8 : 2)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(on ? STVTheme.accentSoft : STVTheme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay { if on { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(STVTheme.accentLine, lineWidth: 1) } }
                    .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(PressScale(scale: 0.94))
            .accessibilityLabel(named && !e.title.isEmpty ? e.title : "第 \(e.ep) 集")
            .accessibilityValue(on ? "上次看到" : "")
        }
    }
}

/// Poster shadow from a plain shape (the cover itself is never flattened for it).
private struct PosterLift: ViewModifier {
    let corner: CGFloat
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.black.shadow(.drop(color: .black.opacity(0.36), radius: 15, y: 12)))
                .padding(1)
        }
    }
}

/// Artwork grows with the pull-down instead of leaving a gap above it.
private struct StretchyTop: ViewModifier {
    let height: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.visualEffect { c, p in
                let pull = max(0, p.frame(in: .named("detail")).minY)
                return c.scaleEffect(1 + pull / height, anchor: .bottom)
            }
        } else {
            content
        }
    }
}

/// Simulator screenshot host for the related-seasons shelf (`STV_DETAIL_SHOT=1`).
/// Set `STV_LIVE_SERIES=<seriesId>` to load a real franchise instead of mock data.
struct DetailRelatedShotHost: View {
    @State private var series = HGSeries(
        seriesId: "7000001", title: "霸总的秘密助理",
        cover: "https://picsum.photos/seed/stv1/600/900", episodeCount: 12)
    @State private var seed: HGSeriesDetail?
    @State private var loading = true
    var body: some View {
        NavigationStack {
            Group {
                if let seed {
                    DramaDetailView(series: series, seededDetail: seed)
                        .id(seed.seriesId + "-\(seed.relatedSeries.count)")
                } else if loading {
                    DSLoading(tint: .white).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DramaDetailView(series: series, seededDetail: .previewDetail)
                }
            }
        }
        .preferredColorScheme(.dark)
        .background(STVTheme.bg)
        .task {
            let live = ProcessInfo.processInfo.environment["STV_LIVE_SERIES"] ?? ""
            if HongguoClient.looksSID(live), let d = try? await HongguoClient.shared.detail(seriesId: live) {
                series = HGSeries(seriesId: d.seriesId, title: d.title, cover: d.cover, episodeCount: max(d.totalEps, d.episodes.count))
                seed = d
            } else {
                seed = .previewDetail
            }
            loading = false
        }
    }
}


/// One-shot live probe: franchise landing for a known multi-season stick_id.
struct ResolveProbeHost: View {
    @State private var lines: [String] = ["probing…"]
    private var vid: String {
        let e = ProcessInfo.processInfo.environment["STV_PROBE_VID"] ?? ""
        return e.isEmpty ? "7683440834066271256" : e
    }
    var body: some View {
        ScrollView { Text(lines.joined(separator: "\n")).font(.system(.footnote, design: .monospaced)).padding() }
            .task { await run() }
    }
    private func run() async {
        var out: [String] = []
        let d = HGPlayerDevice.current()
        out.append("player device src=\(d.source ?? "?") did=\(d.deviceId) (len=\(d.deviceId.count))")
        do {
            let r = try await HongguoClient.shared.resolve(vid: vid)
            out.append("OK streams=\(r.streams.count) err=\(r.err ?? "nil") duration=\(r.duration.map(String.init(describing:)) ?? "nil")")
            NSLog("[HG] probe resolve OK streams=%d", r.streams.count)
        } catch {
            out.append("FAIL \(error.localizedDescription)")
            NSLog("[HG] probe resolve FAIL %@", error.localizedDescription)
        }
        lines = out
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("resolve-probe.txt")
        try? out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        NSLog("[HG] probe wrote %@", url.path)
    }
}

struct RelatedProbeHost: View {
    @State private var text = "probing…"
    var body: some View {
        ScrollView {
            Text(text).font(.system(.caption, design: .monospaced)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .background(Color.black)
        .task { await run() }
    }
    private func run() async {
        let sid = "7661844828728085528" // 被贬北凉… S1 from gateway tests
        var lines: [String] = ["stick_ids=" + sid]
        do {
            let items = try await HongguoClient.shared.seriesLanding(stickIds: sid)
            lines.append("landing count=\(items.count)")
            for s in items.prefix(20) {
                lines.append("\(s.seriesId) | \(s.title) | eps=\(s.episodeCount)")
            }
            let d = try await HongguoClient.shared.detail(seriesId: sid)
            lines.append("detail related=\(d.relatedSeries.count) title=\(d.title)")
            for s in d.relatedSeries.prefix(20) {
                lines.append("rel \(s.seriesId) | \(s.title)")
            }
            // Dump raw relate keys from a fresh detail post is inside client; summarize here.
        } catch {
            lines.append("ERR \(error)")
        }
        text = lines.joined(separator: "\n")
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("related-probe.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        lines.append("wrote \(url.path)")
        text = lines.joined(separator: "\n")
    }
}
