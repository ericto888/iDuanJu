import SwiftUI

/// Unified STVTheme novel rankings: compact source header, 2-tier horizontal board/category tabs (no cramped rail),
/// 0-card Top 3 visual podium + full-width open hairline list.
struct NovelExploreView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("novel.rank.source") private var sourceID = ""
    @State private var categories: [LegadoClient.ExploreCategory] = []
    @State private var group = ""
    @State private var categoryID = ""
    @State private var items: [LegadoSearchItem] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var busy = false
    @State private var error: String?
    @State private var managing = false
    @State private var choosingSource = false
    @State private var generation = UUID()
    @State private var controlHeight: CGFloat = 0
    private let accent = STVTheme.accent
    @ObservedObject private var sourceStore = LegadoSourceStore.shared
    private var sources: [LegadoSource] { sourceStore.sources.filter { $0.isOn && $0.supported && ($0.isRSS || !($0.exploreUrl ?? "").isEmpty) } }
    private var groups: [String] { categories.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } } }
    private var groupCategories: [LegadoClient.ExploreCategory] { categories.filter { $0.group == group && !$0.isControl } }
    private var currentSourceName: String { sources.first(where: { $0.id == sourceID })?.bookSourceName ?? "选择书源" }

    @State private var searching = false
    @Namespace private var catUnderlineNS
    private let podiumCols = Array(repeating: GridItem(.flexible(), spacing: 11, alignment: .top), count: 3)

    var body: some View {
        let sources = self.sources
        NavigationStack {
            Group {
                if sources.isEmpty {
                    ScrollView {
                        DSEmptyState("先添加书源", systemImage: "books.vertical", message: "发现页显示书源实际提供的分类与榜单。", actionTitle: "导入 / 管理书源") { managing = true }
                            .padding(.top, 80)
                    }
                } else {
                    results
                }
            }
            .liquidTopBar { header(sources) }
            .dsAmbient(cool: true)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: LegadoSearchItem.self) { NovelWebDetailView(items: [$0]) }
            .fullScreenCover(isPresented: $managing) { NovelSourcesView() }
            .fullScreenCover(isPresented: $searching) { NovelSearchView() }
            .sheet(isPresented: $choosingSource) { sourceSheet }
            .task(id: sources.map(\.id)) { if !sources.contains(where: { $0.id == sourceID }) { sourceID = sources.first?.id ?? "" } }
            .task(id: sourceID) { await refreshCategories() }
            .tint(accent)
        }
    }

    /// Floating header: glass actions, board / category tabs, the source's own filters.
    private func header(_ sources: [LegadoSource]) -> some View {
        VStack(spacing: 0) {
            LiquidGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    DSBackButton { dismiss() }
                    Text("小说榜单").dsFont(20, .heavy, relativeTo: .title3).foregroundStyle(STVTheme.text).lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 4)
                    if !sources.isEmpty {
                        Button { choosingSource = true } label: {
                            CapsuleLabel(title: currentSourceName, trailingIcon: "chevron.down")
                        }
                        .buttonStyle(GlassPress())
                        .accessibilityIdentifier("novel.rank.source")
                    }
                    RoundIconButton(systemName: "magnifyingglass", size: 44) { searching = true }
                        .accessibilityLabel("搜书")
                        .accessibilityIdentifier("novel.rank.search")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2).padding(.bottom, 6)
            if !sources.isEmpty {
                if groups.count > 1 {
                    groupBar.padding(.top, 4)
                    if !groupCategories.isEmpty { categoryChipsBar.padding(.top, 6) }
                } else if !groupCategories.isEmpty {
                    singleGroupCategoryTabs.padding(.top, 4)
                }
                if categories.contains(where: { $0.group == group && $0.isControl }) { sourceControls.padding(.top, 4) }
            }
        }
        .padding(.bottom, 6)
    }

    private var groupBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            UnderlineTabs(items: groups, selection: Binding(get: { group }, set: { title in
                guard title != group, !busy else { return }
                group = title
                categoryID = categories.first { $0.group == title && !$0.isControl && !$0.url.isEmpty }?.id ?? ""
                Task { await resetAndLoad() }
            }), label: { $0 }, small: true, idPrefix: "novel.rank.group")
            .padding(.horizontal, 18)
        }
        .compatScrollBounceBasedOnSize(axes: .horizontal)
        .mask(FadeMask())
    }

    private var categoryChipsBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(groupCategories) { cat in
                        let on = cat.id == categoryID
                        Button { DS.tick(); withAnimation(DS.select) { select(cat) } } label: { Text(cat.title) }
                            .buttonStyle(ToneChipStyle(on: on, small: true))
                            .disabled(busy)
                            .id(cat.id)
                            .accessibilityIdentifier("novel.rank.category.\(cat.title)")
                            .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.leading, 16).padding(.trailing, 24)
                .padding(.vertical, 4)
            }
            .compatScrollBounceBasedOnSize(axes: .horizontal)
            .mask(FadeMask())
            .compatOnChange(of: categoryID) { id in withAnimation(DS.select) { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private var singleGroupCategoryTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .lastTextBaseline, spacing: 22) {
                    ForEach(groupCategories) { cat in
                        let on = cat.id == categoryID
                        Button { withAnimation(DS.select) { select(cat) } } label: {
                            UnderlineTabLabel(title: cat.title, on: on, small: true, ns: catUnderlineNS)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .id(cat.id)
                        .accessibilityIdentifier("novel.rank.category.\(cat.title)")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .frame(height: 34)
                .padding(.horizontal, 18)
            }
            .compatScrollBounceBasedOnSize(axes: .horizontal)
            .mask(FadeMask())
            .compatOnChange(of: categoryID) { id in withAnimation(DS.select) { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if items.count >= 3 {
                    podiumView(Array(items.prefix(3)))
                    Hairline().padding(.horizontal, 16)
                    ForEach(Array(items.dropFirst(3).enumerated()), id: \.element.id) { offset, item in
                        let index = offset + 3
                        NavigationLink(value: item) { bookRow(item, rank: index + 1) }
                            .buttonStyle(PressScale(scale: 0.985))
                            .overlay(alignment: .top) {
                                if offset > 0 { Hairline().padding(.leading, 52).padding(.trailing, 16) }
                            }
                            .accessibilityIdentifier("novel.rank.book.\(index)")
                            .onAppear { if index == items.count - 1, hasMore, !busy, error == nil { Task { await load(generation) } } }
                    }
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        NavigationLink(value: item) { bookRow(item, rank: index + 1) }
                            .buttonStyle(PressScale(scale: 0.985))
                            .overlay(alignment: .top) {
                                if index > 0 { Hairline().padding(.leading, 52).padding(.trailing, 16) }
                            }
                            .accessibilityIdentifier("novel.rank.book.\(index)")
                            .onAppear { if index == items.count - 1, hasMore, !busy, error == nil { Task { await load(generation) } } }
                    }
                }

                if busy { DSLoading() }
                else if let error {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("这个栏目暂时不可用", systemImage: "wifi.exclamationmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(STVTheme.text)
                        Text(error).font(.system(size: 12)).foregroundStyle(STVTheme.secondary).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button { Task { await load(generation) } } label: { MiniButtonLabel(title: "重试") }
                            Button { choosingSource = true } label: { MiniButtonLabel(title: "换个书源") }
                        }
                        .buttonStyle(PressScale())
                    }.padding(16)
                } else if items.isEmpty {
                    Text(categoryID.isEmpty ? "选择上方分类，或切换其他书源" : "书源没有返回书籍，请尝试其他分类")
                        .font(.system(size: 13)).foregroundStyle(STVTheme.secondary)
                        .frame(maxWidth: .infinity).padding(32)
                } else if !hasMore {
                    Text("已显示全部").font(.system(size: 12)).foregroundStyle(STVTheme.tertiary).frame(maxWidth: .infinity).padding(20)
                }
            }
            .padding(.bottom, 32)
        }
        .id(categoryID)
        .transition(.opacity)
    }

    private func podiumView(_ topThree: [LegadoSearchItem]) -> some View {
        LazyVGrid(columns: podiumCols, spacing: 12) {
            ForEach(Array(topThree.enumerated()), id: \.element.id) { index, item in
                let firstTag = item.kind.components(separatedBy: CharacterSet(charactersIn: "·/,，|"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty } ?? ""
                let sub = [item.author, firstTag].filter { !$0.isEmpty }.joined(separator: " · ")
                NavigationLink(value: item) {
                    VStack(alignment: .leading, spacing: 0) {
                        WebCover(url: item.cover, title: item.name, author: item.author, corner: 9, rank: index + 1)
                            .aspectRatio(0.71, contentMode: .fit)
                        Text(item.name)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(STVTheme.text)
                            .lineLimit(1)
                            .padding(.top, 7)
                        if !sub.isEmpty {
                            Text(sub)
                                .font(.system(size: 11.5))
                                .foregroundStyle(STVTheme.secondary)
                                .lineLimit(1)
                                .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScale(scale: 0.97))
                .accessibilityIdentifier("novel.rank.book.\(index)")
                .onAppear { if index == items.count - 1, hasMore, !busy, error == nil { Task { await load(generation) } } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private func bookRow(_ item: LegadoSearchItem, rank: Int) -> some View {
        let tags = Array(
            item.kind.components(separatedBy: CharacterSet(charactersIn: "·/,，|"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(2)
        )
        let intro = item.intro.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let meta = [item.author, item.latest].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 19, weight: .heavy).italic())
                .foregroundStyle(STVTheme.rankColor(rank))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .frame(width: 24)
            WebCover(url: item.cover, title: item.name, author: item.author, corner: 7)
                .frame(width: 56, height: 79)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 15.5, weight: .bold))
                        .foregroundStyle(STVTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !tags.isEmpty {
                        HStack(spacing: 4) { ForEach(tags, id: \.self) { DSTag(text: $0) } }
                    }
                }
                if !intro.isEmpty {
                    Text(intro)
                        .font(.system(size: 12))
                        .foregroundStyle(STVTheme.secondary)
                        .lineLimit(1)
                        .padding(.top, 4)
                }
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 11.5))
                        .foregroundStyle(STVTheme.tertiary)
                        .lineLimit(1)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var sourceSheet: some View {
        let list = sources
        return DSSheet("切换榜单来源", subtitle: "共 \(list.count) 个书源") {
            DSOptionList(options: list.map(\.id), selected: sourceID, label: { id in list.first { $0.id == id }?.bookSourceName ?? id },
                         note: { id in list.first { $0.id == id }?.bookSourceGroup }) { id in
                sourceID = id
                choosingSource = false
            }
        }
        .dsSheetChrome()
    }

    private var sourceControls: some View {
        ScrollView(.vertical) {
            ExploreControlsLayout(spacing: 6) {
                ForEach(categories.filter { $0.group == group && $0.isControl }) { c in
                    Group {
                        if c.type == "text" {
                            ExploreTextControl(category: c, enabled: !busy) { performControl(c, value: $0) }
                        } else if c.type == "select" {
                            Menu { ForEach(c.chars, id: \.self) { value in Button(value) { performControl(c, value: value) } } } label: {
                                ControlChip(title: (c.displayTitle.isEmpty ? c.title : c.displayTitle) + "：" + c.value + " ▾")
                            }
                        } else {
                            let on = (c.type == "toggle" ? c.value : "").contains("●") || c.title.hasPrefix("●")
                            Button { DS.tick(); performControl(c) } label: { ControlChip(title: (c.type == "toggle" ? c.value : "") + (c.displayTitle.isEmpty ? c.title : c.displayTitle), on: on) }
                                .buttonStyle(PressScale())
                        }
                    }
                    .disabled(busy)
                    .layoutValue(key: ExploreBasisKey.self, value: c.flexBasis)
                    .layoutValue(key: ExploreGrowKey.self, value: c.flexGrow)
                    .layoutValue(key: ExploreWrapKey.self, value: c.wrapBefore)
                    .accessibilityIdentifier("novel.rank.filter." + c.title)
                }
            }
            .compatOnSize { controlHeight = $0.height }
            .padding(.horizontal, 16)
        }
        .frame(height: min(240, controlHeight))
        .accessibilityIdentifier("novel.rank.controls")
        .compatScrollBounceBasedOnSize()
    }

    private func select(_ category: LegadoClient.ExploreCategory) {
        guard !busy else { return }
        if category.isControl { performControl(category) }
        else { categoryID = category.id; Task { await resetAndLoad() } }
    }
    private func performControl(_ category: LegadoClient.ExploreCategory, value: String? = nil) {
        guard !busy, let source = sources.first(where: { $0.id == sourceID }) else { return }
        let previous = categories.first { $0.id == categoryID }
        generation = UUID(); let token = generation
        items = []; page = 1; hasMore = false; error = nil; busy = true
        Task {
            do {
                try await LegadoClient.run { try LegadoClient.exploreAction(source, category: category, value: value) }
                guard token == generation, sourceID == source.id, !Task.isCancelled else { return }
                await refreshCategories(previous: previous)
            } catch { if token == generation { self.error = error.localizedDescription; busy = false } }
        }
    }
    private func refreshCategories(previous: LegadoClient.ExploreCategory? = nil) async {
        generation = UUID(); categories = []; categoryID = ""; items = []; error = nil
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        let token = generation; busy = true
        do {
            let result = try await LegadoClient.run { try LegadoClient.exploreCategories(source) }
            guard token == generation, !Task.isCancelled else { return }
            categories = result
            if !result.contains(where: { $0.group == group }) { group = result.first?.group ?? "" }
            busy = false
            let chosen = LegadoClient.refreshedCategory(previous, in: result, group: group)
            categoryID = chosen?.id ?? ""
            if let chosen { group = chosen.group }
            if result.isEmpty { error = "书源没有可用的发现配置" }
            await resetAndLoad()
        } catch { if token == generation { self.error = error.localizedDescription; busy = false } }
    }
    private func resetAndLoad() async {
        guard !categoryID.isEmpty else { items = []; hasMore = false; busy = false; return }
        generation = UUID(); items = []; page = 1; hasMore = true; busy = false; error = nil
        await load(generation)
    }
    private func load(_ token: UUID) async {
        guard token == generation, !busy, hasMore, let source = sources.first(where: { $0.id == sourceID }), let category = categories.first(where: { $0.id == categoryID }), !category.url.isEmpty else { return }
        let requestedPage = page; busy = true; error = nil
        do {
            let result = try await LegadoClient.run { try LegadoClient.explore(source, category: category, page: requestedPage) }
            guard token == generation, !Task.isCancelled else { return }
            var seen = Set(items.map(\.id)); let fresh = result.filter { seen.insert($0.id).inserted }
            items += fresh; hasMore = !fresh.isEmpty; page += 1
        } catch { if token == generation { self.error = error.localizedDescription } }
        if token == generation { busy = false }
    }
}

private struct ExploreBasisKey: LayoutValueKey { static let defaultValue: Double = -1 }
private struct ExploreGrowKey: LayoutValueKey { static let defaultValue: Double = 0 }
private struct ExploreWrapKey: LayoutValueKey { static let defaultValue = false }

/// Generic source flex widths/wrapping; not tied to any site's labels or URL formats.
private struct ExploreControlsLayout: Layout {
    var spacing: CGFloat = 6
    private func rows(_ subviews: Subviews, _ width: CGFloat) -> [[(Int, CGFloat)]] {
        var rows: [[(Int, CGFloat)]] = []; var row: [(Int, CGFloat)] = []; var used: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let basis = v[ExploreBasisKey.self]
            let w = min(width, basis > 0 ? width * min(1, basis) : v.sizeThatFits(.unspecified).width)
            if !row.isEmpty && (v[ExploreWrapKey.self] || used + spacing + w > width) { rows.append(row); row = []; used = 0 }
            row.append((i, w)); used += w + (row.count > 1 ? spacing : 0)
        }
        if !row.isEmpty { rows.append(row) }
        return rows.map { row in
            let extra = max(0, width - row.reduce(0) { $0 + $1.1 } - CGFloat(max(0, row.count - 1)) * spacing)
            let grow = row.reduce(0) { $0 + max(0, subviews[$1.0][ExploreGrowKey.self]) }
            return row.map { (i, w) in (i, w + (grow > 0 ? extra * max(0, subviews[i][ExploreGrowKey.self]) / grow : 0)) }
        }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let rows = rows(subviews, width)
        let height = rows.reduce(CGFloat.zero) { height, row in height + (row.map { subviews[$0.0].sizeThatFits(.init(width: $0.1, height: nil)).height }.max() ?? 0) } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, bounds.width) {
            var x = bounds.minX
            let height = row.map { subviews[$0.0].sizeThatFits(.init(width: $0.1, height: nil)).height }.max() ?? 0
            for (i, width) in row { subviews[i].place(at: CGPoint(x: x, y: y), proposal: .init(width: width, height: height)); x += width + spacing }
            y += height + spacing
        }
    }
}

/// Full-cell chip: source filters are laid out by flex basis, so the chip fills the width it is given.
private struct ControlChip: View {
    let title: String
    var on = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Text(title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(on ? STVTheme.accent : STVTheme.text)
            .padding(.horizontal, 12).frame(minHeight: 34).frame(maxWidth: .infinity)
            .background(Capsule().fill(on ? STVTheme.accentSoft : STVTheme.glass))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.5)
    }
}

private struct ExploreTextControl: View {
    let category: LegadoClient.ExploreCategory
    let enabled: Bool
    let onValue: (String) -> Void
    @State private var text: String
    @State private var pending: Task<Void, Never>?
    init(category: LegadoClient.ExploreCategory, enabled: Bool, onValue: @escaping (String) -> Void) {
        self.category = category; self.enabled = enabled; self.onValue = onValue; _text = State(initialValue: category.value)
    }
    var body: some View {
        DSTextField(category.displayTitle.isEmpty ? category.title : category.displayTitle, text: $text)
            .frame(minWidth: 160).disabled(!enabled)
            .compatOnChange(of: text) { value in
                pending?.cancel()
                guard value != category.value else { return }
                pending = Task { do { try await Task.sleep(for: .milliseconds(450)); onValue(value) } catch {} }
            }
            .compatOnChange(of: enabled) { value in
                pending?.cancel()
                if value && text != category.value { pending = Task { do { try await Task.sleep(for: .milliseconds(450)); onValue(text) } catch {} } }
            }
            .compatOnChange(of: category.value) { value in text = value }
            .onDisappear { pending?.cancel() }
    }
}
