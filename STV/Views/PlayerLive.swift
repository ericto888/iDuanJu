import SwiftUI

/// One programme of a channel's guide.
struct LiveProgram: Identifiable, Equatable {
    var start: Date
    var end: Date
    var title: String
    var id: String { "\(Int(start.timeIntervalSince1970))|\(title)" }
}

extension LiveProgram {
    init(_ p: Programme) {
        self.init(start: Date(timeIntervalSince1970: Double(p.start) / 1000), end: Date(timeIntervalSince1970: Double(p.end) / 1000), title: p.title)
    }
    var programme: Programme {
        Programme(start: Int64(start.timeIntervalSince1970 * 1000), end: Int64(end.timeIntervalSince1970 * 1000), title: title)
    }
}

/// What the player needs from the live engine. The player knows channels (episodes) and streams only; EPG sources and
/// favourites belong to the TVBox engine, which fills these in.
@MainActor enum LiveHooks {
    struct Program: Equatable { var now = ""; var next = "" }
    /// 节目单 of the day containing the date, oldest first.
    static var guide: (HGSeries, HGEpisode, Date) async -> [LiveProgram] = { s, e, day in
        guard let uid = s.source.tvboxLiveUID else { return [] }
        return await TVBoxStore.shared.guide(uid, e, at: Int64(day.timeIntervalSince1970 * 1000)).map(LiveProgram.init).sorted { $0.start < $1.start }
    }
    /// 回看 address of a finished programme; nil when the channel has no catch-up for it.
    static var replay: (HGSeries, HGEpisode, LiveProgram) -> HGResolvedVideo? = { s, e, p in
        guard let uid = s.source.tvboxLiveUID else { return nil }
        return TVBoxStore.shared.catchup(uid, e, p.programme)
    }
    static var program: (HGSeries, HGEpisode) async -> Program? = { s, e in await TVBoxStore.shared.program(s, e) }
    static var isFavorite: (HGEpisode) -> Bool = { TVBoxStore.shared.isFavoriteChannel($0.title) }
    static var toggleFavorite: (HGEpisode) -> Void = { TVBoxStore.shared.toggleFavoriteChannel($0.title) }

    /// Last watched channel of a live list (by group and name: lists are re-downloaded and reordered).
    static func lastChannel(_ s: HGSeries) -> ChannelKey? {
        guard let parts = (UserDefaults.standard.dictionary(forKey: key)?[s.id] as? String)?.components(separatedBy: mark) else { return nil }
        // earlier versions stored the name alone
        return parts.count == 3 ? ChannelKey(group: parts[0], name: parts[1], url: parts[2]) : ChannelKey(group: "", name: parts[0], url: "")
    }
    static func remember(_ channel: HGEpisode, in s: HGSeries) {
        let k = ChannelKey(channel), value = [k.group, k.name, k.url].joined(separator: mark)
        var d = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        guard d[s.id] as? String != value else { return }
        d[s.id] = value
        UserDefaults.standard.set(d, forKey: key)
    }
    private static let key = "stv.live.last"
    private static let mark = "\u{1}"

    /// Where a channel picked by its place in the list as it was shown stands in the list as it is now.
    nonisolated static func place(_ index: Int, _ picked: ChannelKey?, in channels: [HGEpisode]) -> Int { picked?.index(in: channels, near: index) ?? index }

    static func logo(_ e: HGEpisode) -> String {
        guard let m = e.media, let o = try? JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String: Any] else { return "" }
        return o["logo"] as? String ?? ""
    }
    static func sourceCount(_ e: HGEpisode) -> Int {
        guard let m = e.media, let o = try? JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String: Any] else { return 1 }
        return max(1, (o["urls"] as? [String])?.count ?? 1)
    }
}

