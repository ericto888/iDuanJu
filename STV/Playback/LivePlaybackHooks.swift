import Foundation

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