/// Now / next line under the channel name.
struct PlayerProgramLine: View {
    let series: HGSeries
    let channel: HGEpisode
    @State private var program: LiveHooks.Program?
    var body: some View {
        Group {
            if let p = program, !p.now.isEmpty {
                (Text("正在播 ").foregroundColor(.white.opacity(0.6)) + Text(p.now).foregroundColor(.white.opacity(0.92))
                 + Text(p.next.isEmpty ? "" : "  ·  接着 \(p.next)").foregroundColor(.white.opacity(0.6)))
            } else {
                Text(channel.page ?? "").foregroundColor(.white.opacity(0.6))
            }
        }
        .font(.system(size: 13)).lineLimit(1)
        .accessibilityIdentifier("player.program")
        .task(id: channel.id) {
            program = nil
            while !Task.isCancelled {
                let p = await LiveHooks.program(series, channel)
                guard !Task.isCancelled else { return }
                program = p
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

/// 节目单: one day at a time; finished programmes replay when the channel has catch-up.
struct GuidePopover: View {
    let series: HGSeries
    let channel: HGEpisode
    let replaying: LiveProgram?
    let onReplay: (LiveProgram, HGResolvedVideo) -> Void
    let onLive: () -> Void

    @State private var day = 0
    @State private var rows: [LiveProgram]?
    @State private var replayable = false
    @State private var now = Date()

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let date: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日"; return f }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlayerSectionTitle(text: "节目单", heading: true, trailing: channel.title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(-3...1, id: \.self) { d in PlayerPanelChip(title: title(d), selected: d == day, height: 30) { day = d } }
                }
            }
            if let rows {
                if rows.isEmpty {
                    Text("这一天没有节目单").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                } else { list(rows) }
            } else {
                PlayerLoading(text: "正在载入").frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .task(id: "\(channel.id)|\(day)") {
            rows = nil
            now = Date()
            let list = await LiveHooks.guide(series, channel, now.addingTimeInterval(Double(day) * 86_400))
            guard !Task.isCancelled else { return }
            replayable = list.first { $0.end <= now }.map { LiveHooks.replay(series, channel, $0) != nil } ?? false
            rows = list
        }
    }

    private func title(_ d: Int) -> String {
        switch d {
        case 0: return "今天"
        case -1: return "昨天"
        case -2: return "前天"
        case 1: return "明天"
        default: return Self.date.string(from: now.addingTimeInterval(Double(d) * 86_400))
        }
    }

    private func list(_ rows: [LiveProgram]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) { ForEach(rows) { row($0).id($0.id) } }
            }
            .scrollIndicators(.hidden)
            .onAppear { if let on = rows.first(where: { $0.end > now }), day == 0 { proxy.scrollTo(on.id, anchor: .center) } }
        }
    }

    private func row(_ p: LiveProgram) -> some View {
        let onAir = p.start <= now && now < p.end, past = p.end <= now
        let current = replaying.map { $0.id == p.id } ?? onAir
        return Button {
            if past, replayable, let v = LiveHooks.replay(series, channel, p) { onReplay(p, v) }
            else if onAir, replaying != nil { onLive() }
        } label: {
            HStack(spacing: 10) {
                Text(Self.clock.string(from: p.start)).font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(current ? STVTheme.accent : .white.opacity(past && !replayable ? 0.35 : 0.6)).frame(width: 44, alignment: .leading)
                Text(p.title).font(.system(size: 14, weight: current ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                    .foregroundStyle(current ? STVTheme.accent : .white.opacity(past && !replayable ? 0.45 : 0.92))
                Spacer(minLength: 6)
                if onAir { Text("直播中").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42)) }
                else if past, replayable { Text("回看").font(.system(size: 11, weight: .semibold)).foregroundStyle(STVTheme.accent) }
            }
            .padding(.horizontal, 12).padding(.vertical, 7).frame(minHeight: 46)
            .background(current ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.98))
        .disabled(!(past && replayable) && !(onAir && replaying != nil))
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// 频道: groups, search, favourites and the list. Filtering happens once per change, not per redraw.
struct ChannelsPopover: View {
    let series: HGSeries
    let channels: [HGEpisode]
    let current: Int
    let onPick: (Int) -> Void

    private enum Filter: Hashable { case all, favorites, group(String) }
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var rows: [Int] = []
    @State private var groups: [String] = []
    @State private var favorites: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("频道").font(.system(size: 17, weight: .bold))
                Spacer()
                Text("\(rows.count) / \(channels.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                TextField("", text: $query, prompt: Text("搜索频道").foregroundColor(.white.opacity(0.45)))
                    .font(.system(size: 14)).foregroundStyle(.white).submitLabel(.search).autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.55)) }
                        .buttonStyle(.plain).accessibilityLabel("清除")
                }
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(Color.white.opacity(0.10), in: Capsule())

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        PlayerPanelChip(title: "全部", selected: filter == .all, height: 30) { filter = .all }
                        PlayerPanelChip(title: "收藏", selected: filter == .favorites, symbol: "star.fill", height: 30) { filter = .favorites }
                        ForEach(groups, id: \.self) { g in
                            PlayerPanelChip(title: g, selected: filter == .group(g), height: 30) { filter = .group(g) }.id(g)
                        }
                    }
                }
                .compatOnChange(of: groups) {
                    if case .group(let g) = filter { proxy.scrollTo(g, anchor: .center) }
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(rows, id: \.self) { i in row(i).id(i) }
                    }
                }
                .scrollIndicators(.hidden)
                .compatOnChange(of: rows) { r in if r.contains(current) { proxy.scrollTo(current, anchor: .center) } }
            }
            .overlay {
                if rows.isEmpty {
                    Text(filter == .favorites ? "还没有收藏的频道" : "没有匹配的频道").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .onAppear {
            var seen = Set<String>()
            groups = channels.compactMap { $0.page }.filter { !$0.isEmpty && seen.insert($0).inserted }
            favorites = Set(channels.filter { LiveHooks.isFavorite($0) }.map(\.title))
            if channels.indices.contains(current), let g = channels[current].page, !g.isEmpty { filter = .group(g) }
            refilter()
        }
        .compatOnChange(of: filter) { refilter() }
        .compatOnChange(of: query) { refilter() }
    }

    private func row(_ i: Int) -> some View {
        let e = channels[i], on = i == current
        let logo = LiveHooks.logo(e)
        return HStack(spacing: 10) {
            Button { onPick(i) } label: {
                HStack(spacing: 10) {
                    Group {
                        if logo.isEmpty {
                            Text(String(format: "%03d", i + 1)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(on ? STVTheme.accent : .white.opacity(0.5))
                        } else {
                            CoverView(url: logo, corner: 6)
                        }
                    }
                    .frame(width: 40, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.system(size: 15, weight: on ? .semibold : .regular)).lineLimit(1)
                        if LiveHooks.sourceCount(e) > 1 {
                            Text("\(LiveHooks.sourceCount(e)) 条线路").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    Spacer(minLength: 4)
                    if on { Image(systemName: "waveform").font(.system(size: 13, weight: .semibold)).foregroundStyle(STVTheme.accent) }
                }
                .foregroundStyle(on ? STVTheme.accent : .white)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale(scale: 0.98))
            .accessibilityIdentifier("player.channel.\(e.ep)")
            .accessibilityAddTraits(on ? .isSelected : [])
            Button {
                LiveHooks.toggleFavorite(e)
                if favorites.remove(e.title) == nil { favorites.insert(e.title) }
                if filter == .favorites { refilter() }
            } label: {
                Image(systemName: favorites.contains(e.title) ? "star.fill" : "star")
                    .font(.system(size: 14)).foregroundStyle(favorites.contains(e.title) ? STVTheme.accentWarm : .white.opacity(0.4))
                    .frame(width: 40, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(favorites.contains(e.title) ? "取消收藏" : "收藏")
        }
        .padding(.leading, 10).frame(minHeight: 48)
        .background(on ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func refilter() {
        let q = query.trimmingCharacters(in: .whitespaces)
        rows = channels.indices.filter { i in
            let e = channels[i]
            if !q.isEmpty { return e.title.localizedCaseInsensitiveContains(q) }
            switch filter {
            case .all: return true
            case .favorites: return favorites.contains(e.title)
            case .group(let g): return e.page == g
            }
        }
    }
}
